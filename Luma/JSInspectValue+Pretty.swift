import SwiftUI
import LumaCore

extension JSInspectValue {
    func prettyAttributedDescription() -> AttributedString {
        var result = AttributedString()
        appendPretty(into: &result, indentLevel: 0)
        return result
    }

    private func appendPretty(into output: inout AttributedString, indentLevel: Int) {
        func appendIndent(_ level: Int) {
            guard level > 0 else { return }
            let indent = AttributedString(String(repeating: "  ", count: level))
            output += indent
        }

        func appendToken(_ text: String, color: Color? = nil) {
            var token = AttributedString(text)
            if let color {
                token.foregroundColor = color
            }
            output += token
        }

        switch self {
        case .number(let n):
            let s: String
            if n.rounded(.towardZero) == n {
                s = Int(exactly: n).map(String.init) ?? String(format: "%.0f", n)
            } else {
                s = String(n)
            }
            appendToken(s, color: .cyan)

        case .string(let s):
            appendToken("\"\(s)\"", color: .mint)

        case .object(_, let props):
            if props.isEmpty {
                appendToken("{}", color: .cyan)
                return
            }

            appendToken("{", color: .cyan)
            output += AttributedString("\n")

            for (idx, prop) in props.enumerated() {
                appendIndent(indentLevel + 1)
                appendToken(prop.displayKey, color: Color.green.opacity(0.85))
                appendToken(": ")
                prop.value.appendPretty(into: &output, indentLevel: indentLevel + 1)
                if idx != props.count - 1 {
                    appendToken(",")
                }
                output += AttributedString("\n")
            }

            appendIndent(indentLevel)
            appendToken("}", color: .cyan)

        case .array(_, let elements):
            if elements.isEmpty {
                appendToken("[]")
                return
            }

            appendToken("[")
            output += AttributedString("\n")

            for (idx, element) in elements.enumerated() {
                appendIndent(indentLevel + 1)
                element.appendPretty(into: &output, indentLevel: indentLevel + 1)
                if idx != elements.count - 1 {
                    appendToken(",")
                }
                output += AttributedString("\n")
            }

            appendIndent(indentLevel)
            appendToken("]")

        case .nativePointer(let s):
            appendToken(s, color: .orange)

        case .null:
            appendToken("null", color: .orange)

        case .boolean(let b):
            appendToken(b ? "true" : "false", color: .orange)

        case .bytes(let bytes):
            appendToken("Bytes(", color: .mint)
            appendToken(bytes.kind.rawValue, color: .cyan)
            appendToken("[\(bytes.data.count)])", color: .mint)

        case .function(let sig):
            appendToken(sig, color: .purple)

        case .error(let name, let message, let stack):
            let header: String
            if message.isEmpty {
                header = name
            } else {
                header = "\(name): \(message)"
            }
            appendToken(header, color: .red)
            if !stack.isEmpty {
                output += AttributedString("\n")
                let lines = stack.split(separator: "\n", omittingEmptySubsequences: false)
                for (idx, line) in lines.enumerated() {
                    if idx > 0 {
                        output += AttributedString("\n")
                    }
                    appendIndent(indentLevel + 1)
                    appendToken(String(line), color: .secondary)
                }
            }

        case .undefined:
            appendToken("undefined", color: .orange)

        case .bigInt(let s):
            appendToken(s + "n", color: .cyan)

        case .symbol(let t):
            appendToken(t, color: .purple)

        case .date(let s):
            appendToken("Date(", color: .blue)
            appendToken(s, color: .mint)
            appendToken(")", color: .blue)

        case .regExp(let pattern, let flags):
            appendToken("/", color: .purple)
            appendToken(pattern, color: .mint)
            appendToken("/", color: .purple)
            if !flags.isEmpty {
                appendToken(flags, color: .purple)
            }

        case .map(_, let entries):
            if entries.isEmpty {
                appendToken("Map{}", color: .cyan)
                return
            }

            appendToken("Map{", color: .cyan)
            output += AttributedString("\n")

            for (idx, entry) in entries.enumerated() {
                appendIndent(indentLevel + 1)
                entry.key.appendPretty(into: &output, indentLevel: indentLevel + 1)
                appendToken(" => ")
                entry.value.appendPretty(into: &output, indentLevel: indentLevel + 1)
                if idx != entries.count - 1 {
                    appendToken(",")
                }
                output += AttributedString("\n")
            }

            appendIndent(indentLevel)
            appendToken("}", color: .cyan)

        case .set(_, let elements):
            if elements.isEmpty {
                appendToken("Set[]", color: .cyan)
                return
            }

            appendToken("Set[", color: .cyan)
            output += AttributedString("\n")

            for (idx, element) in elements.enumerated() {
                appendIndent(indentLevel + 1)
                appendToken("• ", color: .cyan)
                element.appendPretty(into: &output, indentLevel: indentLevel + 1)
                if idx != elements.count - 1 {
                    output += AttributedString("\n")
                }
            }

            output += AttributedString("\n")
            appendIndent(indentLevel)
            appendToken("]", color: .cyan)

        case .promise:
            appendToken("Promise", color: .purple)

        case .weakMap:
            appendToken("WeakMap", color: .purple)

        case .weakSet:
            appendToken("WeakSet", color: .purple)

        case .depthLimit(let container):
            switch container {
            case .object:
                appendToken("Object<depth limit reached>", color: .orange)
            case .array:
                appendToken("Array<depth limit reached>", color: .orange)
            case .map:
                appendToken("Map<depth limit reached>", color: .orange)
            case .set:
                appendToken("Set<depth limit reached>", color: .orange)
            }

        case .circular(let id):
            appendToken("⟳ circular *\(id)", color: .orange)
        }
    }
}
