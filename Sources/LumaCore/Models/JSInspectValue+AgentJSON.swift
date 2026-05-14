import Foundation

extension JSInspectValue {
    public struct AgentJSONOptions: Sendable {
        public let maxDepth: Int?
        public let maxStringLength: Int?
        public let maxBytesPreview: Int

        public init(maxDepth: Int? = nil, maxStringLength: Int? = nil, maxBytesPreview: Int = 1024) {
            self.maxDepth = maxDepth
            self.maxStringLength = maxStringLength
            self.maxBytesPreview = maxBytesPreview
        }

        public static let compact = AgentJSONOptions(maxDepth: 4, maxStringLength: 256, maxBytesPreview: 32)
        public static let full = AgentJSONOptions()
    }

    public func toAgentJSON(options: AgentJSONOptions = .full) -> Any {
        var state = AgentJSONState(options: options, circularTargets: circularTargetIDs())
        return encodeAgentJSON(depth: 0, state: &state)
    }

    public func agentSummary(maxLength: Int = 96, maxDepth: Int = 3) -> String {
        let rendered = renderAgentSummary(depth: 0, maxDepth: maxDepth)
        guard rendered.count > maxLength else { return rendered }
        let cut = rendered.index(rendered.startIndex, offsetBy: maxLength - 1)
        return rendered[..<cut] + "…"
    }

    private func renderAgentSummary(depth: Int, maxDepth: Int) -> String {
        if depth >= maxDepth, let kind = compositeKindName {
            return "[\(kind)…]"
        }

        switch self {
        case .number(let n):
            return n.isFinite ? formatSummaryNumber(n) : String(n)

        case .string(let s):
            return formatSummaryString(s, cap: 40)

        case .boolean(let b):
            return String(b)

        case .null:
            return "null"

        case .undefined:
            return "undefined"

        case .nativePointer(let s):
            return s

        case .bigInt(let s):
            return "\(s)n"

        case .date(let s):
            return "Date(\(s))"

        case .symbol(let s):
            return s

        case .function:
            return "function"

        case .regExp(let pattern, let flags):
            return "/\(pattern)/\(flags)"

        case .error(let name, let message, _):
            return "\(name)(\(formatSummaryString(message, cap: 40)))"

        case .bytes(let bytes):
            return "<\(bytes.kind.rawValue) \(bytes.data.count) bytes>"

        case .promise: return "Promise"
        case .weakMap: return "WeakMap"
        case .weakSet: return "WeakSet"

        case .depthLimit(let container):
            return "[\(containerKindName(container))…]"

        case .circular(let id):
            return "<ref \(id)>"

        case .object(_, let props):
            return renderSummaryObject(properties: props, depth: depth, maxDepth: maxDepth)

        case .array(_, let elements):
            return renderSummaryArray(elements: elements, depth: depth, maxDepth: maxDepth)

        case .map(_, let entries):
            return renderSummaryMap(entries: entries, depth: depth, maxDepth: maxDepth)

        case .set(_, let elements):
            let inner = elements.prefix(6).map { $0.renderAgentSummary(depth: depth + 1, maxDepth: maxDepth) }
            let ellipsis = elements.count > inner.count ? ", …" : ""
            return "Set{" + inner.joined(separator: ", ") + ellipsis + "}"
        }
    }

    private func renderSummaryObject(properties: [Property], depth: Int, maxDepth: Int) -> String {
        let shown = properties.prefix(6).map { prop -> String in
            let key = agentKeyString(prop.key)
            let value = prop.value.renderAgentSummary(depth: depth + 1, maxDepth: maxDepth)
            return "\(key): \(value)"
        }
        let ellipsis = properties.count > shown.count ? ", …" : ""
        return "{" + shown.joined(separator: ", ") + ellipsis + "}"
    }

    private func renderSummaryArray(elements: [JSInspectValue], depth: Int, maxDepth: Int) -> String {
        let shown = elements.prefix(8).map { $0.renderAgentSummary(depth: depth + 1, maxDepth: maxDepth) }
        let ellipsis = elements.count > shown.count ? ", …" : ""
        return "[" + shown.joined(separator: ", ") + ellipsis + "]"
    }

