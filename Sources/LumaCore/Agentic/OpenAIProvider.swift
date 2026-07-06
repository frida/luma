import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIProvider: LLMProvider {
    public static let providerID = "openai"
    public static let defaultBaseURL = URL(string: "https://api.openai.com")!

    public let descriptor: LLMProviderDescriptor
    private let session: URLSession

    public init(session: URLSession = .shared, baseURL: URL = OpenAIProvider.defaultBaseURL) {
        self.session = session
        self.descriptor = LLMProviderDescriptor(
            id: Self.providerID,
            displayName: "OpenAI",
            capabilities: LLMProviderCapabilities(
                supported: [.streaming, .thinking, .toolUse, .apiKey]
            ),
            defaultModelID: nil,
            summarizationModelID: nil,
            defaultBaseURL: baseURL
        )
    }

    public func suggestedModels(apiKey: String?, baseURL: URL?) async throws -> [LLMModelInfo] {
        try await fetchOpenAICompatibleModels(
            session: session,
            baseURL: baseURL ?? descriptor.defaultBaseURL,
            apiKey: apiKey
        )
    }

    public func streamTurn(
        _ request: LLMTurnRequest,
        apiKey: String?,
        baseURL: URL?
    ) -> AsyncThrowingStream<LLMTurnEvent, Error> {
        runOpenAICompatibleStream(
            request: request,
            apiKey: apiKey,
            baseURL: baseURL ?? descriptor.defaultBaseURL,
            session: session,
            requiresAPIKey: descriptor.capabilities.supports(.apiKey)
        )
    }
}

public func describeModelFetchError(_ error: Error, baseURL: URL?) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
            if let baseURL {
                return "Could not reach \(baseURL.absoluteString)"
            }
            return "Could not reach server"
        default:
            break
        }
    }
    return "Failed to load models: \(error.localizedDescription)"
}

func fetchOpenAICompatibleModels(
    session: URLSession,
    baseURL: URL,
    apiKey: String?
) async throws -> [LLMModelInfo] {
    let url = openAICompatibleURL(baseURL: baseURL, path: "/v1/models")

    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "accept")
    if let apiKey, !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
    }

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw LLMProviderError.requestFailed(status: http.statusCode, message: body)
    }

    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let entries = object["data"] as? [[String: Any]]
    else {
        throw LLMProviderError.requestFailed(status: 0, message: "Unexpected response from \(url.absoluteString)")
    }

    return entries.compactMap { entry -> LLMModelInfo? in
        guard let id = entry["id"] as? String else { return nil }
        return LLMModelInfo(
            id: id,
            displayName: id,
            contextWindow: 128_000,
            maxOutput: 16_384
        )
    }
    .sorted { $0.id < $1.id }
}

