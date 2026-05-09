import Foundation

public struct AnthropicProvider: LLMProvider {
    public static let providerID = "anthropic"
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    public let descriptor: LLMProviderDescriptor
    private let session: URLSession

    public init(session: URLSession = .shared, baseURL: URL = AnthropicProvider.defaultBaseURL) {
        self.session = session
        self.descriptor = LLMProviderDescriptor(
            id: Self.providerID,
            displayName: "Anthropic",
            capabilities: LLMProviderCapabilities(
                supportsStreaming: true,
                supportsPromptCaching: true,
                supportsThinking: true,
                supportsToolUse: true,
                requiresAPIKey: true,
                supportsCustomBaseURL: true
            ),
            defaultModelID: "claude-sonnet-4-6",
            defaultBaseURL: baseURL
        )
    }

    public func suggestedModels() -> [LLMModelInfo] {
        [
            LLMModelInfo(id: "claude-opus-4-7", displayName: "Claude Opus 4.7", contextWindow: 200_000, maxOutput: 32_000, supportsCaching: true, supportsThinking: true),
            LLMModelInfo(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", contextWindow: 200_000, maxOutput: 64_000, supportsCaching: true, supportsThinking: true),
            LLMModelInfo(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", contextWindow: 200_000, maxOutput: 8_192, supportsCaching: true, supportsThinking: false),
        ]
    }

    public func streamTurn(
        _ request: LLMTurnRequest,
        apiKey: String?,
        baseURL: URL?
    ) -> AsyncThrowingStream<LLMTurnEvent, Error> {
        AsyncThrowingStream<LLMTurnEvent, Error> { continuation in
            let work = Task<Void, Never> {
                do {
                    try await runStream(
                        request: request,
                        apiKey: apiKey,
                        baseURL: baseURL ?? descriptor.defaultBaseURL,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func runStream(
        request: LLMTurnRequest,
        apiKey: String?,
        baseURL: URL,
        continuation: AsyncThrowingStream<LLMTurnEvent, Error>.Continuation
    ) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey
        }

        var url = baseURL
        url.append(path: "/v1/messages")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")

        let body = try buildRequestBody(request)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.requestFailed(status: -1, message: "Invalid response")
        }
        if http.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody.append(line)
                errorBody.append("\n")
                if errorBody.count > 8192 { break }
            }
            throw LLMProviderError.requestFailed(status: http.statusCode, message: errorBody)
        }

        var state = SSEState()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                if let event = state.takeEvent() {
                    try dispatchEvent(event, into: continuation, accumulator: &state.accumulator)
                }
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                state.eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let payload = line.dropFirst("data:".count)
                let trimmed = payload.first == " " ? String(payload.dropFirst()) : String(payload)
                if state.dataBuffer.isEmpty {
                    state.dataBuffer = trimmed
                } else {
                    state.dataBuffer.append("\n")
                    state.dataBuffer.append(trimmed)
                }
            }
        }

        if state.accumulator.finalRole != nil {
            continuation.yield(.finalMessage(
                role: state.accumulator.finalRole ?? .assistant,
                blocks: state.accumulator.assembledBlocks()
            ))
        }
    }

    // MARK: - Request body

    private func buildRequestBody(_ request: LLMTurnRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": request.modelID,
            "max_tokens": request.maxOutputTokens,
            "stream": true,
        ]

        if !request.systemBlocks.isEmpty {
            body["system"] = encodeBlocksForSystem(request.systemBlocks)
        }

        body["messages"] = encodeMessages(request.messages)

        if !request.tools.isEmpty {
            body["tools"] = encodeTools(request.tools)
        }

