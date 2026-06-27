import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS) || os(Linux) || os(Windows)

@MainActor
public final class ClaudeCodeProvider: LLMProvider {
    public static let providerID = "claude-code"
    public static let mcpServerName = "luma"

    public let descriptor: LLMProviderDescriptor
    private let executablePath: String
    private weak var engine: Engine?
    private var initializedMissionSessionIDs: Set<UUID> = []

    public init(engine: Engine?, executablePath: String = "claude") {
        self.engine = engine
        self.executablePath = executablePath
        self.descriptor = LLMProviderDescriptor(
            id: Self.providerID,
            displayName: "Claude Code (subprocess)",
            capabilities: LLMProviderCapabilities(
                supported: engine != nil ? [.streaming, .promptCaching, .toolUse] : [.streaming, .promptCaching],
                reasoningEffortOptions: ["auto", "low", "medium", "high", "xhigh", "max"],
                defaultReasoningEffort: "auto"
            ),
            defaultModelID: "default",
            summarizationModelID: "haiku",
            defaultBaseURL: URL(string: "claude://localhost")!
        )
    }

    nonisolated public func suggestedModels(apiKey: String?, baseURL: URL?) async throws -> [LLMModelInfo] {
        [
            LLMModelInfo(id: "default", displayName: "Default (Claude Code's choice)", contextWindow: 200_000, maxOutput: 8_192),
            LLMModelInfo(id: "sonnet", displayName: "Sonnet", contextWindow: 200_000, maxOutput: 16_384),
            LLMModelInfo(id: "opus", displayName: "Opus", contextWindow: 200_000, maxOutput: 16_384),
            LLMModelInfo(id: "haiku", displayName: "Haiku", contextWindow: 200_000, maxOutput: 8_192),
        ]
    }

