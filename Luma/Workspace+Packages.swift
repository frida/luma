import Foundation
import LumaCore
import SwiftyMonaco

extension Workspace {
    func rebuildMonacoFSSnapshotIfNeeded() async {
        guard monacoFSSnapshotDirty else { return }

        do {
            let paths = try engine.compilerWorkspacePaths()
            _ = try await engine.compilerWorkspace.ensureReady(paths: paths)

            let snapshot = try buildMonacoFSSnapshot(paths: paths)
            monacoFSSnapshotVersion += 1
            monacoFSSnapshot = snapshot.withVersion(monacoFSSnapshotVersion)
            monacoFSSnapshotDirty = false
        } catch {
            print("Failed to rebuild Monaco FS snapshot: \(error)")
        }
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
}
