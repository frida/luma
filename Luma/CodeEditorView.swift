import SwiftUI
import SwiftyMonaco

struct CodeEditorView: View {
    @Binding var text: String
    let profile: MonacoEditorProfile
    var introspector: MonacoIntrospector? = nil

    var body: some View {
        var editor = SwiftyMonaco(text: $text, profile: profile)

        if let introspector {
            editor = editor.introspector(introspector)
        }

        return editor
    }
}
