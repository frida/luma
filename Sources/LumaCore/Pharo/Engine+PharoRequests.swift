import Foundation

extension Engine {
    func answerPharoRequest(_ request: [String: Any]) async throws -> Any {
        guard let operation = request["op"] as? String else { throw PharoAsyncBridgeError.missingArgument("op") }
        switch operation {
        case "sessions":
            return sessions.map { pharo.recordWithIcon(for: $0).json }
        case "notebook_entries":
            return notebookEntries.map { $0.recordForPharo.json }
        case "events":
            return try recentEventsForPharo(request)
        case "watch_events":
            return watchEventsForPharo(request)
        case "record_class":
            return try recordPharoClass(request)
        case "forget_class":
            return try forgetPharoClass(request)
        case "record_method":
            return try recordPharoMethod(request)
        case "forget_method":
            return try forgetPharoMethod(request)
        case "patterns":
            return await describePatternLibrary()
        case "pattern_source":
            return try librarySource(named: request).text
        case "check_pattern":
            return try await patternDecoder.summary(ofText: try pharoArgument("source", of: request)).jsonObject
        case "decode":
            return try await decodeForPharo(request)
        default:
            return try await answerPharoSessionRequest(operation, request)
        }
    }

    private func recentEventsForPharo(_ request: [String: Any]) throws -> [[String: Any]] {
        let limit: Int = try pharoArgument("limit", of: request)
        let matches = Self.pharoEventFilter(request)
        return eventLog.events.filter(matches).suffix(limit).map { $0.recordForPharo.json }
    }

    private func watchEventsForPharo(_ request: [String: Any]) -> PharoStreamedResult {
        let matches = Self.pharoEventFilter(request)
        let source = events
        return PharoStreamedResult(
            items: AsyncStream { continuation in
                let batches = PharoEventBatches(into: continuation)
                let forwarding = Task {
                    for await event in source where matches(event) {
                        await batches.add(event.recordForPharo)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in forwarding.cancel() }
            })
    }

    private static func pharoEventFilter(_ request: [String: Any]) -> (RuntimeEvent) -> Bool {
        let sessionID = (request["session"] as? String).flatMap(UUID.init)
        let hook = request["hook"] as? String
        return { event in
            if let sessionID, event.sessionID != sessionID { return false }
            if let hook, event.hookTag != hook { return false }
            return true
        }
    }

    private func decodeForPharo(_ request: [String: Any]) async throws -> PharoHeldResult {
        let text = try request["source"] as? String ?? librarySource(named: request).text
        let typeName = try await typeName(of: request, in: text)
        let address = try pharoAddress(of: request)
        let decoding: PatternMemoryDecoding
        if let encoded = request["bytes"] as? String {
            guard let data = Data(base64Encoded: encoded) else { throw PharoAsyncBridgeError.missingArgument("bytes") }
            let value = try await patternDecoder.decode(
                text: text, typeName: typeName, data: data, address: address,
                platform: request["platform"] as? String, arch: request["arch"] as? String)
            decoding = PatternMemoryDecoding(value: value, data: data)
        } else {
            decoding = try await decodePattern(
                text: text, typeName: typeName, sessionID: try pharoSessionID(of: request), address: address, byteCount: 0x200)
        }
        let id = PharoPatternRegistry.shared.register(
            PharoPatternDecoding(root: decoding.value, data: decoding.data, address: address))
        return PharoHeldResult(value: ["decode": id, "root": decoding.value.pharoJSON]) {
            PharoPatternRegistry.shared.release(id)
        }
    }

    private func librarySource(named request: [String: Any]) throws -> PatternSource {
        let id: String = try pharoArgument("pattern_id", of: request)
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

    func pharoNode(of request: [String: Any]) throws -> ProcessNode {
        guard let node = node(forSessionID: try pharoSessionID(of: request)) else { throw PatternMemoryError.detached }
        return node
    }

    func pharoSessionID(of request: [String: Any]) throws -> UUID {
        guard let text = request["session"] as? String, let id = UUID(uuidString: text) else {
            throw PharoAsyncBridgeError.missingArgument("session")
        }
        return id
    }

    func pharoAddress(of request: [String: Any]) throws -> UInt64 {
        guard let number = request["address"] as? NSNumber else { throw PharoAsyncBridgeError.missingArgument("address") }
        return number.uint64Value
    }

    func pharoArgument<T>(_ name: String, of request: [String: Any]) throws -> T {
        guard let value = request[name] as? T else { throw PharoAsyncBridgeError.missingArgument(name) }
        return value
    }
}

private actor PharoEventBatches {
    private let continuation: AsyncStream<Any>.Continuation
    private var pending: [PharoHostRecord] = []
    private var isFlushScheduled = false

    init(into continuation: AsyncStream<Any>.Continuation) {
        self.continuation = continuation
    }

    func add(_ record: PharoHostRecord) {
        pending.append(record)
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(16))
            await flush()
        }
    }

    private func flush() {
        continuation.yield(pending.map(\.json))
        pending = []
        isFlushScheduled = false
    }
}

extension RuntimeEvent {
    fileprivate var hookTag: String? {
        (sentPayload as? [String: Any])?["hook"] as? String
    }
}

extension DecodedPattern {
    fileprivate var pharoJSON: [String: Any] {
        var object = projection(depth: 0, elementLimit: 0)
        object["node"] = nodeID
        switch value {
        case .integer(let number)?:
            object["number"] = number
        case .unsigned(let number)?:
            object["number"] = number
        default:
            break
        }
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
