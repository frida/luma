import Foundation

struct PatternPackageManifest: Decodable {
    let main: String
    let keywords: [String]

    static func of(_ package: InstalledPackage, in workspace: CompilerWorkspacePaths) -> PatternPackageManifest? {
        let url = workspace.nodeModules.appendingPathComponent(package.name, isDirectory: true).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: url.path),
            let manifest = try? JSONDecoder().decode(PatternPackageManifest.self, from: data),
            manifest.keywords.contains(PatternLibrary.packageKeyword)
        else {
            return nil
        }
        return manifest
    }
}
