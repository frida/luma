import LumaCore
import SwiftUI
import SwiftyMonaco

struct CodeEditorView: View {
    @Binding var text: String
    let profile: EditorProfile
    var introspector: MonacoIntrospector? = nil
    @ObservedObject var workspace: Workspace

    var body: some View {
        let monacoProfile = MonacoEditorProfile(from: profile)
        let snapshot = workspace.engine.editorFSSnapshot.map { MonacoFSSnapshot(from: $0) }

        var editor = SwiftyMonaco(text: $text, profile: monacoProfile)
            .fsSnapshot(snapshot)

        if let introspector {
            editor = editor.introspector(introspector)
        }

        return editor.task {
            await workspace.engine.rebuildEditorFSSnapshotIfNeeded()
        }
    }
}