    private func renderSummaryMap(entries: [Property], depth: Int, maxDepth: Int) -> String {
        let shown = entries.prefix(6).map { entry -> String in
            let key = entry.key.renderAgentSummary(depth: depth + 1, maxDepth: maxDepth)
            let value = entry.value.renderAgentSummary(depth: depth + 1, maxDepth: maxDepth)
            return "\(key) => \(value)"
        }
        let ellipsis = entries.count > shown.count ? ", …" : ""
        return "Map{" + shown.joined(separator: ", ") + ellipsis + "}"
    }

    private func encodeAgentJSON(depth: Int, state: inout AgentJSONState) -> Any {
        if let maxDepth = state.options.maxDepth, depth >= maxDepth, let kind = compositeKindName {
            return ["$type": "Truncated", "reason": "depth", "kind": kind] as [String: Any]
        }

        switch self {
        case .number(let n):
            return n.isFinite ? (n as Any) : ["$type": "Number", "value": String(n)] as [String: Any]

        case .string(let s):
            return truncatedAgentString(s, maxLength: state.options.maxStringLength)

        case .boolean(let b):
            return b

        case .null:
            return NSNull()

        case .undefined:
            return ["$type": "Undefined"] as [String: Any]

        case .nativePointer(let s):
            return ["$type": "NativePointer", "value": s] as [String: Any]

        case .bigInt(let s):
            return ["$type": "BigInt", "value": s] as [String: Any]

        case .date(let s):
            return ["$type": "Date", "value": s] as [String: Any]

        case .symbol(let s):
            return ["$type": "JsSymbol", "value": s] as [String: Any]

        case .function(let s):
            let value = truncatedAgentString(s, maxLength: state.options.maxStringLength)
            return ["$type": "Function", "value": value] as [String: Any]

        case .regExp(let pattern, let flags):
            return ["$type": "RegExp", "pattern": pattern, "flags": flags] as [String: Any]

        case .error(let name, let message, let stack):
            var dict: [String: Any] = ["$type": "Error", "name": name, "message": message]
            if !stack.isEmpty {
                dict["stack"] = truncatedAgentString(stack, maxLength: state.options.maxStringLength)
            }
            return dict

        case .bytes(let bytes):
            return encodeAgentBytes(bytes, previewLimit: state.options.maxBytesPreview)

        case .promise:
            return ["$type": "Promise"] as [String: Any]

        case .weakMap:
            return ["$type": "WeakMap"] as [String: Any]

        case .weakSet:
            return ["$type": "WeakSet"] as [String: Any]

        case .depthLimit(let container):
            return ["$type": "Truncated", "reason": "depth", "kind": containerKindName(container)] as [String: Any]

        case .circular(let id):
            return ["$ref": id] as [String: Any]

        case .object(let id, let props):
            return encodeAgentObject(id: id, properties: props, depth: depth, state: &state)

        case .array(let id, let elements):
            return encodeAgentArray(id: id, elements: elements, depth: depth, state: &state)

        case .map(let id, let entries):
            return encodeAgentMap(id: id, entries: entries, depth: depth, state: &state)

        case .set(let id, let elements):
            return encodeAgentSet(id: id, elements: elements, depth: depth, state: &state)
        }
    }

    private func encodeAgentObject(id: Int, properties: [Property], depth: Int, state: inout AgentJSONState) -> Any {
        let needsIdentity = state.circularTargets.contains(id) && id != 0
        var dict: [String: Any] = [:]
        if needsIdentity {
            dict["$type"] = "Object"
            dict["$id"] = id
        }
        for prop in properties {
            let key = agentKeyString(prop.key)
            dict[key] = prop.value.encodeAgentJSON(depth: depth + 1, state: &state)
        }
        return dict
    }

