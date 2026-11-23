/// A Tonel file split the way the image can read it: the image parses a method
/// or an expression at a time, and a Tonel file is neither. Its methods are
/// handed over one by one, and what frames them -- the class's definition, the
/// comment before it and each method's category -- as one expression made of
/// the same tokens at the same offsets.
struct TonelSource {
    let units: [UTF16.CodeUnit]
    let methods: [TonelMethod]
    let classes: [TonelClass]

    private let frameTokens: [SmalltalkToken]

    init(_ text: String) {
        units = Array(text.utf16)
        let tokens = SmalltalkLexer.tokenize(units)
        var methods: [TonelMethod] = []
        var frameTokens: [SmalltalkToken] = []
        var index = 0
        while index < tokens.count {
            if let (method, next) = Self.method(startingAt: index, in: tokens, units: units) {
                methods.append(method)
                frameTokens += tokens[index..<method.firstPatternToken]
                if let close = method.closeBracketToken {
                    frameTokens += [tokens[method.openBracketToken], tokens[close]]
                }
                index = next
            } else {
                frameTokens.append(tokens[index])
                index += 1
            }
        }
        self.methods = methods
        self.frameTokens = frameTokens
        classes = Self.classes(in: frameTokens, units: units)
    }

    func method(enclosingUTF16 offset: Int) -> TonelMethod? {
        methods.first { $0.source.contains(offset) || ($0.closeBracket == nil && offset == units.count) }
    }

    /// The method as the image compiles it: its pattern and body, with the
    /// brackets around the body blanked rather than removed, so an offset in
    /// it is the file's less the method's start.
    func methodSource(of method: TonelMethod) -> [UTF16.CodeUnit] {
        var source = Array(units[method.source])
        source[method.openBracket - method.source.lowerBound] = space
        if let close = method.closeBracket {
            source[close - method.source.lowerBound] = space
        }
        return source
    }

    /// The frame as an expression the image parses without fault: each literal
    /// and name stays where it stands as a statement of its own, the braces and
    /// brackets stay as the arrays and blocks they read as, the colons and
    /// commas give way to the periods between statements, and the methods'
    /// patterns and bodies are blanked.
    var frameExpression: [UTF16.CodeUnit] {
        var expression = units.map { isLineBreak($0) ? $0 : space }
        var statements: [SmalltalkToken] = []
        for token in frameTokens {
            switch FrameRole(of: token, in: units) {
            case .comment:
                expression.replaceSubrange(token.utf16Range, with: units[token.utf16Range])
            case .statement, .opener, .closer:
                expression.replaceSubrange(token.utf16Range, with: units[token.utf16Range])
                statements.append(token)
            case .separator:
                break
            }
        }
        separateStatements(statements, in: &expression)
        return expression
    }

    private func separateStatements(_ statements: [SmalltalkToken], in expression: inout [UTF16.CodeUnit]) {
        let comments = frameTokens.filter { $0.kind == .comment }.map(\.utf16Range)
        var previous: SmalltalkToken?
        for token in statements {
            defer { previous = token }
            guard let previous,
                FrameRole(of: previous, in: units).endsStatement,
                FrameRole(of: token, in: units).beginsStatement
            else { continue }
            let gap = previous.utf16Range.upperBound..<token.utf16Range.lowerBound
            let slot = gap.first { offset in
                (expression[offset] == space || isLineBreak(expression[offset])) && !comments.contains { $0.contains(offset) }
            }
            if let slot {
                expression[slot] = period
            }
        }
    }

    private static func method(
        startingAt index: Int,
        in tokens: [SmalltalkToken],
        units: [UTF16.CodeUnit]
    ) -> (TonelMethod, next: Int)? {
        func text(_ i: Int) -> String? {
            guard i < tokens.count else { return nil }
            return String(utf16CodeUnits: Array(units[tokens[i].utf16Range]), count: tokens[i].utf16Range.count)
        }
        guard tokens[index].kind == .identifier, let className = text(index) else { return nil }
        let side: TonelMethod.Side = text(index + 1) == "class" ? .classSide : .instanceSide
        let arrow = side == .classSide ? index + 2 : index + 1
        guard text(arrow) == ">>" else { return nil }
        let firstPatternToken = arrow + 1
        guard let openBracketToken = (firstPatternToken..<tokens.count).first(where: { tokens[$0].kind == .punctuation }),
            text(openBracketToken) == "["
        else { return nil }
        var depth = 0
        var closeBracketToken: Int?
        for i in openBracketToken..<tokens.count {
            switch text(i) {
            case "[":
                depth += 1
            case "]":
                depth -= 1
            default:
                continue
            }
            if depth == 0 {
                closeBracketToken = i
                break
            }
        }
        let pattern = (firstPatternToken..<openBracketToken).compactMap(text)
        let start = firstPatternToken < openBracketToken ? tokens[firstPatternToken] : tokens[openBracketToken]
        let end = closeBracketToken.map { tokens[$0].utf16Range.upperBound } ?? units.count
        let method = TonelMethod(
            className: className,
            side: side,
            selector: selector(of: pattern),
            source: start.utf16Range.lowerBound..<end,
            openBracket: tokens[openBracketToken].utf16Range.lowerBound,
            closeBracket: closeBracketToken.map { tokens[$0].utf16Range.lowerBound },
            firstPatternToken: firstPatternToken,
            openBracketToken: openBracketToken,
            closeBracketToken: closeBracketToken)
        return (method, (closeBracketToken ?? tokens.count - 1) + 1)
    }

