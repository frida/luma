struct SmalltalkToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case comment
        case string
        case symbol
        case character
        case number
        case identifier
        case keyword
        case binary
        case punctuation
    }

    let kind: Kind
    let utf16Range: Range<Int>
}

/// Reads Smalltalk as far as telling its tokens apart takes: where a string, a
/// comment or a character literal ends, so a bracket inside one is not taken for
/// one that nests.
enum SmalltalkLexer {
    static func tokenize(_ units: [UTF16.CodeUnit]) -> [SmalltalkToken] {
        var tokens: [SmalltalkToken] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            if isWhitespace(unit) {
                index += 1
                continue
            }
            let start = index
            let kind: SmalltalkToken.Kind
            switch unit {
            case quote:
                index = endOfQuoted(units, after: index, terminator: quote)
                kind = .comment
            case apostrophe:
                index = endOfQuoted(units, after: index, terminator: apostrophe)
                kind = .string
            case dollar:
                index = min(index + 1 + codePointLength(units, at: index + 1), units.count)
                kind = .character
            case hash:
                (index, kind) = endOfHash(units, at: index)
            case colon where index + 1 < units.count && units[index + 1] == equals:
                index += 2
                kind = .punctuation
            case _ where isLetter(unit):
                index = endOfIdentifier(units, from: index)
                if index < units.count, units[index] == colon, index + 1 >= units.count || units[index + 1] != equals {
                    index += 1
                    kind = .keyword
                } else {
                    kind = .identifier
                }
            case _ where isDigit(unit):
                index = endOfNumber(units, from: index)
                kind = .number
            case _ where isBinary(unit):
                while index < units.count, isBinary(units[index]) { index += 1 }
                kind = .binary
            default:
                index += codePointLength(units, at: index)
                kind = .punctuation
            }
            tokens.append(SmalltalkToken(kind: kind, utf16Range: start..<index))
        }
        return tokens
    }

    private static func endOfQuoted(_ units: [UTF16.CodeUnit], after open: Int, terminator: UTF16.CodeUnit) -> Int {
        var index = open + 1
        while index < units.count {
            if units[index] == terminator {
                guard index + 1 < units.count, units[index + 1] == terminator else { return index + 1 }
                index += 2
            } else {
                index += 1
            }
        }
        return units.count
    }

    private static func endOfHash(_ units: [UTF16.CodeUnit], at hashIndex: Int) -> (Int, SmalltalkToken.Kind) {
        let next = hashIndex + 1
        guard next < units.count else { return (next, .punctuation) }
        let unit = units[next]
        if unit == apostrophe {
            return (endOfQuoted(units, after: next, terminator: apostrophe), .symbol)
        }
        if isLetter(unit) {
            var index = next
            while index < units.count, isLetter(units[index]) || isDigit(units[index]) || units[index] == colon {
                index += 1
            }
            return (index, .symbol)
        }
        if isBinary(unit) {
            var index = next
            while index < units.count, isBinary(units[index]) { index += 1 }
            return (index, .symbol)
        }
        return (next, .punctuation)
    }

    private static func endOfIdentifier(_ units: [UTF16.CodeUnit], from start: Int) -> Int {
        var index = start
        while index < units.count, isLetter(units[index]) || isDigit(units[index]) { index += 1 }
        return index
    }

    private static func endOfNumber(_ units: [UTF16.CodeUnit], from start: Int) -> Int {
        var index = start
        while index < units.count {
            let unit = units[index]
            if isLetter(unit) || isDigit(unit) {
                index += 1
            } else if unit == period, index + 1 < units.count, isDigit(units[index + 1]) {
                index += 2
            } else {
                break
            }
        }
        return index
    }

    private static func codePointLength(_ units: [UTF16.CodeUnit], at index: Int) -> Int {
        guard index < units.count else { return 0 }
        return UTF16.isLeadSurrogate(units[index]) && index + 1 < units.count ? 2 : 1
    }

    private static func isWhitespace(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C
    }

    private static func isLetter(_ unit: UTF16.CodeUnit) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
    }

    private static func isDigit(_ unit: UTF16.CodeUnit) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private static func isBinary(_ unit: UTF16.CodeUnit) -> Bool {
        binaryCharacters.contains(unit)
    }

    private static let binaryCharacters: Set<UTF16.CodeUnit> = Set("+-*/\\~<>=@%|&?,!".utf16)
    private static let quote = UTF16.CodeUnit(0x22)
    private static let apostrophe = UTF16.CodeUnit(0x27)
    private static let dollar = UTF16.CodeUnit(0x24)
    private static let hash = UTF16.CodeUnit(0x23)
    private static let colon = UTF16.CodeUnit(0x3A)
    private static let equals = UTF16.CodeUnit(0x3D)
    private static let period = UTF16.CodeUnit(0x2E)
}
