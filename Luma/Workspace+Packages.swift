import Foundation
import Frida
import SwiftData
import SwiftyMonaco

extension Workspace {
    @MainActor
    func projectPackagesState() throws -> ProjectPackagesState {
        guard let modelContext else {
            fatalError("Workspace.modelContext is not configured")
        }

        if let existing =
            try modelContext
            .fetch(FetchDescriptor<ProjectPackagesState>())
            .first
        {
            return existing
        }

        let state = ProjectPackagesState()
        modelContext.insert(state)
        return state
    }

    func currentPackageBundlesForAgent() async throws -> [[String: Any]] {
        _ = try await ensureCompilerWorkspaceReady()

        let projectPackages = try projectPackagesState()

        var items: [[String: Any]] = []

        for pkg in projectPackages.packages {
            guard let bundle = packageBundles[pkg.name] else {
                continue
            }

            var entry: [String: Any] = [
                "name": pkg.name,
                "bundle": bundle,
            ]

            if let alias = pkg.globalAlias {
                entry["globalAlias"] = alias
            }

            items.append(entry)
        }

        return items
    }

    func compilerWorkspaceDirectory() throws -> URL {
        let projectPackages = try projectPackagesState()
        let fm = FileManager.default

        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let root =
            base
            .appendingPathComponent(Bundle.main.bundleIdentifier!, isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectPackages.id.uuidString, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)

        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }

