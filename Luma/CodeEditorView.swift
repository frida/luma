import Combine
import LumaCore
import SwiftUI

struct CodeEditorView: View {
    @Binding var text: String
    let profile: EditorProfile
    var introspector: CodeIntrospector? = nil
    var focused: Binding<Bool>? = nil
    let engine: Engine

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        CodeTextEditor(text: $text, profile: profile, introspector: introspector, focused: focused, engine: engine)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(editorBorderColor)
                    .frame(height: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(editorBorderColor)
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(editorBorderColor)
                    .frame(height: 1)
                    .allowsHitTesting(false)
            }
    }

    private var editorBorderColor: Color {
        colorScheme == .dark
            ? Color(red: 0x2A / 255.0, green: 0x2B / 255.0, blue: 0x2C / 255.0)
            : Color(red: 0xF0 / 255.0, green: 0xF1 / 255.0, blue: 0xF2 / 255.0)
    }
}

@MainActor
final class CodeIntrospector: ObservableObject {
    weak var document: TypeScriptDocument?

    func topLevelSymbols() async -> [CodeSymbol] {
        guard let document, let symbols = try? await document.symbols() else { return [] }
        return symbols.map { CodeSymbol(text: $0.name, kind: $0.kind) }
    }
}

struct CodeSymbol: Hashable {
    let text: String
    let kind: Int
}
