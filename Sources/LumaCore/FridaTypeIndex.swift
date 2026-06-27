import Foundation

enum FridaTypeIndex {
    static func detail(for member: String) -> String? {
        index[member]
    }

    private static let index: [String: String] = build()

    private static func build() -> [String: String] {
        var details: [String: String] = [:]
        var ambiguous: Set<String> = []
        for file in TypeScriptTypings.fridaGum {
            parse(file.content, into: &details, ambiguous: &ambiguous)
        }
        for name in ambiguous {
            details.removeValue(forKey: name)
        }
        return details
    }

    private static func parse(_ content: String, into details: inout [String: String], ambiguous: inout Set<String>) {
        var pendingDoc: String?
        var docSummary: String?
        var paragraphEnded = false
        var inDoc = false
        var container: String?

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if !inDoc {
                if let opened = topLevelContainer(rawLine) {
                    container = opened
                } else if rawLine == "}" {
                    container = nil
                }
            }

            if inDoc {
                if trimmed.contains("*/") {
                    inDoc = false
                    pendingDoc = docSummary.map(firstSentence)
                    continue
                }
                let body = trimmed.drop(while: { $0 == "*" || $0 == " " }).trimmingCharacters(in: .whitespaces)
                if body.isEmpty || body.hasPrefix("@") {
                    paragraphEnded = docSummary != nil
                } else if !paragraphEnded {
                    docSummary = docSummary.map { "\($0) \(body)" } ?? body
                }
                continue
            }

            if trimmed.hasPrefix("/**") {
                docSummary = nil
                paragraphEnded = false
                inDoc = !trimmed.contains("*/")
                if !inDoc {
                    pendingDoc = singleLineDoc(trimmed).map(firstSentence)
                }
                continue
            }

            if let (name, signature) = memberDeclaration(trimmed) {
                let detail = pendingDoc ?? signature
                record(name: name, detail: detail, into: &details, ambiguous: &ambiguous)
                if let container {
                    record(name: "\(container).\(name)", detail: detail, into: &details, ambiguous: &ambiguous)
                }
            }
            pendingDoc = nil
            docSummary = nil
        }
    }

    private static func record(name: String, detail: String, into details: inout [String: String], ambiguous: inout Set<String>) {
        guard !detail.isEmpty, !ambiguous.contains(name) else { return }
        if let existing = details[name] {
            if existing != detail {
                ambiguous.insert(name)
                details.removeValue(forKey: name)
            }
        } else {
            details[name] = detail
        }
    }

    private static func memberDeclaration(_ line: String) -> (name: String, detail: String)? {
        if let match = functionPattern.firstCapture(in: line) {
            let signature = match.rest.contains(")") ? cleanSignature(match.rest) : ""
            return (match.name, signature)
        }
        guard line.hasSuffix(";") else { return nil }
        if let match = memberPattern.firstCapture(in: line), !reservedNames.contains(match.name) {
            return (match.name, cleanSignature(match.rest))
        }
        return nil
    }

    private static func firstSentence(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let stop = collapsed.range(of: ". ") {
            return String(collapsed[..<stop.lowerBound]) + "."
        }
        return collapsed
    }

    private static func singleLineDoc(_ line: String) -> String? {
        guard let open = line.range(of: "/**"), let close = line.range(of: "*/") else { return nil }
        let inner = line[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: CharacterSet(charactersIn: " *"))
        return inner.isEmpty ? nil : inner
    }

    private static func cleanSignature(_ signature: String) -> String {
        var s = signature.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(";") { s.removeLast() }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if s.count > 120 {
            s = String(s.prefix(119)) + "…"
        }
        return s
    }

    private static let reservedNames: Set<String> = [
        "function", "interface", "namespace", "class", "type", "enum", "export",
        "declare", "import", "const", "let", "var", "extends", "implements",
        "return", "new", "typeof", "keyof", "readonly", "public", "private",
    ]

    private static func topLevelContainer(_ line: Substring) -> String? {
        guard let first = line.first, first.isLetter, line.hasSuffix("{") else { return nil }
        return containerPattern.firstCapture(in: String(line))?.name
    }

    private static let containerPattern = CapturePattern(
        #"^(?:export\s+|declare\s+)*(?:namespace|interface|class)\s+([A-Za-z_$][\w$]*)(.*)$"#
    )
    private static let functionPattern = CapturePattern(
        #"^(?:export\s+)?(?:declare\s+)?function\s+([A-Za-z_$][\w$]*)\s*(\(.*)$"#
    )
    private static let memberPattern = CapturePattern(
        #"^(?:export\s+|declare\s+|const\s+|let\s+|var\s+|readonly\s+|static\s+|get\s+|set\s+|public\s+)*([A-Za-z_$][\w$]*)\??\s*([:(].*)$"#
    )
}

private struct CapturePattern {
    private let regex: NSRegularExpression?

    init(_ pattern: String) {
        regex = try? NSRegularExpression(pattern: pattern)
    }

    func firstCapture(in string: String) -> (name: String, rest: String)? {
        guard let regex,
            let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
            match.numberOfRanges >= 3,
            let nameRange = Range(match.range(at: 1), in: string),
            let restRange = Range(match.range(at: 2), in: string)
        else { return nil }
        return (String(string[nameRange]), String(string[restRange]))
    }
}