        if request.thinkingBudget >= 1024 {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": request.thinkingBudget,
            ]
        }

        if let temperature = request.temperature {
            body["temperature"] = temperature
        }

        return body
    }

    private func encodeBlocksForSystem(_ blocks: [LLMContentBlock]) -> [[String: Any]] {
        blocks.map { block in
            var obj = encodeAnthropicBlock(block.content)
            if block.cacheBoundary {
                obj["cache_control"] = ["type": "ephemeral"]
            }
            return obj
        }
    }

    private func encodeMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        messages.map { message in
            [
                "role": message.role.rawValue,
                "content": message.blocks.map { block -> [String: Any] in
                    var obj = encodeAnthropicBlock(block.content)
                    if block.cacheBoundary {
                        obj["cache_control"] = ["type": "ephemeral"]
                    }
                    return obj
                },
            ]
        }
    }

    private func encodeTools(_ tools: [LLMToolSpec]) -> [[String: Any]] {
        tools.map { tool in
            var obj: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
            ]
            if let schema = try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) {
                obj["input_schema"] = schema
            } else {
                obj["input_schema"] = ["type": "object", "properties": [:]]
            }
            if tool.cacheBoundary {
                obj["cache_control"] = ["type": "ephemeral"]
            }
            return obj
        }
    }

    private func encodeAnthropicBlock(_ content: LLMContent) -> [String: Any] {
        switch content {
        case .text(let text):
            return ["type": "text", "text": text]
        case .toolUse(let id, let name, let inputJSON):
            let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) ?? [:]
            return ["type": "tool_use", "id": id, "name": name, "input": input]
        case .toolResult(let toolUseID, let contentJSON, let isError):
            var obj: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": toolUseID,
                "content": contentJSON,
            ]
            if isError { obj["is_error"] = true }
            return obj
        case .thinking(let text, let signature):
            var obj: [String: Any] = ["type": "thinking", "thinking": text]
            if !signature.isEmpty { obj["signature"] = signature }
            return obj
        case .redactedThinking(let data):
            return ["type": "redacted_thinking", "data": data]
        }
    }

    // MARK: - SSE parsing

    private struct SSEState {
        var eventName = ""
        var dataBuffer = ""
        var accumulator = ResponseAccumulator()

        mutating func takeEvent() -> SSEEvent? {
            guard !eventName.isEmpty || !dataBuffer.isEmpty else { return nil }
            let event = SSEEvent(name: eventName, data: dataBuffer)
            eventName = ""
            dataBuffer = ""
            return event
        }
    }

    private struct SSEEvent {
        let name: String
        let data: String
    }

    private func dispatchEvent(
        _ event: SSEEvent,
        into continuation: AsyncThrowingStream<LLMTurnEvent, Error>.Continuation,
        accumulator: inout ResponseAccumulator
    ) throws {
        guard let payload = event.data.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            return
        }

        switch event.name {
        case "message_start":
            if let message = object["message"] as? [String: Any] {
                if let role = message["role"] as? String, let parsed = LLMRole(rawValue: role) {
                    accumulator.finalRole = parsed
                }
                if let usage = message["usage"] as? [String: Any] {
                    let u = decodeUsage(usage, prior: accumulator.usage)
                    accumulator.usage = u
                    continuation.yield(.usage(u))
                }
            }

        case "content_block_start":
            if let index = object["index"] as? Int,
                let block = object["content_block"] as? [String: Any],
                let kind = block["type"] as? String
            {
                let entry = accumulator.startBlock(index: index, kind: kind, raw: block)
                if entry.kind == "tool_use",
                    let id = block["id"] as? String,
                    let name = block["name"] as? String
                {
                    continuation.yield(.toolUseStarted(id: id, name: name))
                }
            }

        case "content_block_delta":
            guard let index = object["index"] as? Int,
                let delta = object["delta"] as? [String: Any],
                let deltaType = delta["type"] as? String
            else { break }

            switch deltaType {
            case "text_delta":
                if let text = delta["text"] as? String {
                    accumulator.appendText(text, atIndex: index)
                    continuation.yield(.textDelta(text))
                }
            case "thinking_delta":
                if let text = delta["thinking"] as? String {
                    accumulator.appendThinking(text, atIndex: index)
                    continuation.yield(.thinkingDelta(text))
                }
            case "signature_delta":
                if let sig = delta["signature"] as? String {
                    accumulator.appendThinkingSignature(sig, atIndex: index)
                }
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String {
                    accumulator.appendToolInput(partial, atIndex: index)
                    if let id = accumulator.toolUseID(at: index) {
                        continuation.yield(.toolUseInputDelta(id: id, partialJSON: partial))
                    }
                }
            default:
                break
            }

        case "content_block_stop":
            if let index = object["index"] as? Int,
                let entry = accumulator.finishBlock(index: index),
                entry.kind == "tool_use",
                let id = entry.id,
                let name = entry.name
            {
                let inputJSON = entry.toolInput.isEmpty ? "{}" : entry.toolInput
                continuation.yield(.toolUseCompleted(id: id, name: name, inputJSON: inputJSON))
            }

        case "message_delta":
            if let usage = object["usage"] as? [String: Any] {
                let u = decodeUsage(usage, prior: accumulator.usage)
                accumulator.usage = u
                continuation.yield(.usage(u))
            }
            if let delta = object["delta"] as? [String: Any],
                let stopReason = delta["stop_reason"] as? String,
                let parsed = LLMStopReason(rawValue: stopReason)
            {
                accumulator.stopReason = parsed
            }

        case "message_stop":
            continuation.yield(.messageStop(accumulator.stopReason ?? .endTurn))

        case "error":
            if let err = object["error"] as? [String: Any],
                let message = err["message"] as? String
            {
                throw LLMProviderError.requestFailed(status: 0, message: message)
            }
            throw LLMProviderError.streamInterrupted

        default:
            break
        }
    }

    private func decodeUsage(_ obj: [String: Any], prior: LLMUsage) -> LLMUsage {
        var u = prior
        if let v = obj["input_tokens"] as? Int { u.inputTokens = v }
        if let v = obj["output_tokens"] as? Int { u.outputTokens = v }
        if let v = obj["cache_read_input_tokens"] as? Int { u.cacheReadTokens = v }
        if let v = obj["cache_creation_input_tokens"] as? Int { u.cacheCreateTokens = v }
        return u
    }
}

