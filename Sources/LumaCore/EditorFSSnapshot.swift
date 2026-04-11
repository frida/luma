import Foundation

public struct EditorFSSnapshotFile: Codable, Hashable, Sendable {
    public var path: String
    public var text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

public struct EditorFSSnapshot: Codable, Hashable, Sendable {
    public var version: Int
    public var files: [EditorFSSnapshotFile]

    public init(version: Int, files: [EditorFSSnapshotFile]) {
        self.version = version
        self.files = files
    }

    public func withVersion(_ v: Int) -> EditorFSSnapshot {
        EditorFSSnapshot(version: v, files: files)
    }
}

public enum MonacoPackageAliasTypings {
    public struct GeneratedLib: Sendable {
        public let filePath: String
        public let content: String
    }

    public static func makeLib(packages: [InstalledPackage]) -> GeneratedLib? {
        let aliased = packages.compactMap { pkg -> (alias: String, module: String)? in
            guard let alias = pkg.globalAlias, !alias.isEmpty else { return nil }
            return (alias: alias, module: pkg.name)
        }
        guard !aliased.isEmpty else { return nil }

        var dts = """
            type LumaPackageAlias<T> = T extends { default: infer D } ? D : T;

            declare global {

            """
        for (alias, moduleName) in aliased {
            dts += """
                    const \(alias): LumaPackageAlias<typeof import("\(moduleName)")>;\n
                """
        }
        dts += """
            }

            export {};
            """

        return GeneratedLib(
            filePath: "file:///workspace/luma-package-aliases.d.ts",
            content: dts
        )
    }
}
