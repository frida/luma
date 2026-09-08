import Foundation

public struct TypeScriptToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case keyword
        case identifier
        case number
        case string
        case template
        case regex
        case comment
        case punctuation
    }

    public let kind: Kind
    public let utf16Range: Range<Int>
}

public enum TypeScriptLexer {
    public static func tokenize(_ text: String) -> [TypeScriptToken] {
        var scanner = Scanner(units: Array(text.utf16))
        var tokens: [TypeScriptToken] = []
        while let token = scanner.next() {
            tokens.append(token)
        }
        return tokens
    }
}

private struct Scanner {
    let units: [UInt16]
    var position = 0
    var previous: TypeScriptToken?

    init(units: [UInt16]) {
        self.units = units
    }

    mutating func next() -> TypeScriptToken? {
        skipWhitespace()
        guard position < units.count else { return nil }
        let start = position
        let kind = scanToken()
        let token = TypeScriptToken(kind: kind, utf16Range: start..<position)
        if kind != .comment {
            previous = token
        }
        return token
    }

    private mutating func skipWhitespace() {
        while position < units.count, isWhitespace(units[position]) {
            position += 1
        }
    }

    private mutating func scanToken() -> TypeScriptToken.Kind {
        let unit = units[position]
        if unit == Ascii.slash, peek(1) == Ascii.slash {
            scanLineComment()
            return .comment
        }
        if unit == Ascii.slash, peek(1) == Ascii.asterisk {
            scanBlockComment()
            return .comment
        }
        if unit == Ascii.doubleQuote || unit == Ascii.singleQuote {
            scanString(quote: unit)
            return .string
        }
        if unit == Ascii.backtick {
            scanTemplate()
            return .template
        }
        if unit == Ascii.slash, regexMayStart() {
            scanRegex()
            return .regex
        }
        if isDigit(unit) || (unit == Ascii.dot && isDigit(peek(1))) {
            scanNumber()
            return .number
        }
        if isIdentifierStart(unit) {
            return scanWord()
        }
        position += 1
        return .punctuation
    }

    private mutating func scanLineComment() {
        while position < units.count, !isLineBreak(units[position]) {
            position += 1
        }
    }

    private mutating func scanBlockComment() {
        position += 2
        while position < units.count {
            if units[position] == Ascii.asterisk, peek(1) == Ascii.slash {
                position += 2
                return
            }
            position += 1
        }
    }

    private mutating func scanString(quote: UInt16) {
        position += 1
        while position < units.count {
            let unit = units[position]
            if unit == Ascii.backslash {
                position += 2
                continue
            }
            if unit == quote {
                position += 1
                return
            }
            if isLineBreak(unit) {
                return
            }
            position += 1
        }
    }

    private mutating func scanTemplate() {
        position += 1
        while position < units.count {
            let unit = units[position]
            if unit == Ascii.backslash {
                position += 2
                continue
            }
            if unit == Ascii.backtick {
                position += 1
                return
            }
            if unit == Ascii.dollar, peek(1) == Ascii.openBrace {
                position += 2
                skipTemplateExpression()
                continue
            }
            position += 1
        }
    }

    private mutating func skipTemplateExpression() {
        var depth = 1
        while position < units.count, depth > 0 {
            let unit = units[position]
            switch unit {
            case Ascii.openBrace:
                depth += 1
                position += 1
            case Ascii.closeBrace:
                depth -= 1
                position += 1
            case Ascii.doubleQuote, Ascii.singleQuote:
                scanString(quote: unit)
            case Ascii.backtick:
                scanTemplate()
            default:
                position += 1
            }
        }
    }

    private func regexMayStart() -> Bool {
        guard let previous else { return true }
        switch previous.kind {
        case .identifier, .number, .string, .template, .regex:
            return false
        case .keyword:
            return !valueKeywords.contains(word(of: previous))
        case .punctuation:
            let last = units[previous.utf16Range.upperBound - 1]
            return last != Ascii.closeParen && last != Ascii.closeBracket && last != Ascii.closeBrace
        case .comment:
            return true
        }
    }

    private mutating func scanRegex() {
        position += 1
        var inClass = false
        while position < units.count {
            let unit = units[position]
            if unit == Ascii.backslash {
                position += 2
                continue
            }
            if isLineBreak(unit) {
                return
            }
            position += 1
            if unit == Ascii.openBracket {
                inClass = true
            } else if unit == Ascii.closeBracket {
                inClass = false
            } else if unit == Ascii.slash, !inClass {
                break
            }
        }
        while position < units.count, isIdentifierPart(units[position]) {
            position += 1
        }
    }

    private mutating func scanNumber() {
        while position < units.count, isNumberPart(units[position]) {
            position += 1
        }
    }

    private mutating func scanWord() -> TypeScriptToken.Kind {
        let start = position
        while position < units.count, isIdentifierPart(units[position]) {
            position += 1
        }
        let token = TypeScriptToken(kind: .identifier, utf16Range: start..<position)
        return keywords.contains(word(of: token)) ? .keyword : .identifier
    }

    private func word(of token: TypeScriptToken) -> String {
        String(utf16CodeUnits: Array(units[token.utf16Range]), count: token.utf16Range.count)
    }

    private func peek(_ distance: Int) -> UInt16 {
        let index = position + distance
        return index < units.count ? units[index] : 0
    }
}

private let keywords: Set<String> = [
    "abstract", "any", "as", "asserts", "async", "await", "bigint", "boolean", "break", "case", "catch", "class",
    "const", "constructor", "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export",
    "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in",
    "infer", "instanceof", "interface", "is", "keyof", "let", "module", "namespace", "never", "new", "null",
    "number", "object", "of", "override", "package", "private", "protected", "public", "readonly", "require",
    "return", "satisfies", "set", "static", "string", "super", "switch", "symbol", "this", "throw", "true",
    "try", "type", "typeof", "undefined", "unique", "unknown", "var", "void", "while", "with", "yield",
]

private let valueKeywords: Set<String> = ["this", "super", "null", "true", "false", "undefined"]

private enum Ascii {
    static let slash: UInt16 = 0x2F
    static let asterisk: UInt16 = 0x2A
    static let doubleQuote: UInt16 = 0x22
    static let singleQuote: UInt16 = 0x27
    static let backtick: UInt16 = 0x60
    static let backslash: UInt16 = 0x5C
    static let dollar: UInt16 = 0x24
    static let dot: UInt16 = 0x2E
    static let openBrace: UInt16 = 0x7B
    static let closeBrace: UInt16 = 0x7D
    static let closeParen: UInt16 = 0x29
    static let openBracket: UInt16 = 0x5B
    static let closeBracket: UInt16 = 0x5D
}

private func isWhitespace(_ unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C || unit == 0xA0
}

private func isLineBreak(_ unit: UInt16) -> Bool {
    unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
}

private func isDigit(_ unit: UInt16) -> Bool {
    unit >= 0x30 && unit <= 0x39
}

private func isNumberPart(_ unit: UInt16) -> Bool {
    isDigit(unit) || isLetter(unit) || unit == Ascii.dot || unit == 0x5F
}

private func isLetter(_ unit: UInt16) -> Bool {
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
}

private func isIdentifierStart(_ unit: UInt16) -> Bool {
    isLetter(unit) || unit == 0x5F || unit == Ascii.dollar || unit >= 0x80
}

private func isIdentifierPart(_ unit: UInt16) -> Bool {
    isIdentifierStart(unit) || isDigit(unit)
}
