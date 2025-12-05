import SwiftUI

extension JSInspectValue {
    var inlineDescription: String {
        switch self {
        case .number(let n):
            if n.rounded(.towardZero) == n {
                return String(Int(n))
            } else {
                return String(n)
            }

        case .string(let s):
            let maxLen = 80
            let body = s.count > maxLen ? s.prefix(maxLen) + "…" : Substring(s)
            return "\"\(body)\""

        case .object(_, let props):
            return "Object{\(props.count)}"

        case .array(_, let items):
            return "Array[\(items.count)]"

        case .nativePointer(let s):
            return s

        case .null:
            return "null"

        case .boolean(let b):
            return b ? "true" : "false"

        case .bytes(let bytes):
            return "Bytes(\(bytes.kind.rawValue)[\(bytes.data.count)])"

        case .function(let sig):
            return sig

        case .error(let name, let message, _):
            if message.isEmpty {
                return name
            } else {
                return "\(name): \(message)"
            }

        case .undefined:
            return "undefined"

        case .bigInt(let s):
            return s + "n"

        case .symbol(let t):
            return t

        case .date(let s):
            return "Date(\(s))"

        case .regExp(let pattern, let flags):
            return "/\(pattern)/\(flags)"

        case .map(_, let entries):
            return "Map{\(entries.count)}"

        case .set(_, let items):
            return "Set{\(items.count)}"

        case .promise:
            return "Promise"

        case .weakMap:
            return "WeakMap"

        case .weakSet:
            return "WeakSet"

        case .depthLimit(let container):
            switch container {
            case .object: return "Object<… depth limit …>"
            case .array: return "Array<… depth limit …>"
            case .map: return "Map<… depth limit …>"
            case .set: return "Set<… depth limit …>"
            }

        case .circular(let id):
            return "⟳ circular *\(id)"
        }
    }

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
                s = String(Int(n))
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

extension JSInspectValue.Property {
    var displayKey: String {
        switch key {
        case .string(let s):
            return s
        case .symbol(let t):
            return t
        default:
            return key.inlineDescription
        }
    }
}
