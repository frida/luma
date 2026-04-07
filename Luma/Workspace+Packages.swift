import Foundation
import LumaCore
import SwiftyMonaco

extension Workspace {
    func rebuildMonacoFSSnapshotIfNeeded() async {
        await engine.rebuildMonacoFSSnapshotIfNeeded()
    }

    var monacoFSSnapshot: SwiftyMonaco.MonacoFSSnapshot? {
        guard let snap = engine.monacoFSSnapshot else { return nil }
        return SwiftyMonaco.MonacoFSSnapshot(
            version: snap.version,
            files: snap.files.map { .init(path: $0.path, text: $0.text) }
        )
    }
}
