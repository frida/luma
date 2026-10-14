import Foundation

extension Engine {
    func answerPharoSessionRequest(_ operation: String, _ request: [String: Any]) async throws -> Any {
        func node() throws -> ProcessNode { try pharoNode(of: request) }
        switch operation {
        case "modules":
            return try node().modules.map(\.pharoJSON)
        case "threads":
            return try node().threads.map(\.pharoJSON)
        case "module_functions":
            return try await moduleFunctionsForPharo(request, in: try node())
        case "resolve":
            return try await node().resolveTargets(
                scope: try pharoArgument("scope", of: request), query: try pharoArgument("query", of: request)
            ).compactMap(Self.pharoFunction)
        case "symbolicate":
            let addresses: [NSNumber] = try pharoArgument("addresses", of: request)
            return try await node().symbolicate(addresses: addresses.map(\.uint64Value)).map { Self.pharoNullable($0?.pharoJSON) }
        case "range_at":
            return Self.pharoNullable(try await node().findRangeByAddress(try pharoAddress(of: request))?.pharoJSON)
        case "thread_snapshot":
            let id: NSNumber = try pharoArgument("thread", of: request)
            return Self.pharoNullable(try await node().fetchThreadSnapshot(id: id.uintValue)?.pharoJSON)
        case "disassemble":
            return try await disassembleForPharo(request, in: try node())
        case "evaluate_js":
            return try await node().evaluateJavaScript(try pharoArgument("source", of: request)).pharoJSON
        case "read_memory":
            let count: Int = try pharoArgument("count", of: request)
            return Data(try await node().readRemoteMemory(at: try pharoAddress(of: request), count: count)).base64EncodedString()
        default:
            throw PharoAsyncBridgeError.unknownOperation(operation)
        }
    }

    private static func pharoNullable(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    private func moduleFunctionsForPharo(_ request: [String: Any], in node: ProcessNode) async throws -> [[String: Any]] {
        let name: String = try pharoArgument("module", of: request)
        guard let module = node.modules.first(where: { $0.name == name }) else {
            throw PharoAsyncBridgeError.missingArgument("module")
        }
        return try await node.enumerateModuleFunctions(name: name).map {
            ["name": $0.name, "address": module.base + $0.offset, "detail": $0.source.rawValue]
        }
    }

    private static func pharoFunction(of target: [String: Any]) -> [String: Any]? {
        guard let name = target["displayName"] as? String,
            let text = target["address"] as? String,
            let address = UInt64(text.dropFirst(2), radix: 16)
        else { return nil }
        return ["name": name, "address": address, "detail": target["detail"] as? String ?? ""]
    }

    private func disassembleForPharo(_ request: [String: Any], in node: ProcessNode) async throws -> [[String: String]] {
        guard let disassembler = disassembler(forSessionID: node.sessionID) else { throw PatternMemoryError.detached }
        let count: Int = try pharoArgument("count", of: request)
        let lines = await disassembler.disassemble(
            DisassemblyRequest(address: try pharoAddress(of: request), count: count, appearance: .light))
        return lines.map {
            [
                "address": $0.addressText.plainText,
                "bytes": $0.bytesText.plainText,
                "asm": $0.asmText.plainText,
                "comment": $0.commentText?.plainText ?? "",
            ]
        }
    }
}

extension ProcessModule {
    fileprivate var pharoJSON: [String: Any] {
        ["name": name, "path": path, "base": base, "size": size]
    }
}

extension ProcessThread {
    fileprivate var pharoJSON: [String: Any] {
        ["id": id, "name": name ?? NSNull(), "entrypoint": entrypoint?.routine ?? NSNull()]
    }
}

extension SymbolicateResult {
    fileprivate var pharoJSON: [String: Any] {
        [
            "module": module,
            "name": name,
            "offset": offset ?? NSNull(),
            "file": source?.file ?? NSNull(),
            "line": source?.line ?? NSNull(),
        ]
    }
}

extension ProcessNode.ProcessRange {
    fileprivate var pharoJSON: [String: Any] {
        ["base": base, "size": size, "protection": protection, "path": filePath ?? NSNull()]
    }
}

extension ThreadSnapshot {
    fileprivate var pharoJSON: [String: Any] {
        [
            "id": id,
            "name": name ?? NSNull(),
            "state": state,
            "registers": registers.map { ["name": $0.name, "value": $0.rawValue] },
        ]
    }
}

extension JSInspectValue {
    fileprivate var pharoJSON: Any {
        get throws {
            switch self {
            case .number(let value):
                return value.rounded() == value && value.magnitude < 9_007_199_254_740_992 ? Int64(value) : value
            case .string(let value), .nativePointer(let value), .bigInt(let value), .function(let value),
                .symbol(let value), .date(let value):
                return value
            case .boolean(let value):
                return value
            case .null, .undefined, .promise, .weakMap, .weakSet, .depthLimit, .circular:
                return NSNull()
            case .object(_, let properties), .map(_, let properties):
                return try Dictionary(
                    properties.map { (try $0.key.pharoKey, try $0.value.pharoJSON) }, uniquingKeysWith: { _, last in last })
            case .array(_, let elements), .set(_, let elements):
                return try elements.map { try $0.pharoJSON }
            case .bytes(let bytes):
                return bytes.data.base64EncodedString()
            case .regExp(let pattern, let flags):
                return "/\(pattern)/\(flags)"
            case .error(let name, let message, _):
                throw PharoEvaluationFailure(name: name, message: message)
            }
        }
    }

    private var pharoKey: String {
        get throws {
            switch self {
            case .string(let value):
                return value
            default:
                return String(describing: try pharoJSON)
            }
        }
    }
}

struct PharoEvaluationFailure: LocalizedError {
    let name: String
    let message: String

    var errorDescription: String? {
        "\(name): \(message)"
    }
}
