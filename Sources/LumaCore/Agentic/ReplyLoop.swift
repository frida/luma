import Foundation

@MainActor
struct ReplyLoop {
    struct Limits {
        let iterations: Int
        let maxOutputTokens: Int
        let temperature: Double
    }

    struct Reply {
        var text = ""
        var usage = LLMUsage.zero
    }

    let provider: any LLMProvider
    let modelID: String
    let credentials: LLMCredentialStore
    let mission: Mission
    let limits: Limits

    func run(
        system: String,
        messages initialMessages: [LLMMessage],
        tools: [LLMToolSpec],
        onDelta: @escaping @MainActor (String) -> Void,
        runToolUses: @MainActor ([LLMContentBlock]) async -> [LLMContentBlock]
    ) async throws -> Reply {
        let providerID = provider.descriptor.id
        let apiKey = (try? await credentials.apiKey(providerID: providerID)) ?? nil
        if provider.descriptor.capabilities.supports(.apiKey), apiKey == nil {
            throw ReplyLoopError.missingAPIKey(providerID: providerID)
        }
        let baseURL = LumaAppState.shared.providerBaseURL(providerID: providerID).flatMap(URL.init(string:))

        var messages = initialMessages
        var reply = Reply()
        var iterationsRemaining = limits.iterations
        while iterationsRemaining > 0 {
            iterationsRemaining -= 1
            if Task.isCancelled { throw CancellationError() }
            let request = LLMTurnRequest(
                modelID: modelID,
                systemBlocks: [LLMContentBlock(content: .text(system), cacheBoundary: true)],
                messages: messages,
                tools: tools,
                maxOutputTokens: limits.maxOutputTokens,
                thinkingBudget: 0,
                temperature: limits.temperature,
                mission: mission
            )

            let outcome = await streamTurn(request, apiKey: apiKey, baseURL: baseURL, onDelta: onDelta)
            reply.text += outcome.text
            reply.usage.inputTokens += outcome.usage.inputTokens
            reply.usage.outputTokens += outcome.usage.outputTokens
            reply.usage.cacheReadTokens += outcome.usage.cacheReadTokens
            reply.usage.cacheCreateTokens += outcome.usage.cacheCreateTokens

            if let error = outcome.error { throw error }

            let toolUses = outcome.blocks.filter {
                if case .toolUse = $0.content { return true }
                return false
            }
            if toolUses.isEmpty { break }

            messages.append(LLMMessage(role: .assistant, blocks: outcome.blocks))
            messages.append(LLMMessage(role: .user, blocks: await runToolUses(toolUses)))
        }
        return reply
    }

    private struct TurnOutcome {
        var blocks: [LLMContentBlock]
        var text: String
        var usage: LLMUsage
        var error: (any Swift.Error)?
    }

    private func streamTurn(
        _ request: LLMTurnRequest,
        apiKey: String?,
        baseURL: URL?,
        onDelta: @MainActor (String) -> Void
    ) async -> TurnOutcome {
        var blocks: [LLMContentBlock] = []
        var streamedText = ""
        var usage = LLMUsage.zero
        var capturedError: (any Swift.Error)?

        do {
            for try await event in provider.streamTurn(request, apiKey: apiKey, baseURL: baseURL) {
                switch event {
                case .textDelta(let delta):
                    streamedText += delta
                    onDelta(delta)
                case .finalMessage(_, let finalBlocks):
                    blocks = finalBlocks
                case .usage(let u):
                    usage = u
                default:
                    break
                }
            }
        } catch {
            capturedError = error
        }

        if blocks.isEmpty, !streamedText.isEmpty {
            blocks = [LLMContentBlock(content: .text(streamedText))]
        }

        let finalText = blocks.compactMap { block -> String? in
            if case .text(let t) = block.content { return t }
            return nil
        }.joined()
        let textForLoop = finalText.isEmpty ? streamedText : finalText

        return TurnOutcome(blocks: blocks, text: textForLoop, usage: usage, error: capturedError)
    }
}

enum ReplyLoopError: Error, LocalizedError {
    case missingAPIKey(providerID: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let providerID):
            "missing API key for provider \(providerID)"
        }
    }
}
