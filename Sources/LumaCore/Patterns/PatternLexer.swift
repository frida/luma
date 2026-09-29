import Foundation

public enum PatternLexer {
    public static func tokenize(_ text: String) -> [TypeScriptToken] {
        TypeScriptLexer.tokenize(text, keywords: keywords, allowsRegex: false)
    }

    private static let keywords: Set<String> = [
        "struct", "union", "enum", "bitfield", "fn", "namespace", "using", "import", "as", "if", "else", "while", "for",
        "match", "return", "break", "continue", "try", "catch", "in", "out", "ref", "auto", "const", "let", "padding",
        "null", "true", "false", "parent", "this", "sizeof", "addressof", "typenameof", "be", "le", "signed", "unsigned",
        "u8", "u16", "u24", "u32", "u48", "u64", "u96", "u128", "s8", "s16", "s24", "s32", "s48", "s64", "s96", "s128",
        "float", "double", "bool", "char", "char16", "str",
    ]
}
