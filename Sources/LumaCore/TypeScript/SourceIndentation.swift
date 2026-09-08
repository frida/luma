import Foundation

public enum SourceIndentation {
    public static let unit = "    "

    public struct Newline: Equatable, Sendable {
        public let text: String
        public let caretOffset: Int
    }

    public static func newline(in text: String, atUTF16 caret: Int) -> Newline {
        let units = Array(text.utf16)
        let caret = min(caret, units.count)
        let lineStart = units[..<caret].lastIndex(where: { $0 == 0x0A || $0 == 0x0D }).map { $0 + 1 } ?? 0
        let base = leadingWhitespace(units[lineStart..<caret])
        let opensBlock = openDepth(of: text, from: lineStart, to: caret) > 0
        let inner = opensBlock ? base + unit : base
        if opensBlock, nextNonSpaceIsCloser(units, from: caret) {
            return Newline(text: "\n" + inner + "\n" + base, caretOffset: 1 + inner.utf16.count)
        }
        return Newline(text: "\n" + inner, caretOffset: 1 + inner.utf16.count)
    }

    public struct Reindent: Equatable, Sendable {
        public let range: Range<Int>
        public let replacement: String
        public let caretUTF16: Int
    }

    public static func reindent(in text: String, atUTF16 caret: Int) -> Reindent {
        let units = Array(text.utf16)
        let caret = min(caret, units.count)
        let lineStart = units[..<caret].lastIndex(where: { $0 == 0x0A || $0 == 0x0D }).map { $0 + 1 } ?? 0
        var leadEnd = lineStart
        while leadEnd < units.count, units[leadEnd] == 0x20 || units[leadEnd] == 0x09 {
            leadEnd += 1
        }
        let startsWithCloser = leadEnd < units.count
            && (units[leadEnd] == 0x29 || units[leadEnd] == 0x5D || units[leadEnd] == 0x7D)
        var base = ""
        var previousOpensBlock = false
        if lineStart > 0 {
            let previousLineEnd = lineStart - 1
            let previousLineStart = units[..<previousLineEnd].lastIndex(where: { $0 == 0x0A || $0 == 0x0D }).map { $0 + 1 } ?? 0
            base = leadingWhitespace(units[previousLineStart..<previousLineEnd])
            previousOpensBlock = openDepth(of: text, from: previousLineStart, to: previousLineEnd) > 0
        }
        var replacement = base + (previousOpensBlock ? unit : "")
        if startsWithCloser, replacement.utf16.count >= unit.utf16.count {
            replacement = String(replacement.dropLast(unit.count))
        }
        let existing = leadEnd - lineStart
        return Reindent(
            range: lineStart..<leadEnd,
            replacement: replacement,
            caretUTF16: caret + (replacement.utf16.count - existing))
    }

    public static func isReindentTrigger(in text: String, atUTF16 caret: Int) -> Bool {
        let units = Array(text.utf16)
        let caret = min(caret, units.count)
        let lineStart = units[..<caret].lastIndex(where: { $0 == 0x0A || $0 == 0x0D }).map { $0 + 1 } ?? 0
        var end = caret
        if end > lineStart, units[end - 1] == 0x29 || units[end - 1] == 0x5D || units[end - 1] == 0x7D {
            end -= 1
        }
        return units[lineStart..<end].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    public static func closerDedent(in text: String, atUTF16 caret: Int) -> Range<Int>? {
        let units = Array(text.utf16)
        let caret = min(caret, units.count)
        let lineStart = units[..<caret].lastIndex(where: { $0 == 0x0A || $0 == 0x0D }).map { $0 + 1 } ?? 0
        let lead = units[lineStart..<caret]
        guard !lead.isEmpty, lead.allSatisfy({ $0 == 0x20 }), lead.count >= unit.utf16.count else { return nil }
        return (caret - unit.utf16.count)..<caret
    }

    public static func backspaceDedent(in text: String, atUTF16 caret: Int) -> Range<Int>? {
        return closerDedent(in: text, atUTF16: caret)
    }

    private static func leadingWhitespace(_ line: ArraySlice<UInt16>) -> String {
        let run = line.prefix { $0 == 0x20 || $0 == 0x09 }
        return String(utf16CodeUnits: Array(run), count: run.count)
    }

    private static func openDepth(of text: String, from start: Int, to end: Int) -> Int {
        var depth = 0
        for token in TypeScriptLexer.tokenize(text) where token.kind == .punctuation {
            guard token.utf16Range.lowerBound >= start else { continue }
            guard token.utf16Range.lowerBound < end else { break }
            switch text.utf16[text.utf16.index(text.utf16.startIndex, offsetBy: token.utf16Range.lowerBound)] {
            case 0x28, 0x5B, 0x7B:
                depth += 1
            case 0x29, 0x5D, 0x7D:
                if depth > 0 { depth -= 1 }
            default:
                break
            }
        }
        return depth
    }

    private static func nextNonSpaceIsCloser(_ units: [UInt16], from caret: Int) -> Bool {
        var index = caret
        while index < units.count {
            let unit = units[index]
            if unit == 0x20 || unit == 0x09 {
                index += 1
                continue
            }
            return unit == 0x29 || unit == 0x5D || unit == 0x7D
        }
        return false
    }
}
