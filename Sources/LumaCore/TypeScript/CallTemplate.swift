import Foundation

public struct CallTemplate: Equatable, Sendable {
    public let text: String
    public let placeholders: [Range<Int>]

    public init(name: String, parameters: [String]) {
        var text = name + "("
        var placeholders: [Range<Int>] = []
        for (index, parameter) in parameters.enumerated() {
            if index > 0 {
                text += ", "
            }
            let start = text.utf16.count
            text += parameter
            placeholders.append(start..<text.utf16.count)
        }
        text += ")"
        self.text = text
        self.placeholders = placeholders
    }

    public var snippet: String {
        var snippet = ""
        var cursor = 0
        for (index, placeholder) in placeholders.enumerated() {
            snippet += text.utf16Substring(cursor..<placeholder.lowerBound)
            snippet += "${\(index + 1):" + text.utf16Substring(placeholder) + "}"
            cursor = placeholder.upperBound
        }
        snippet += text.utf16Substring(cursor..<text.utf16.count)
        return snippet + "$0"
    }
}

extension LSP.SignatureHelp {
    public var requiredParameterNames: [String] {
        activeParameters.filter { !$0.optional }.map(\.name)
    }

    private var activeParameters: [(name: String, optional: Bool)] {
        guard let signature = signatures.indices.contains(activeSignature ?? 0) ? signatures[activeSignature ?? 0] : signatures.first
        else { return [] }
        return (signature.parameters ?? []).map { parameter in
            switch parameter.label {
            case .text(let text): return describe(text)
            case .offsets(let start, let end): return describe(signature.label.utf16Substring(start..<end))
            }
        }
    }

    private func describe(_ label: String) -> (name: String, optional: Bool) {
        let raw = (label.split(separator: ":", maxSplits: 1).first.map(String.init) ?? label)
            .trimmingCharacters(in: .whitespaces)
        let optional = raw.hasSuffix("?") || raw.hasPrefix("...")
        return (raw.hasSuffix("?") ? String(raw.dropLast()) : raw, optional)
    }
}

extension String {
    public func utf16Substring(_ range: Range<Int>) -> String {
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        return String(utf16[start..<end]) ?? ""
    }
}
