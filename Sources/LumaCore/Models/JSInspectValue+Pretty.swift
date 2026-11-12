import Foundation

extension JSInspectValue {
    public enum BytesPresentation {
        case summary
        case hexDump
    }

    public func prettyDescription(bytes bytesPresentation: BytesPresentation = .summary) -> String {
        var output = ""
        appendPretty(into: &output, indentLevel: 0, bytesPresentation: bytesPresentation)
        return output
    }

    public var inlineDescription: String {
        switch self {
        case .number(let n):
            if n.rounded(.towardZero) == n {
                return Int(exactly: n).map(String.init) ?? String(format: "%.0f", n)
            }
            return String(n)
        case .string(let s):
            return "\"\(escapeForInline(s))\""
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
            return message.isEmpty ? name : "\(name): \(message)"
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

    private func appendPretty(into output: inout String, indentLevel: Int, bytesPresentation: BytesPresentation) {
        let indent = String(repeating: "  ", count: indentLevel)
        let childIndent = String(repeating: "  ", count: indentLevel + 1)

        switch self {
        case .number, .string, .nativePointer, .null, .boolean, .undefined,
             .bigInt, .symbol, .date, .regExp, .promise, .weakMap, .weakSet,
             .depthLimit, .circular, .function:
            output += inlineDescription

        case .bytes(let bytes):
            output += inlineDescription
            if bytesPresentation == .hexDump, !bytes.data.isEmpty {
                for line in hexDump(bytes.data, baseAddress: bytes.address ?? 0).split(separator: "\n") {
                    output += "\n\(childIndent)\(line)"
                }
            }

        case .error(let name, let message, let stack):
            output += message.isEmpty ? name : "\(name): \(message)"
            if !stack.isEmpty {
                for line in stack.split(separator: "\n", omittingEmptySubsequences: false) {
                    output += "\n\(childIndent)\(line)"
                }
            }

        case .object(_, let props):
            if props.isEmpty {
                output += "{}"
                return
            }
            output += "{\n"
            for (idx, prop) in props.enumerated() {
                output += "\(childIndent)\(prop.displayKey): "
                prop.value.appendPretty(into: &output, indentLevel: indentLevel + 1, bytesPresentation: bytesPresentation)
                output += idx == props.count - 1 ? "\n" : ",\n"
            }
            output += "\(indent)}"

        case .array(_, let items):
            if items.isEmpty {
                output += "[]"
                return
            }
            output += "[\n"
            for (idx, item) in items.enumerated() {
                output += childIndent
                item.appendPretty(into: &output, indentLevel: indentLevel + 1, bytesPresentation: bytesPresentation)
                output += idx == items.count - 1 ? "\n" : ",\n"
            }
            output += "\(indent)]"

        case .map(_, let entries):
            if entries.isEmpty {
                output += "Map{}"
                return
            }
            output += "Map{\n"
            for (idx, entry) in entries.enumerated() {
                output += childIndent
                entry.key.appendPretty(into: &output, indentLevel: indentLevel + 1, bytesPresentation: bytesPresentation)
                output += " => "
                entry.value.appendPretty(into: &output, indentLevel: indentLevel + 1, bytesPresentation: bytesPresentation)
                output += idx == entries.count - 1 ? "\n" : ",\n"
            }
            output += "\(indent)}"

        case .set(_, let items):
            if items.isEmpty {
                output += "Set[]"
                return
            }
            output += "Set[\n"
            for (idx, item) in items.enumerated() {
                output += "\(childIndent)• "
                item.appendPretty(into: &output, indentLevel: indentLevel + 1, bytesPresentation: bytesPresentation)
                output += idx == items.count - 1 ? "\n" : ",\n"
            }
            output += "\(indent)]"
        }
    }
}

extension JSInspectValue.Property {
    public var displayKey: String {
        switch key {
        case .string(let s): return s
        case .symbol(let t): return t
        default: return key.inlineDescription
        }
    }
}

private let inlineStringMaxLength = 80

private func escapeForInline(_ s: String) -> String {
    var escaped = ""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": escaped += "\\\\"
        case "\"": escaped += "\\\""
        case "\n": escaped += "\\n"
        case "\r": escaped += "\\r"
        case "\t": escaped += "\\t"
        default:
            if scalar.value < 0x20 {
                escaped += String(format: "\\u%04x", scalar.value)
            } else {
                escaped += String(scalar)
            }
        }
    }
    if escaped.count > inlineStringMaxLength {
        return String(escaped.prefix(inlineStringMaxLength)) + "…"
    }
    return escaped
}