    private static func selector(of pattern: [String]) -> String {
        guard let first = pattern.first else { return "" }
        guard first.hasSuffix(":") else { return first }
        return stride(from: 0, to: pattern.count, by: 2).map { pattern[$0] }.joined()
    }

    private static func classes(in frame: [SmalltalkToken], units: [UTF16.CodeUnit]) -> [TonelClass] {
        let texts = frame.map { String(utf16CodeUnits: Array(units[$0.utf16Range]), count: $0.utf16Range.count) }
        var classes: [TonelClass] = []
        var index = 0
        while index + 1 < frame.count {
            defer { index += 1 }
            guard ["Class", "Trait"].contains(texts[index]), texts[index + 1] == "{" else { continue }
            var definition = TonelClass(name: "")
            var key: String?
            var depth = 0
            for i in (index + 1)..<frame.count {
                let text = texts[i]
                switch (frame[i].kind, text) {
                case (.punctuation, "{"), (.punctuation, "["):
                    depth += 1
                case (.punctuation, "}"), (.punctuation, "]"):
                    depth -= 1
                    if depth == 1 { key = nil }
                case (.symbol, _) where depth == 1 && key == nil:
                    key = String(text.dropFirst())
                case (.string, _), (.symbol, _):
                    definition.take(Self.literalValue(text), for: key)
                    if depth == 1 { key = nil }
                default:
                    break
                }
                if depth == 0 {
                    index = i
                    break
                }
            }
            if !definition.name.isEmpty {
                classes.append(definition)
            }
        }
        return classes
    }

    private static func literalValue(_ text: String) -> String {
        var value = Substring(text)
        if value.hasPrefix("#") { value = value.dropFirst() }
        guard value.hasPrefix("'") else { return String(value) }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }

    private func isLineBreak(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x0A || unit == 0x0D
    }

    private let space = UTF16.CodeUnit(0x20)
    private let period = UTF16.CodeUnit(0x2E)
}

struct TonelMethod: Sendable {
    enum Side: Sendable {
        case instanceSide
        case classSide
    }

    let className: String
    let side: Side
    let selector: String
    /// From the selector pattern through the bracket that closes the body, or
    /// to the end of the file while that is still to be written.
    let source: Range<Int>
    let openBracket: Int
    let closeBracket: Int?

    fileprivate let firstPatternToken: Int
    fileprivate let openBracketToken: Int
    fileprivate let closeBracketToken: Int?
}

struct TonelClass: Sendable {
    var name: String
    var instanceVariables: [String] = []
    var classVariables: [String] = []
    var classInstanceVariables: [String] = []

    func variables(on side: TonelMethod.Side) -> [String] {
        switch side {
        case .instanceSide:
            return instanceVariables + classVariables
        case .classSide:
            return classInstanceVariables + classVariables
        }
    }

    fileprivate mutating func take(_ value: String, for key: String?) {
        switch key {
        case "name":
            name = value
        case "instVars":
            instanceVariables.append(value)
        case "classVars":
            classVariables.append(value)
        case "classInstVars":
            classInstanceVariables.append(value)
        default:
            break
        }
    }
}

private enum FrameRole {
    case comment
    case statement
    case opener
    case closer
    case separator

    init(of token: SmalltalkToken, in units: [UTF16.CodeUnit]) {
        switch token.kind {
        case .comment:
            self = .comment
        case .string, .symbol, .character, .number, .identifier:
            self = .statement
        case .punctuation where token.utf16Range.count == 1:
            switch units[token.utf16Range.lowerBound] {
            case 0x7B, 0x5B:
                self = .opener
            case 0x7D, 0x5D:
                self = .closer
            default:
                self = .separator
            }
        case .punctuation, .keyword, .binary:
            self = .separator
        }
    }

    var endsStatement: Bool {
        self == .statement || self == .closer
    }

    var beginsStatement: Bool {
        self == .statement || self == .opener
    }
}
