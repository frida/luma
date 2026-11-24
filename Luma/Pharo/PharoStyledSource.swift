import SwiftUI
import SwiftyPharo

struct PharoStyledSource: View {
    let source: String
    var errorPosition: Int? = nil

    @State private var spans: [PharoStyleSpan] = []

    var body: some View {
        Text(styled)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            .task(id: source) { spans = await PharoRuntime.shared.styles(in: source, isMethod: false) ?? [] }
    }

    private var styled: AttributedString {
        var styled = AttributedString(source)
        for span in spans {
            guard let range = range(from: span.start - 1, to: span.stop, in: styled) else { continue }
            if let color = PlatformColor.pharoRun(lightHex: span.light, darkHex: span.dark) {
                styled[range].foregroundColor = Color(color)
            }
            if span.bold {
                styled[range].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        if let errorPosition {
            var dot = AttributedString("●")
            dot.foregroundColor = .red
            let offset = min(max(errorPosition - 1, 0), source.utf16.count)
            styled.insert(dot, at: index(at: offset, in: styled))
        }
        return styled
    }

    private func range(from start: Int, to end: Int, in styled: AttributedString) -> Range<AttributedString.Index>? {
        guard start < end, end <= source.utf16.count else { return nil }
        return index(at: start, in: styled)..<index(at: end, in: styled)
    }

    private func index(at utf16Offset: Int, in styled: AttributedString) -> AttributedString.Index {
        AttributedString.Index(String.Index(utf16Offset: utf16Offset, in: source), within: styled)!
    }
}