        return root
    }

    func ensureCompilerWorkspaceReady() async throws -> URL {
        var rootURL: URL!

        try await packageOps.enqueue {
            let projectPackages = try self.projectPackagesState()
            let paths = try self.compilerWorkspacePaths()
            let fm = FileManager.default

            if self.compilerWorkspaceRoot == nil {
                if !fm.fileExists(atPath: paths.root.path) {
                    try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
                }

                if projectPackages.packageJSON != nil || projectPackages.packageLockJSON != nil {
                    try self.writeManifestsToDisk(from: projectPackages, paths: paths)

                    let opts = PackageInstallOptions()
                    opts.projectRoot = paths.root.path
                    opts.role = .runtime

                    _ = try await self.packageManager.install(options: opts)

                    try self.loadManifestsFromDisk(into: projectPackages, paths: paths)
                } else if !projectPackages.packages.isEmpty {
                    let specs = projectPackages.packages.map { "\($0.name)@\($0.version)" }

                    let opts = PackageInstallOptions()
                    opts.projectRoot = paths.root.path
                    opts.role = .runtime
                    opts.specs = specs

                    _ = try await self.packageManager.install(options: opts)

                    try self.loadManifestsFromDisk(into: projectPackages, paths: paths)
                }

                self.compilerWorkspaceRoot = paths.root
                self.packageBundlesDirty = true
                self.monacoFSSnapshotDirty = true
            }

            if self.packageBundlesDirty {
                try await self.buildAllPackageBundles(
                    projectPackages: projectPackages,
                    paths: paths
                )
                self.packageBundlesDirty = false
            }

            if self.monacoFSSnapshotDirty {
                let snapshot = try self.buildMonacoFSSnapshot(paths: paths)
                self.monacoFSSnapshotVersion += 1
                self.monacoFSSnapshot = snapshot.withVersion(self.monacoFSSnapshotVersion)
                self.monacoFSSnapshotDirty = false
            }

            rootURL = self.compilerWorkspaceRoot ?? paths.root
        }

        return rootURL
    }

    func installPackage(
        name: String,
        versionSpec: String? = nil,
        globalAlias: String? = nil
    ) async throws -> InstalledPackage {
        var installed: InstalledPackage!

        try await packageOps.enqueue {
            installed = try await self._installPackage(
                name: name,
                versionSpec: versionSpec,
                globalAlias: globalAlias,
            )
        }

        propagateNewlyInstalledPackage(installed)

        return installed
    }

    @MainActor
    private func _installPackage(
        name: String,
        versionSpec: String?,
        globalAlias: String?
    ) async throws -> InstalledPackage {
        let projectPackages = try projectPackagesState()
        let paths = try compilerWorkspacePaths()

        let spec = versionSpec.map { "\(name)@\($0)" } ?? name

        let opts = PackageInstallOptions()
        opts.projectRoot = paths.root.path
        opts.role = .runtime
        opts.specs = [spec]

        let result = try await packageManager.install(options: opts)

        try loadManifestsFromDisk(into: projectPackages, paths: paths)

        guard let installed = result.packages.first(where: { $0.name == name }) else {
            return projectPackages.packages.first(where: { $0.name == name })!
        }

        if let existing = projectPackages.packages.first(where: { $0.name == name }) {
            projectPackages.packages.removeAll { $0.id == existing.id }
            modelContext.delete(existing)
        }

        let entry = InstalledPackage(
            name: installed.name,
            version: installed.version,
            globalAlias: globalAlias,
            project: projectPackages
        )
        projectPackages.packages.append(entry)
        modelContext.insert(entry)

        packageBundlesDirty = true
        monacoFSSnapshotDirty = true

        return entry
    }

    func upgradePackage(_ package: InstalledPackage) async throws -> InstalledPackage {
        var upgraded: InstalledPackage!

        try await packageOps.enqueue {
            upgraded = try await self._installPackage(
                name: package.name,
                versionSpec: nil,
                globalAlias: package.globalAlias
            )

            if upgraded.id != package.id {
                self.modelContext.delete(package)
            }
        }

        return upgraded
    }

    func removePackage(_ package: InstalledPackage) async throws {
        try await packageOps.enqueue {
            let projectPackages = try self.projectPackagesState()
            let paths = try self.compilerWorkspacePaths()

            projectPackages.packages.removeAll { $0.id == package.id }
            self.modelContext.delete(package)

            try self.deleteWorkspaceManifestsAndNodeModules(paths: paths)

            guard !projectPackages.packages.isEmpty else {
                projectPackages.packageJSON = nil
                projectPackages.packageLockJSON = nil
                self.packageBundles = [:]
                self.packageBundlesDirty = false
                return
            }

            let specs = projectPackages.packages.map { "\($0.name)@\($0.version)" }

            let opts = PackageInstallOptions()
            opts.projectRoot = paths.root.path
            opts.role = .runtime
            opts.specs = specs

            _ = try await self.packageManager.install(options: opts)

            try self.loadManifestsFromDisk(into: projectPackages, paths: paths)

            self.packageBundlesDirty = true
            self.monacoFSSnapshotDirty = true
        }
    }

    private func buildAllPackageBundles(projectPackages: ProjectPackagesState, paths: CompilerWorkspacePaths) async throws {
        packageBundles.removeAll()

        for pkg in projectPackages.packages {
            let descriptor = try await buildBundle(for: pkg, paths: paths)
            packageBundles[pkg.name] = descriptor.bundle
        }
    }

    private func buildBundle(for package: InstalledPackage, paths: CompilerWorkspacePaths) async throws -> PackageBundleDescriptor {
        let fm = FileManager.default

        let wrapperRelPath = "Packages/\(package.name).entry.js"
        let wrapperURL = paths.root.appendingPathComponent(wrapperRelPath)

        try fm.createDirectory(
            at: wrapperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let source = """
            export * from "\(package.name)";
            export { default } from "\(package.name)";
            """
        try source.write(to: wrapperURL, atomically: true, encoding: .utf8)

        let options = BuildOptions()
        options.projectRoot = paths.root.path
        options.sourceMaps = .omitted
        options.compression = .terser

        let bundle = try await withCompilerDiagnostics(label: "package \(package.name)") { compiler in
            return try await compiler.build(entrypoint: wrapperRelPath, options: options)
        }

        let modules = try parseESMBundle(bundle)

        return PackageBundleDescriptor(
            name: package.name,
            bundle: modules.modules[modules.order[0]]!
        )
    }

    struct PackageBundleDescriptor {
        let name: String
        let bundle: String
    }

    func withCompilerDiagnostics<T>(
        label: String,
        _ work: (Compiler) async throws -> T
    ) async throws -> T {
        let compiler = Compiler()

        var diagnostics: [String] = []

        let eventsTask = Task { @MainActor in
            for await event in compiler.events {
                switch event {
                case .starting:
                    NSLog("[Compiler][\(label)] starting")
                case .diagnostics(let payload):
                    let message = String(describing: payload)
                    diagnostics.append(message)
                    NSLog("[Compiler][\(label)] diagnostics: %@", message)
                case .output:
                    NSLog("[Compiler][\(label)] output")
                case .finished:
                    NSLog("[Compiler][\(label)] finished")
                    return
                }
            }
        }

        do {
            let result = try await work(compiler)

            await MainActor.run {
                self.lastCompilerDiagnostics = diagnostics
            }
            eventsTask.cancel()

            return result
        } catch {
            eventsTask.cancel()

            await MainActor.run {
                self.lastCompilerDiagnostics = diagnostics
            }

            throw error
        }
    }

    func loadAllPackages(on node: ProcessNode) async {
        do {
            let bundles = try await currentPackageBundlesForAgent()
            guard !bundles.isEmpty else { return }

            try await node.script.exports.loadPackages(JSValue(bundles))

            for entry in bundles {
                node.loadedPackageNames.insert(entry["name"] as! String)
            }
        } catch {
            print("Failed to load package bundles into process \(node.process.pid): \(error)")
        }
    }

    func loadPackage(_ package: InstalledPackage, on node: ProcessNode) async {
        if node.loadedPackageNames.contains(package.name) {
            return
        }

        do {
            let bundles = try await currentPackageBundlesForAgent()

            guard let entry = bundles.first(where: { ($0["name"] as? String) == package.name }) else {
                return
            }

            try await node.script.exports.loadPackages(JSValue([entry]))

            node.loadedPackageNames.insert(entry["name"] as! String)
        } catch {
            print("Failed to load package \(package.name) into process \(node.process.pid): \(error)")
        }
    }

    func propagateNewlyInstalledPackage(_ package: InstalledPackage) {
        Task { @MainActor in
            for node in self.processNodes {
                await self.loadPackage(package, on: node)
            }
        }
    }

    func compilerWorkspacePaths() throws -> CompilerWorkspacePaths {
        CompilerWorkspacePaths(root: try compilerWorkspaceDirectory())
    }

    private func loadManifestsFromDisk(into projectPackages: ProjectPackagesState, paths: CompilerWorkspacePaths) throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: paths.packageJSON.path) {
            projectPackages.packageJSON = try Data(contentsOf: paths.packageJSON)
        } else {
            projectPackages.packageJSON = nil
        }

        if fm.fileExists(atPath: paths.packageLockJSON.path) {
            projectPackages.packageLockJSON = try Data(contentsOf: paths.packageLockJSON)
        } else {
            projectPackages.packageLockJSON = nil
        }
    }

    private func writeManifestsToDisk(from projectPackages: ProjectPackagesState, paths: CompilerWorkspacePaths) throws {
        let fm = FileManager.default

        if let data = projectPackages.packageJSON {
            try data.write(to: paths.packageJSON, options: .atomic)
        } else {
            try? fm.removeItem(at: paths.packageJSON)
        }

        if let data = projectPackages.packageLockJSON {
            try data.write(to: paths.packageLockJSON, options: .atomic)
        } else {
            try? fm.removeItem(at: paths.packageLockJSON)
        }
    }

    private func deleteWorkspaceManifestsAndNodeModules(paths: CompilerWorkspacePaths) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: paths.nodeModules)
        try? fm.removeItem(at: paths.packageJSON)
        try? fm.removeItem(at: paths.packageLockJSON)
    }

    private func buildMonacoFSSnapshot(paths: CompilerWorkspacePaths) throws -> MonacoFSSnapshot {
        let fm = FileManager.default
        let root = paths.root
        let nodeModules = paths.nodeModules

        guard fm.fileExists(atPath: nodeModules.path) else {
            return MonacoFSSnapshot(version: 0, files: [])
        }

        let workspaceRootURI = "file:///workspace/"

        func toWorkspaceURI(_ fileURL: URL) -> String? {
            guard fileURL.path.hasPrefix(root.path) else { return nil }
            var rel = String(fileURL.path.dropFirst(root.path.count))
            if rel.hasPrefix("/") {
                rel.removeFirst()
            }
            return workspaceRootURI + rel.replacingOccurrences(of: " ", with: "%20")
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        let enumerator = fm.enumerator(
            at: nodeModules,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        var out: [MonacoFSSnapshotFile] = []
        out.reserveCapacity(2048)

        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }

            let name = values.name ?? url.lastPathComponent

            let isInteresting = name == "package.json" || name.hasSuffix(".d.ts")
            if isInteresting == false {
                continue
            }

            guard let uri = toWorkspaceURI(url) else { continue }

            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { continue }

            out.append(.init(path: uri, text: text))
        }

        return MonacoFSSnapshot(version: 0, files: out)
    }

    func parseESMBundle(_ bundle: String) throws -> ESMModules {
        let headerPrefix = "📦\n"
        let separator = "✄\n"

        guard bundle.hasPrefix(headerPrefix) else {
            throw ESMBundleError.invalidFormat
        }

        guard let separatorRange = bundle.range(of: "\n" + separator) else {
            throw ESMBundleError.headerNotFound
        }

        let headerString = String(bundle[..<separatorRange.lowerBound])
        let headerAndSepString = String(bundle[..<separatorRange.upperBound])

        guard let bundleData = bundle.data(using: .utf8) else {
            throw ESMBundleError.encodingError
        }
        let headerAndSepByteCount = headerAndSepString.utf8.count

        let bodyBytes = bundleData[headerAndSepByteCount...]
        let separatorData = separator.data(using: .utf8)!
        let separatorLength = separatorData.count

        var descriptors: [(path: String, size: Int)] = []

        let headerLines = headerString.split(separator: "\n", omittingEmptySubsequences: false)
        guard headerLines.first == "📦" else {
            throw ESMBundleError.invalidFormat
        }

        for line in headerLines.dropFirst() {
            if line.isEmpty {
                throw ESMBundleError.invalidFormat
            }

            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let size = Int(parts[0]) else {
                throw ESMBundleError.invalidHeaderLine(String(line))
            }

            let path = String(parts[1])
            descriptors.append((path: path, size: size))
        }

        if descriptors.isEmpty {
            throw ESMBundleError.emptyBundle
        }

        var modules: [String: String] = [:]
        var order: [String] = []

        var cursor = bodyBytes.startIndex

        for (index, desc) in descriptors.enumerated() {
            let remaining = bodyBytes.distance(from: cursor, to: bodyBytes.endIndex)
            guard remaining >= desc.size else {
                throw ESMBundleError.sizeOutOfRange
            }

            let start = cursor
            let end = bodyBytes.index(start, offsetBy: desc.size)
            let fileData = bodyBytes[start..<end]

            guard let source = String(data: fileData, encoding: .utf8) else {
                throw ESMBundleError.encodingError
            }

            modules[desc.path] = source
            order.append(desc.path)

            cursor = end

            if index < descriptors.count - 1 {
                let remainingAfterFile = bodyBytes.distance(from: cursor, to: bodyBytes.endIndex)
                guard remainingAfterFile >= separatorLength else {
                    throw ESMBundleError.invalidSeparator
                }

                let sepEnd = bodyBytes.index(cursor, offsetBy: separatorLength)
                let sepSlice = bodyBytes[cursor..<sepEnd]
                if sepSlice != separatorData {
                    throw ESMBundleError.invalidSeparator
                }

                cursor = sepEnd
            }
        }

        guard cursor == bodyBytes.endIndex else {
            throw ESMBundleError.trailingData
        }

        return ESMModules(modules: modules, order: order)
    }

    struct ESMModules {
        let modules: [String: String]
        let order: [String]
    }

    private enum ESMBundleError: Swift.Error {
        case invalidFormat
        case headerNotFound
        case invalidHeaderLine(String)
        case emptyBundle
        case encodingError
        case sizeOutOfRange
        case invalidSeparator
        case trailingData
    }
}

struct CompilerWorkspacePaths {
    let root: URL

    var nodeModules: URL {
        root.appendingPathComponent("node_modules", isDirectory: true)
    }

    var packageJSON: URL {
        root.appendingPathComponent("package.json")
    }

    var packageLockJSON: URL {
        root.appendingPathComponent("package-lock.json")
    }
}

@MainActor
final class PackageOperationQueue {
    private var pending: [() async throws -> Void] = []
    private var isRunning = false

    func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending.append {
                do {
                    try await operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if !isRunning {
                Task { [self] in
                    try await runNext()
                }
            }
        }
    }

    private func runNext() async throws {
        guard !pending.isEmpty else {
            isRunning = false
            return
        }

        isRunning = true
        let op = pending.removeFirst()

        do {
            try await op()
            try await runNext()
        } catch {
            isRunning = false
            pending.removeAll()
            throw error
        }
    }
}
