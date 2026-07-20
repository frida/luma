import Foundation
import Frida

public struct CompilerWorkspacePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var nodeModules: URL {
        root.appendingPathComponent("node_modules", isDirectory: true)
    }

    public var packageJSON: URL {
        root.appendingPathComponent("package.json")
    }

    public var packageLockJSON: URL {
        root.appendingPathComponent("package-lock.json")
    }
}

@MainActor
public final class CompilerWorkspace {
    public let packageOps = PackageOperationQueue()
    public let packageManager = PackageManager()

    public var workspaceRoot: URL?
    public var packageBundles: [String: String] = [:]
    public var packageBundlesDirty = true
    public var lastCompilerDiagnostics: [CompilerDiagnostic] = []

    private let store: ProjectStore

    public init(store: ProjectStore) {
        self.store = store
    }

    public func ensureReady(paths: CompilerWorkspacePaths) async throws -> URL {
        var rootURL: URL!

        try await packageOps.enqueue {
            let packagesState = try self.store.fetchPackagesState()
            let fm = FileManager.default

            if self.workspaceRoot == nil {
                if !fm.fileExists(atPath: paths.root.path) {
                    try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
                }

                try self.discardOrphanedDiskState(packagesState: packagesState, paths: paths)

                if packagesState.packageJSON != nil || packagesState.packageLockJSON != nil {
                    try self.writeManifestsToDisk(from: packagesState, paths: paths)

                    _ = try await self.packageManager.install(
                        projectRoot: paths.root.path,
                        role: .runtime)
                } else if !packagesState.packages.isEmpty {
                    let specs = packagesState.packages.map { "\($0.name)@\($0.version)" }

                    _ = try await self.packageManager.install(
                        specs: specs,
                        projectRoot: paths.root.path,
                        role: .runtime)
                }

                self.workspaceRoot = paths.root
                self.packageBundlesDirty = true
            }

            if self.packageBundlesDirty {
                try await self.buildAllPackageBundles(packagesState: packagesState, paths: paths)
                self.packageBundlesDirty = false
            }

            rootURL = self.workspaceRoot ?? paths.root
        }

        return rootURL
    }

    public func installPackage(
        name: String,
        versionSpec: String? = nil,
        globalAlias: String? = nil,
        paths: CompilerWorkspacePaths
    ) async throws -> InstalledPackage {
        var installed: InstalledPackage!

        try await packageOps.enqueue {
            installed = try await self.performInstallPackage(
                name: name,
                versionSpec: versionSpec,
                globalAlias: globalAlias,
                paths: paths
            )
        }

        return installed
    }

    private func performInstallPackage(
        name: String,
        versionSpec: String?,
        globalAlias: String?,
        paths: CompilerWorkspacePaths
    ) async throws -> InstalledPackage {
        var packagesState = try store.fetchPackagesState()

        try discardOrphanedDiskState(packagesState: packagesState, paths: paths)

        let spec = versionSpec.map { "\(name)@\($0)" } ?? name

        let result = try await packageManager.install(
            specs: [spec],
            projectRoot: paths.root.path,
            role: .runtime)

        let manifests = try readManifestsFromDisk(paths: paths)
        packagesState.packageJSON = manifests.packageJSON
        packagesState.packageLockJSON = manifests.packageLockJSON

        guard let installedInfo = result.packages.first(where: { $0.name == name }) else {
            if let existing = packagesState.packages.first(where: { $0.name == name }) {
                return existing
            }
            throw LumaCoreError.invalidOperation("Package '\(name)' not found in install result")
        }

        packagesState.packages.removeAll { $0.name == name }

        let entry = InstalledPackage(
            packagesStateID: packagesState.id,
            name: installedInfo.name,
            version: installedInfo.version,
            globalAlias: globalAlias
        )
        packagesState.packages.append(entry)

        try store.save(packagesState)

        packageBundlesDirty = true

        return entry
    }

    public func removePackage(_ package: InstalledPackage, paths: CompilerWorkspacePaths) async throws {
        try await packageOps.enqueue {
            var packagesState = try self.store.fetchPackagesState()

            packagesState.packages.removeAll { $0.id == package.id }

            try self.deleteWorkspaceManifestsAndNodeModules(paths: paths)

            guard !packagesState.packages.isEmpty else {
                packagesState.packageJSON = nil
                packagesState.packageLockJSON = nil
                self.packageBundles = [:]
                self.packageBundlesDirty = false
                try self.store.save(packagesState)
                return
            }

            let specs = packagesState.packages.map { "\($0.name)@\($0.version)" }

            _ = try await self.packageManager.install(
                specs: specs,
                projectRoot: paths.root.path,
                role: .runtime)

            let manifests = try self.readManifestsFromDisk(paths: paths)
            packagesState.packageJSON = manifests.packageJSON
            packagesState.packageLockJSON = manifests.packageLockJSON

            try self.store.save(packagesState)

            self.packageBundlesDirty = true
        }
    }