    private func encodeAgentArray(id: Int, elements: [JSInspectValue], depth: Int, state: inout AgentJSONState) -> Any {
        let items = elements.map { $0.encodeAgentJSON(depth: depth + 1, state: &state) }
        if state.circularTargets.contains(id) && id != 0 {
            return ["$type": "Array", "$id": id, "items": items] as [String: Any]
        }
        return items
    }

    private func encodeAgentMap(id: Int, entries: [Property], depth: Int, state: inout AgentJSONState) -> Any {
        let pairs: [[Any]] = entries.map { entry in
            [
                entry.key.encodeAgentJSON(depth: depth + 1, state: &state),
                entry.value.encodeAgentJSON(depth: depth + 1, state: &state),
            ]
        }
        var dict: [String: Any] = ["$type": "Map", "entries": pairs]
        if state.circularTargets.contains(id) && id != 0 {
            dict["$id"] = id
        }
        return dict
    }

    private func encodeAgentSet(id: Int, elements: [JSInspectValue], depth: Int, state: inout AgentJSONState) -> Any {
        let values = elements.map { $0.encodeAgentJSON(depth: depth + 1, state: &state) }
        var dict: [String: Any] = ["$type": "Set", "values": values]
        if state.circularTargets.contains(id) && id != 0 {
            dict["$id"] = id
        }
        return dict
    }

    private func encodeAgentBytes(_ bytes: Bytes, previewLimit: Int) -> [String: Any] {
        let totalLength = bytes.data.count
        let previewSlice = bytes.data.prefix(previewLimit)
        var dict: [String: Any] = [
            "$type": bytes.kind.rawValue,
            "byteLength": totalLength,
            "base64": previewSlice.base64EncodedString(),
        ]
        if totalLength > previewSlice.count {
            dict["previewLength"] = previewSlice.count
        }
        return dict
    }

    private var compositeKindName: String? {
        switch self {
        case .object: return "object"
        case .array: return "array"
        case .map: return "map"
        case .set: return "set"
        default: return nil
        }
    }

    private func circularTargetIDs() -> Set<Int> {
        var ids: Set<Int> = []
        collectCircularTargetIDs(into: &ids)
        return ids
    }

    private func collectCircularTargetIDs(into ids: inout Set<Int>) {
        switch self {
        case .circular(let id):
            ids.insert(id)
        case .object(_, let props), .map(_, let props):
            for prop in props {
                prop.key.collectCircularTargetIDs(into: &ids)
                prop.value.collectCircularTargetIDs(into: &ids)
            }
        case .array(_, let elements), .set(_, let elements):
            for element in elements {
                element.collectCircularTargetIDs(into: &ids)
            }
        default:
            break
        }
    }
}

private struct AgentJSONState {
    let options: JSInspectValue.AgentJSONOptions
    let circularTargets: Set<Int>
}

private func truncatedAgentString(_ s: String, maxLength: Int?) -> Any {
    guard let maxLength, s.count > maxLength else { return s }
    let preview = String(s.prefix(maxLength))
    return [
        "$type": "TruncatedString",
        "preview": preview,
        "length": s.count,
    ] as [String: Any]
}

private func agentKeyString(_ key: JSInspectValue) -> String {
    switch key {
    case .string(let s): return s
    case .number(let n): return String(n)
    case .nativePointer(let s): return s
    case .bigInt(let s): return "\(s)n"
    case .symbol(let s): return s
    case .boolean(let b): return String(b)
    case .null: return "null"
    case .undefined: return "undefined"
    default: return "[\(key)]"
    }
}

private func containerKindName(_ kind: JSInspectValue.ContainerKind) -> String {
    switch kind {
    case .object: return "object"
    case .array: return "array"
    case .map: return "map"
    case .set: return "set"
    }
}

private func formatSummaryString(_ s: String, cap: Int) -> String {
    let trimmed = s.count > cap ? String(s.prefix(cap - 1)) + "…" : s
    return "\"\(trimmed)\""
}

private func formatSummaryNumber(_ n: Double) -> String {
    if n.rounded(.towardZero) == n && abs(n) < 1e16 {
        return String(Int64(n))
    }
    return String(n)
}