func runOpenAICompatibleStream(
    request: LLMTurnRequest,
    apiKey: String?,
    baseURL: URL,
    session: URLSession,
    requiresAPIKey: Bool
) -> AsyncThrowingStream<LLMTurnEvent, Error> {
    AsyncThrowingStream<LLMTurnEvent, Error> { continuation in
        let work = Task<Void, Never> {
            do {
                try await driveOpenAIStream(
                    request: request,
                    apiKey: apiKey,
                    baseURL: baseURL,
                    session: session,
                    requiresAPIKey: requiresAPIKey,
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

private func driveOpenAIStream(
    request: LLMTurnRequest,
    apiKey: String?,
    baseURL: URL,
    session: URLSession,
    requiresAPIKey: Bool,
    continuation: AsyncThrowingStream<LLMTurnEvent, Error>.Continuation
) async throws {
    if requiresAPIKey {
        guard let apiKey, !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey
        }
    }

    let url = openAICompatibleURL(baseURL: baseURL, path: "/v1/chat/completions")

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    if let apiKey, !apiKey.isEmpty {
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")

    let body = buildOpenAIRequestBody(request)
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let sse = try await openServerSentEventStream(session: session, request: urlRequest)
    let http = sse.http
    if http.statusCode != 200 {
        var errorBody = ""
        for try await line in sse.lines {
            errorBody.append(line)
            errorBody.append("\n")
            if errorBody.count > 8192 { break }
        }
        throw LLMProviderError.requestFailed(status: http.statusCode, message: errorBody)
    }

    var accumulator = OpenAIResponseAccumulator()
    for try await line in sse.lines {
        try Task.checkCancellation()
        if line.isEmpty || line.hasPrefix(":") { continue }
        guard line.hasPrefix("data:") else { continue }
        let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: CharacterSet.whitespaces)
        if payload == "[DONE]" {
            break
        }
        let data = Data(payload.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        try handleOpenAIChunk(object, accumulator: &accumulator, continuation: continuation)
    }

    let blocks = accumulator.assembledBlocks()
    if !blocks.isEmpty {
        continuation.yield(.finalMessage(role: .assistant, blocks: blocks))
    }
    continuation.yield(.messageStop(accumulator.stopReason ?? .endTurn))
}

private func openAICompatibleURL(baseURL: URL, path: String) -> URL {
    var url = baseURL
    let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
    let components = url.path.split(separator: "/").map(String.init)
    if components.contains("v1"), normalizedPath.hasPrefix("v1/") {
        url.append(path: String(normalizedPath.dropFirst(3)))
    } else {
        url.append(path: normalizedPath)
    }
    return url
}

private func buildOpenAIRequestBody(_ request: LLMTurnRequest) -> [String: Any] {
    let messages = openAIMessages(systemBlocks: request.systemBlocks, conversation: request.messages)

    var body: [String: Any] = [
        "model": request.modelID,
        "messages": messages,
        "stream": true,
        "stream_options": ["include_usage": true],
    ]

    if request.maxOutputTokens > 0 {
        body["max_completion_tokens"] = request.maxOutputTokens
    }
    if let temperature = request.temperature {
        body["temperature"] = temperature
    }
    if !request.tools.isEmpty {
        body["tools"] = openAITools(request.tools)
    }
    if request.thinkingBudget >= 1024 {
        body["reasoning_effort"] = "medium"
    }
    _ = messages
    return body
}

private func openAIMessages(systemBlocks: [LLMContentBlock], conversation: [LLMMessage]) -> [[String: Any]] {
    var out: [[String: Any]] = []
    let systemText = systemBlocks.compactMap { block -> String? in
        if case .text(let t) = block.content { return t }
        return nil
    }.joined(separator: "\n\n")
    if !systemText.isEmpty {
        out.append(["role": "system", "content": systemText])
    }

    for message in conversation {
        switch message.role {
        case .user:
            out.append(contentsOf: openAIUserMessages(blocks: message.blocks))
        case .assistant:
            out.append(openAIAssistantMessage(blocks: message.blocks))
        }
    }

    return out
}

private func openAIUserMessages(blocks: [LLMContentBlock]) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var pendingText = ""

    for block in blocks {
        switch block.content {
        case .text(let t):
            if !pendingText.isEmpty { pendingText.append("\n\n") }
            pendingText.append(t)
        case .toolResult(let id, let content, _, let attachments):
            if !pendingText.isEmpty {
                out.append(["role": "user", "content": pendingText])
                pendingText = ""
            }
            out.append([
                "role": "tool",
                "tool_call_id": id,
                "content": content,
            ])
            if !attachments.isEmpty {
                var parts: [[String: Any]] = [[
                    "type": "text",
                    "text": "Attachments for the preceding tool result:",
                ]]
                for attachment in attachments where attachment.kind == .image {
                    parts.append([
                        "type": "image_url",
                        "image_url": [
                            "url": "data:\(attachment.mediaType);base64,\(attachment.base64)",
                        ],
                    ])
                }
                out.append(["role": "user", "content": parts])
            }
        default:
            break
        }
    }

    if !pendingText.isEmpty {
        out.append(["role": "user", "content": pendingText])
    }
    return out
}

private func openAIAssistantMessage(blocks: [LLMContentBlock]) -> [String: Any] {
    var content = ""
    var toolCalls: [[String: Any]] = []

    for block in blocks {
        switch block.content {
        case .text(let t):
            if !content.isEmpty { content.append("\n") }
            content.append(t)
        case .toolUse(let id, let name, let inputJSON):
            toolCalls.append([
                "id": id,
                "type": "function",
                "function": [
                    "name": name,
                    "arguments": inputJSON,
                ],
            ])
        default:
            break
        }
    }

    var msg: [String: Any] = ["role": "assistant"]
    if !content.isEmpty { msg["content"] = content }
    if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
    return msg
}

private func openAITools(_ tools: [LLMToolSpec]) -> [[String: Any]] {
    tools.map { tool in
        let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) ?? ["type": "object", "properties": [:]]
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": schema,
            ],
        ]
    }
}

private func handleOpenAIChunk(
    _ chunk: [String: Any],
    accumulator: inout OpenAIResponseAccumulator,
    continuation: AsyncThrowingStream<LLMTurnEvent, Error>.Continuation
) throws {
    if let usage = chunk["usage"] as? [String: Any] {
        let u = decodeOpenAIUsage(usage)
        accumulator.usage = u
        continuation.yield(.usage(u))
    }

    guard let choices = chunk["choices"] as? [[String: Any]],
        let choice = choices.first
    else { return }

    if let delta = choice["delta"] as? [String: Any] {
        if let text = delta["content"] as? String, !text.isEmpty {
            accumulator.appendText(text)
            continuation.yield(.textDelta(text))
        }
        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            accumulator.appendReasoning(reasoning)
            continuation.yield(.thinkingDelta(reasoning))
        }
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for callDelta in toolCalls {
                applyToolCallDelta(callDelta, accumulator: &accumulator, continuation: continuation)
            }
        }
    }

    if let finish = choice["finish_reason"] as? String {
        accumulator.stopReason = mapOpenAIFinishReason(finish)
    }
}

