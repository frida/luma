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
    public var lastCompilerDiagnostics: [String] = []

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

                if packagesState.packageJSON != nil || packagesState.packageLockJSON != nil {
                    try self.writeManifestsToDisk(from: packagesState, paths: paths)

                    let opts = PackageInstallOptions()
                    opts.projectRoot = paths.root.path
                    opts.role = .runtime

                    _ = try await self.packageManager.install(options: opts)
                } else if !packagesState.packages.isEmpty {
                    let specs = packagesState.packages.map { "\($0.name)@\($0.version)" }

                    let opts = PackageInstallOptions()
                    opts.projectRoot = paths.root.path
                    opts.role = .runtime
                    opts.specs = specs

                    _ = try await self.packageManager.install(options: opts)
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

        let spec = versionSpec.map { "\(name)@\($0)" } ?? name

        let opts = PackageInstallOptions()
        opts.projectRoot = paths.root.path
        opts.role = .runtime
        opts.specs = [spec]

        let result = try await packageManager.install(options: opts)

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

            let opts = PackageInstallOptions()
            opts.projectRoot = paths.root.path
            opts.role = .runtime
            opts.specs = specs

            _ = try await self.packageManager.install(options: opts)

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

        let options = BuildOptions()
        options.projectRoot = paths.root.path
        options.sourceMaps = .omitted
        options.compression = .terser

        let bundle = try await withCompilerDiagnostics(label: "package \(package.name)") { compiler in
            return try await compiler.build(entrypoint: wrapperRelPath, options: options)
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
        _ work: (Compiler) async throws -> T
    ) async throws -> T {
        let compiler = Compiler()

        var diagnostics: [String] = []

        let eventsTask = Task { @MainActor in
            for await event in compiler.events {
                switch event {
                case .starting:
                    break
                case .diagnostics(let payload):
                    diagnostics.append(String(describing: payload))
                case .output:
                    break
                case .finished:
                    return
                }
            }
        }

        do {
            let result = try await work(compiler)
            lastCompilerDiagnostics = diagnostics
            eventsTask.cancel()
            return result
        } catch {
            eventsTask.cancel()
            lastCompilerDiagnostics = diagnostics
            throw error
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