// MARK: - Response accumulation

private struct BlockEntry {
    let kind: String
    let id: String?
    let name: String?
    var text: String = ""
    var thinkingText: String = ""
    var thinkingSignature: String = ""
    var toolInput: String = ""
    var redactedData: String = ""
}

private struct ResponseAccumulator {
    var blocksByIndex: [Int: BlockEntry] = [:]
    var blockOrder: [Int] = []
    var usage: LLMUsage = .zero
    var stopReason: LLMStopReason?
    var finalRole: LLMRole?

    mutating func startBlock(index: Int, kind: String, raw: [String: Any]) -> BlockEntry {
        let entry = BlockEntry(
            kind: kind,
            id: raw["id"] as? String,
            name: raw["name"] as? String
        )
        blocksByIndex[index] = entry
        if !blockOrder.contains(index) {
            blockOrder.append(index)
        }
        return entry
    }

    mutating func appendText(_ text: String, atIndex index: Int) {
        guard var e = blocksByIndex[index] else { return }
        e.text.append(text)
        blocksByIndex[index] = e
    }

    mutating func appendThinking(_ text: String, atIndex index: Int) {
        guard var e = blocksByIndex[index] else { return }
        e.thinkingText.append(text)
        blocksByIndex[index] = e
    }

    mutating func appendThinkingSignature(_ sig: String, atIndex index: Int) {
        guard var e = blocksByIndex[index] else { return }
        e.thinkingSignature.append(sig)
        blocksByIndex[index] = e
    }

    mutating func appendToolInput(_ partial: String, atIndex index: Int) {
        guard var e = blocksByIndex[index] else { return }
        e.toolInput.append(partial)
        blocksByIndex[index] = e
    }

    func toolUseID(at index: Int) -> String? {
        blocksByIndex[index]?.id
    }

    @discardableResult
    mutating func finishBlock(index: Int) -> BlockEntry? {
        blocksByIndex[index]
    }

    func assembledBlocks() -> [LLMContentBlock] {
        blockOrder.compactMap { idx in
            guard let entry = blocksByIndex[idx] else { return nil }
            switch entry.kind {
            case "text":
                return LLMContentBlock(content: .text(entry.text))
            case "thinking":
                return LLMContentBlock(content: .thinking(text: entry.thinkingText, signature: entry.thinkingSignature))
            case "redacted_thinking":
                return LLMContentBlock(content: .redactedThinking(data: entry.redactedData))
            case "tool_use":
                guard let id = entry.id, let name = entry.name else { return nil }
                let inputJSON = entry.toolInput.isEmpty ? "{}" : entry.toolInput
                return LLMContentBlock(content: .toolUse(id: id, name: name, inputJSON: inputJSON))
            default:
                return nil
            }
        }
    }
}