    public func currentPackageBundlesForAgent(paths: CompilerWorkspacePaths) async throws -> [[String: Any]] {
        _ = try await ensureReady(paths: paths)

        let packagesState = try store.fetchPackagesState()

        var items: [[String: Any]] = []
        for pkg in packagesState.packages {
            guard let bundle = packageBundles[pkg.name] else { continue }

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

    // MARK: - Bundle Building

    private func buildAllPackageBundles(packagesState: ProjectPackagesState, paths: CompilerWorkspacePaths) async throws {
        packageBundles.removeAll()

        for pkg in packagesState.packages {
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

        let bundle = try await withCompilerDiagnostics(label: "package \(package.name)") { compiler in
            return try await compiler.build(
                entrypoint: wrapperRelPath,
                projectRoot: paths.root.path,
                sourceMaps: .omitted,
                compression: .terser)
        }

        let modules = try ESMBundleParser.parse(bundle)

        return PackageBundleDescriptor(
            name: package.name,
            bundle: modules.modules[modules.order[0]]!
        )
    }

    struct PackageBundleDescriptor {
        let name: String
        let bundle: String
    }

    public func withCompilerDiagnostics<T>(
        label: String,
        pathDisplay: (@Sendable (String) -> String)? = nil,
        _ work: (Compiler) async throws -> T
    ) async throws -> T {
        let compiler = Compiler()
        let collector = DiagnosticCollector(pathDisplay: pathDisplay)

        let stream = compiler.events
        let eventsTask = Task { @MainActor in
            for await event in stream {
                switch event {
                case .diagnostics(let payload):
                    collector.absorb(payload)
                case .finished:
                    return
                case .starting, .output:
                    break
                }
            }
        }

        let outcome: Result<T, Swift.Error>
        do {
            outcome = .success(try await work(compiler))
        } catch {
            outcome = .failure(error)
        }

        await eventsTask.value
        lastCompilerDiagnostics = collector.diagnostics

        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw CompileFailure(label: label, underlying: error, diagnostics: collector.diagnostics)
        }
    }

    // MARK: - Disk Operations

    private func writeManifestsToDisk(from state: ProjectPackagesState, paths: CompilerWorkspacePaths) throws {
        let fm = FileManager.default

        if let data = state.packageJSON {
            try data.write(to: paths.packageJSON, options: .atomic)
        } else {
            try? fm.removeItem(at: paths.packageJSON)
        }

        if let data = state.packageLockJSON {
            try data.write(to: paths.packageLockJSON, options: .atomic)
        } else {
            try? fm.removeItem(at: paths.packageLockJSON)
        }
    }

    private func discardOrphanedDiskState(
        packagesState: ProjectPackagesState,
        paths: CompilerWorkspacePaths
    ) throws {
        guard packagesState.packageJSON == nil, packagesState.packageLockJSON == nil else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.packageJSON.path) || fm.fileExists(atPath: paths.nodeModules.path) else { return }
        try deleteWorkspaceManifestsAndNodeModules(paths: paths)
    }

    private func readManifestsFromDisk(paths: CompilerWorkspacePaths) throws -> (packageJSON: Data?, packageLockJSON: Data?) {
        let fm = FileManager.default
        let packageJSON = fm.fileExists(atPath: paths.packageJSON.path) ? try Data(contentsOf: paths.packageJSON) : nil
        let packageLockJSON = fm.fileExists(atPath: paths.packageLockJSON.path) ? try Data(contentsOf: paths.packageLockJSON) : nil
        return (packageJSON, packageLockJSON)
    }

    private func deleteWorkspaceManifestsAndNodeModules(paths: CompilerWorkspacePaths) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: paths.nodeModules)
        try? fm.removeItem(at: paths.packageJSON)
        try? fm.removeItem(at: paths.packageLockJSON)
    }
}

@MainActor
private final class DiagnosticCollector {
    private(set) var diagnostics: [CompilerDiagnostic] = []
    private let pathDisplay: ((String) -> String)?

    init(pathDisplay: ((String) -> String)?) {
        self.pathDisplay = pathDisplay
    }

    func absorb(_ payload: Any) {
        diagnostics.append(contentsOf: CompilerDiagnostic.parse(payload, pathDisplay: pathDisplay))
    }
}

public struct CompileFailure: Swift.Error, CustomStringConvertible, LocalizedError {
    public let label: String
    public let underlying: any Swift.Error
    public let diagnostics: [CompilerDiagnostic]

    public var description: String {
        var message: String
        if let frida = underlying as? Frida.Error {
            message = frida.description
        } else {
            message = underlying.localizedDescription
        }
        if !diagnostics.isEmpty {
            message += "\n" + diagnostics.map(\.description).joined(separator: "\n")
        }
        return message
    }

    public var errorDescription: String? { description }
}

public struct CompilerDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public struct Location: Sendable, Hashable {
        public let path: String
        public let line: Int
        public let character: Int
    }

    public let category: String
    public let code: Int
    public let location: Location?
    public let text: String

    public var description: String {
        var prefix = ""
        if let location {
            prefix = "\(location.path):\(location.line):\(location.character) - "
        }
        let header = code == -1 ? category : "\(category) TS\(code)"
        return "\(prefix)\(header): \(text)"
    }

    static func parse(_ payload: Any, pathDisplay: ((String) -> String)?) -> [CompilerDiagnostic] {
        guard let entries = payload as? [[String: Any]] else { return [] }
        return entries.map { decode($0, pathDisplay: pathDisplay) }
    }

    private static func decode(_ obj: [String: Any], pathDisplay: ((String) -> String)?) -> CompilerDiagnostic {
        return CompilerDiagnostic(
            category: obj["category"] as? String ?? "error",
            code: decodeInt(obj["code"]) ?? -1,
            location: (obj["file"] as? [String: Any]).flatMap { decodeLocation($0, pathDisplay: pathDisplay) },
            text: obj["text"] as? String ?? "Compiler returned an invalid diagnostic payload."
        )
    }

    private static func decodeLocation(_ obj: [String: Any], pathDisplay: ((String) -> String)?) -> Location? {
        guard let rawPath = obj["path"] as? String,
            let line = decodeInt(obj["line"]),
            let character = decodeInt(obj["character"])
        else { return nil }
        return Location(
            path: pathDisplay?(rawPath) ?? rawPath,
            line: line,
            character: character
        )
    }

    private static func decodeInt(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(value)
        case let value as Double:
            return Int(exactly: value)
        default:
            return nil
        }
    }
}