private func applyToolCallDelta(
    _ callDelta: [String: Any],
    accumulator: inout OpenAIResponseAccumulator,
    continuation: AsyncThrowingStream<LLMTurnEvent, Error>.Continuation
) {
    guard let index = callDelta["index"] as? Int else { return }
    let id = callDelta["id"] as? String
    let function = callDelta["function"] as? [String: Any]
    let name = function?["name"] as? String
    let argsDelta = function?["arguments"] as? String

    let entry = accumulator.toolCallEntry(index: index)
    let wasNew = entry.id.isEmpty && id != nil

    if let id { accumulator.setToolCallID(index: index, id: id) }
    if let name { accumulator.setToolCallName(index: index, name: name) }
    if let argsDelta {
        accumulator.appendToolCallArgs(index: index, partial: argsDelta)
        if let resolvedID = accumulator.toolCallEntry(index: index).id.nilIfEmpty {
            continuation.yield(.toolUseInputDelta(id: resolvedID, partialJSON: argsDelta))
        }
    }

    if wasNew, let resolvedID = accumulator.toolCallEntry(index: index).id.nilIfEmpty,
        let resolvedName = accumulator.toolCallEntry(index: index).name.nilIfEmpty
    {
        continuation.yield(.toolUseStarted(id: resolvedID, name: resolvedName))
    }
}

private func mapOpenAIFinishReason(_ reason: String) -> LLMStopReason {
    switch reason {
    case "stop": return .endTurn
    case "length": return .maxTokens
    case "tool_calls", "function_call": return .toolUse
    case "content_filter": return .refusal
    default: return .endTurn
    }
}

private func decodeOpenAIUsage(_ obj: [String: Any]) -> LLMUsage {
    var u = LLMUsage.zero
    if let v = obj["prompt_tokens"] as? Int { u.inputTokens = v }
    if let v = obj["completion_tokens"] as? Int { u.outputTokens = v }
    if let details = obj["prompt_tokens_details"] as? [String: Any],
        let cached = details["cached_tokens"] as? Int
    {
        u.cacheReadTokens = cached
    }
    return u
}

private struct OpenAIToolCallEntry {
    var id: String = ""
    var name: String = ""
    var argsJSON: String = ""
}

private struct OpenAIResponseAccumulator {
    var text: String = ""
    var reasoning: String = ""
    var toolCallsByIndex: [Int: OpenAIToolCallEntry] = [:]
    var toolCallOrder: [Int] = []
    var usage: LLMUsage = .zero
    var stopReason: LLMStopReason?

    mutating func appendText(_ s: String) { text.append(s) }
    mutating func appendReasoning(_ s: String) { reasoning.append(s) }

    mutating func toolCallEntry(index: Int) -> OpenAIToolCallEntry {
        if let existing = toolCallsByIndex[index] { return existing }
        let entry = OpenAIToolCallEntry()
        toolCallsByIndex[index] = entry
        toolCallOrder.append(index)
        return entry
    }

    mutating func setToolCallID(index: Int, id: String) {
        var entry = toolCallEntry(index: index)
        entry.id = id
        toolCallsByIndex[index] = entry
    }

    mutating func setToolCallName(index: Int, name: String) {
        var entry = toolCallEntry(index: index)
        entry.name = name
        toolCallsByIndex[index] = entry
    }

    mutating func appendToolCallArgs(index: Int, partial: String) {
        var entry = toolCallEntry(index: index)
        entry.argsJSON.append(partial)
        toolCallsByIndex[index] = entry
    }

    func assembledBlocks() -> [LLMContentBlock] {
        var blocks: [LLMContentBlock] = []
        if !reasoning.isEmpty {
            blocks.append(LLMContentBlock(content: .thinking(text: reasoning, signature: "")))
        }
        if !text.isEmpty {
            blocks.append(LLMContentBlock(content: .text(text)))
        }
        for index in toolCallOrder {
            guard let entry = toolCallsByIndex[index],
                !entry.id.isEmpty,
                !entry.name.isEmpty
            else { continue }
            let inputJSON = entry.argsJSON.isEmpty ? "{}" : entry.argsJSON
            blocks.append(LLMContentBlock(content: .toolUse(id: entry.id, name: entry.name, inputJSON: inputJSON)))
        }
        return blocks
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
