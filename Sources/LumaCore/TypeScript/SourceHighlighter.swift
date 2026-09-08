import Foundation

public struct SourceHighlightRun: Equatable, Sendable {
    public let range: Range<Int>
    public let color: RGBColor?
}

public enum SourceHighlighter {
    public static func runs(of code: String, semanticTokens: [SemanticToken], dark: Bool) -> [SourceHighlightRun] {
        let count = code.utf16.count
        var colors = [RGBColor?](repeating: nil, count: count)
        for token in TypeScriptLexer.tokenize(code) {
            guard let style = SourceSyntaxPalette.style(for: token.kind, dark: dark) else { continue }
            paint(&colors, token.utf16Range, style.color)
        }
        let lineMap = LineMap(text: code)
        for token in semanticTokens {
            guard let style = SourceSyntaxPalette.semanticStyle(for: token.type, modifiers: token.modifiers, dark: dark) else { continue }
            let lower = lineMap.utf16Offset(of: LSP.Position(line: token.line, character: token.character))
            paint(&colors, lower..<(lower + token.length), style.color)
        }
        return coalesce(colors)
    }

    private static func paint(_ colors: inout [RGBColor?], _ range: Range<Int>, _ color: RGBColor) {
        for index in max(0, range.lowerBound)..<min(colors.count, range.upperBound) {
            colors[index] = color
        }
    }

    private static func coalesce(_ colors: [RGBColor?]) -> [SourceHighlightRun] {
        var runs: [SourceHighlightRun] = []
        var index = 0
        while index < colors.count {
            let color = colors[index]
            var end = index + 1
            while end < colors.count, colors[end] == color {
                end += 1
            }
            runs.append(SourceHighlightRun(range: index..<end, color: color))
            index = end
        }
        return runs
    }
}

public enum HoverMarkdown {
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let isCode: Bool
    }

    public static func segments(_ markdown: String) -> [Segment] {
        markdown.components(separatedBy: "```").enumerated().compactMap { index, part in
            if index.isMultiple(of: 2) {
                let prose = part.trimmingCharacters(in: .whitespacesAndNewlines)
                return prose.isEmpty ? nil : Segment(text: prose, isCode: false)
            }
            return Segment(text: strippingLanguageLine(part), isCode: true)
        }
    }

    private static func strippingLanguageLine(_ block: String) -> String {
        var body = block
        if let newline = body.firstIndex(of: "\n") {
            let language = body[body.startIndex..<newline]
            if language.allSatisfy({ $0.isLetter || $0.isNumber }) {
                body = String(body[body.index(after: newline)...])
            }
        }
        return body.trimmingCharacters(in: .newlines)
    }
}