    nonisolated public func streamTurn(
        _ request: LLMTurnRequest,
        apiKey: String?,
        baseURL: URL?
    ) -> AsyncThrowingStream<LLMTurnEvent, Error> {
        AsyncThrowingStream<LLMTurnEvent, Error> { continuation in
            let process = Process()
            let mcpHandle = MCPServerHandle()
            let work = Task<Void, Never> { @MainActor in
                do {
                    try await self.drive(process: process, mcpHandle: mcpHandle, request: request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
                await mcpHandle.stop()
            }
            continuation.onTermination = { _ in
                work.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func drive(
        process: Process,
        mcpHandle: MCPServerHandle,
        request: LLMTurnRequest,
        continuation: AsyncThrowingStream<LLMTurnEvent, Error>.Continuation
    ) async throws {
        let sessionPlan = makeSessionPlan(for: request)
        let prompt = sessionPlan.prompt
        let systemText = renderSystemPrompt(request.systemBlocks)

        var arguments: [String] = [
            executablePath,
            "--print",
            prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--exclude-dynamic-system-prompt-sections",
        ]
        if let sessionID = sessionPlan.sessionID {
            arguments.append(contentsOf: ["--session-id", sessionID.uuidString])
        }
        if !systemText.isEmpty {
            arguments.append(contentsOf: ["--append-system-prompt", systemText])
        }
        if request.modelID != "default", !request.modelID.isEmpty {
            arguments.append(contentsOf: ["--model", request.modelID])
        }
        if let effort = request.reasoningEffort, effort != "auto", !effort.isEmpty {
            arguments.append(contentsOf: ["--effort", effort])
        }

        #if canImport(Network) || canImport(CSoup)
        if let mission = request.mission, let engine, !request.tools.isEmpty {
            let toolNames = request.tools.map(\.name)
            let server = MCPServer(engine: engine, mission: mission, toolNames: toolNames)
            server.onToolStarted = { name, args in
                continuation.yield(.textDelta("\n[→ \(name)\(formatArgs(args))]\n"))
            }
            server.onToolFinished = { _, result in
                continuation.yield(.textDelta("[← \(result.summary)]\n"))
            }
            let url = try await server.start()
            engine.registerActiveMCPServer(server, for: mission.id)
            await mcpHandle.set(server, missionID: mission.id, engine: engine)

            let mcpConfig: [String: Any] = [
                "mcpServers": [
                    Self.mcpServerName: [
                        "type": "http",
                        "url": url.absoluteString,
                        "headers": ["Authorization": "Bearer \(server.bearerToken)"],
                    ],
                ],
            ]
            let mcpConfigData = (try? JSONSerialization.data(withJSONObject: mcpConfig)) ?? Data("{}".utf8)
            let mcpConfigString = String(data: mcpConfigData, encoding: .utf8) ?? "{}"
            arguments.append(contentsOf: ["--mcp-config", mcpConfigString, "--strict-mcp-config"])

            let allowList = toolNames.map { "mcp__\(Self.mcpServerName)__\($0)" }.joined(separator: ",")
            arguments.append(contentsOf: ["--allowed-tools", allowList])
        } else {
            arguments.append(contentsOf: ["--allowed-tools", ""])
        }
        #else
        _ = mcpHandle
        arguments.append(contentsOf: ["--allowed-tools", ""])
        #endif

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = augmentedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            throw LLMProviderError.requestFailed(status: -1, message: "could not spawn claude: \(error.localizedDescription)")
        }

        try? stdinPipe.fileHandleForWriting.close()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        var buffer = Data()
        var streamedText = ""
        var assistantText = ""
        var assembledUsage = LLMUsage.zero
        var stopReason = LLMStopReason.endTurn
        var errorDetail: String?

        for await chunk in pipeChunks(stdoutHandle) {
            try Task.checkCancellation()
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer[..<nl]
                buffer = buffer.subdata(in: (nl + 1)..<buffer.endIndex)
                guard !lineData.isEmpty,
                    let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
                else { continue }
                handleClaudeEvent(
                    object,
                    continuation: continuation,
                    streamedText: &streamedText,
                    assistantText: &assistantText,
                    assembledUsage: &assembledUsage,
                    stopReason: &stopReason,
                    errorDetail: &errorDetail
                )
            }
        }

        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let detail = stderrText.isEmpty ? (errorDetail ?? "") : stderrText
            let message = detail.isEmpty ? "claude exited with status \(process.terminationStatus)" : detail
            throw LLMProviderError.requestFailed(status: Int(process.terminationStatus), message: message)
        }
        if let sessionID = sessionPlan.sessionID {
            initializedMissionSessionIDs.insert(sessionID)
        }

        let finalText = !assistantText.isEmpty ? assistantText : streamedText
        if !finalText.isEmpty {
            if streamedText.isEmpty {
                continuation.yield(.textDelta(finalText))
            }
            continuation.yield(.finalMessage(role: .assistant, blocks: [LLMContentBlock(content: .text(finalText))]))
        }
        continuation.yield(.messageStop(stopReason))
    }

    private func handleClaudeEvent(
        _ event: [String: Any],
        continuation: AsyncThrowingStream<LLMTurnEvent, Error>.Continuation,
        streamedText: inout String,
        assistantText: inout String,
        assembledUsage: inout LLMUsage,
        stopReason: inout LLMStopReason,
        errorDetail: inout String?
    ) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "system":
            if (event["subtype"] as? String) == "api_retry" {
                let attempt = event["attempt"] as? Int ?? 0
                let maxRetries = event["max_retries"] as? Int ?? 0
                let reason = event["error"] as? String ?? "transient error"
                errorDetail = "model \(reason) after \(maxRetries) retries"
                continuation.yield(.textDelta("\n[model \(reason), retrying \(attempt)/\(maxRetries)…]\n"))
            }

        case "stream_event":
            guard let payload = event["event"] as? [String: Any] else { return }
            if (payload["type"] as? String) == "content_block_delta",
                let delta = payload["delta"] as? [String: Any],
                (delta["type"] as? String) == "text_delta",
                let text = delta["text"] as? String,
                !text.isEmpty
            {
                streamedText.append(text)
                continuation.yield(.textDelta(text))
            }

        case "assistant":
            guard let message = event["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { return }
            for block in content {
                if (block["type"] as? String) == "text",
                    let text = block["text"] as? String,
                    !text.isEmpty
                {
                    assistantText.append(text)
                }
            }

        case "result":
            if let usage = event["usage"] as? [String: Any] {
                assembledUsage = decodeUsage(usage, prior: assembledUsage)
                continuation.yield(.usage(assembledUsage))
            }
            switch event["subtype"] as? String {
            case "success": stopReason = .endTurn
            case "error_max_turns": stopReason = .maxTokens
            case "error_during_execution", "error":
                stopReason = .error
                if let detail = event["result"] as? String, !detail.isEmpty {
                    errorDetail = detail
                }
            default: stopReason = .endTurn
            }

        default:
            break
        }
    }

    private func renderConversation(_ messages: [LLMMessage]) -> String {
        var lines: [String] = []
        for message in messages {
            let speaker = message.role == .user ? "User" : "Assistant"
            let text = message.blocks.compactMap { block -> String? in
                switch block.content {
                case .text(let t): return t
                case .toolResult(_, let content, _, _): return "[tool result]\n\(content)"
                default: return nil
                }
            }.joined(separator: "\n")
            if !text.isEmpty {
                lines.append("\(speaker): \(text)")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private struct ClaudeSessionPlan {
        var prompt: String
        var sessionID: UUID?
    }

    private func makeSessionPlan(for request: LLMTurnRequest) -> ClaudeSessionPlan {
        guard let missionID = request.mission?.id else {
            return ClaudeSessionPlan(prompt: renderConversation(request.messages), sessionID: nil)
        }

        if initializedMissionSessionIDs.contains(missionID), let latest = latestUserMessage(in: request.messages) {
            return ClaudeSessionPlan(prompt: renderConversation([latest]), sessionID: missionID)
        }

        if request.messages.count <= 1 {
            return ClaudeSessionPlan(prompt: renderConversation(request.messages), sessionID: missionID)
        }

        return ClaudeSessionPlan(prompt: renderConversation(request.messages), sessionID: nil)
    }

    private func latestUserMessage(in messages: [LLMMessage]) -> LLMMessage? {
        messages.reversed().first { $0.role == .user }
    }

    private func renderSystemPrompt(_ blocks: [LLMContentBlock]) -> String {
        blocks.compactMap { block -> String? in
            if case .text(let t) = block.content { return t }
            return nil
        }.joined(separator: "\n\n")
    }

    private func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let candidates = [
            NSString(string: "~/.local/bin").expandingTildeInPath,
            NSString(string: "~/.npm-global/bin").expandingTildeInPath,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let inheritedSegments = inherited.split(separator: ":").map(String.init)
        var seen = Set<String>(inheritedSegments)
        var augmented = candidates.filter { !seen.contains($0) }
        seen.formUnion(augmented)
        augmented.append(contentsOf: inheritedSegments)
        env["PATH"] = augmented.joined(separator: ":")
        return env
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

private actor MCPServerHandle {
    #if canImport(Network) || canImport(CSoup)
    private var server: MCPServer?
    private var missionID: UUID?
    private weak var engine: Engine?

    func set(_ server: MCPServer, missionID: UUID, engine: Engine) {
        self.server = server
        self.missionID = missionID
        self.engine = engine
    }

    func stop() async {
        guard let server = server else { return }
        if let missionID, let engine {
            await engine.unregisterActiveMCPServer(for: missionID)
        }
        await MainActor.run { server.stop() }
        self.server = nil
        self.missionID = nil
        self.engine = nil
    }
    #else
    func stop() async {}
    #endif
}

private func pipeChunks(_ handle: FileHandle) -> AsyncStream<Data> {
    AsyncStream<Data> { continuation in
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        continuation.onTermination = { _ in
            handle.readabilityHandler = nil
        }
    }
}

private func formatArgs(_ args: [String: Any]) -> String {
    if args.isEmpty { return "()" }
    let pairs = args.map { key, value -> String in
        if let s = value as? String, s.count <= 60 {
            return "\(key)=\"\(s)\""
        }
        return "\(key)=…"
    }
    return "(" + pairs.joined(separator: ", ") + ")"
}

#endif
