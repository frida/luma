import Foundation

extension Engine {
    func answerPharoRequest(_ request: [String: Any]) async throws -> Any {
        guard let operation = request["op"] as? String else { throw PharoAsyncBridgeError.missingArgument("op") }
        switch operation {
        case "patterns":
            return await describePatternLibrary()
        case "pattern_source":
            return try librarySource(named: request).text
        case "check_pattern":
            return try await patternDecoder.summary(ofText: try argument("source", of: request)).jsonObject
        case "read_memory":
            return try await readMemoryForPharo(request)
        case "decode":
            return try await decodeForPharo(request)
        default:
            throw PharoAsyncBridgeError.unknownOperation(operation)
        }
    }

    private func readMemoryForPharo(_ request: [String: Any]) async throws -> String {
        guard let node = node(forSessionID: try sessionID(of: request)) else { throw PatternMemoryError.detached }
        let count: Int = try argument("count", of: request)
        return Data(try await node.readRemoteMemory(at: try address(of: request), count: count)).base64EncodedString()
    }

    private func decodeForPharo(_ request: [String: Any]) async throws -> PharoHeldResult {
        let text = try request["source"] as? String ?? librarySource(named: request).text
        let typeName = try await typeName(of: request, in: text)
        let address = try address(of: request)
        let decoding: PatternMemoryDecoding
        if let encoded = request["bytes"] as? String {
            guard let data = Data(base64Encoded: encoded) else { throw PharoAsyncBridgeError.missingArgument("bytes") }
            let value = try await patternDecoder.decode(
                text: text, typeName: typeName, data: data, address: address,
                arch: request["arch"] as? String ?? PatternDecoder.hostArch,
                platform: request["platform"] as? String ?? PatternDecoder.hostPlatform)
            decoding = PatternMemoryDecoding(value: value, data: data)
        } else {
            decoding = try await decodePattern(
                text: text, typeName: typeName, sessionID: try sessionID(of: request), address: address, byteCount: 0x200)
        }
        let id = PharoPatternRegistry.shared.register(
            PharoPatternDecoding(root: decoding.value, data: decoding.data, address: address))
        return PharoHeldResult(value: ["decode": id, "root": decoding.value.pharoJSON]) {
            PharoPatternRegistry.shared.release(id)
        }
    }

    private func librarySource(named request: [String: Any]) throws -> PatternSource {
        let id: String = try argument("pattern_id", of: request)
        guard let source = patterns.source(withID: id) else { throw PharoAsyncBridgeError.missingArgument("pattern_id") }
        return source
    }

    private func typeName(of request: [String: Any], in text: String) async throws -> String {
        if let typeName = request["type"] as? String {
            return typeName
        }
        guard let rootType = try await patternDecoder.summary(ofText: text).rootType else {
            throw PharoAsyncBridgeError.missingArgument("type")
        }
        return rootType
    }

    private func sessionID(of request: [String: Any]) throws -> UUID {
        guard let text = request["session"] as? String, let id = UUID(uuidString: text) else {
            throw PharoAsyncBridgeError.missingArgument("session")
        }
        return id
    }

    private func address(of request: [String: Any]) throws -> UInt64 {
        guard let number = request["address"] as? NSNumber else { throw PharoAsyncBridgeError.missingArgument("address") }
        return number.uint64Value
    }

    private func argument<T>(_ name: String, of request: [String: Any]) throws -> T {
        guard let value = request[name] as? T else { throw PharoAsyncBridgeError.missingArgument(name) }
        return value
    }
}

extension DecodedPattern {
    fileprivate var pharoJSON: [String: Any] {
        var object = projection(depth: 0, elementLimit: 0)
        object["node"] = nodeID
        let visibleFields = fields.filter { !$0.hidden }
        if !visibleFields.isEmpty {
            object["fields"] = visibleFields.map(\.pharoJSON)
        }
        if !elements.isEmpty {
            object["elements"] = elements.map(\.pharoJSON)
        }
        return object
    }
}
