import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
public final class ClaudeCodeProvider: LLMProvider {
    public static let providerID = "claude-code"
    public static let mcpServerName = "luma"

    public let descriptor: LLMProviderDescriptor
    private let executablePath: String
    private weak var engine: Engine?

    public init(engine: Engine?, executablePath: String = "claude") {
        self.engine = engine
        self.executablePath = executablePath
        self.descriptor = LLMProviderDescriptor(
            id: Self.providerID,
            displayName: "Claude Code (subprocess)",
            capabilities: LLMProviderCapabilities(
                supportsStreaming: false,
                supportsPromptCaching: false,
                supportsThinking: false,
                supportsToolUse: engine != nil,
                requiresAPIKey: false,
                supportsCustomBaseURL: false
            ),
            defaultModelID: "default",
            defaultBaseURL: URL(string: "claude://localhost")!
        )
    }

    nonisolated public func suggestedModels() -> [LLMModelInfo] {
        [
            LLMModelInfo(id: "default", displayName: "Default (Claude Code's choice)", contextWindow: 200_000, maxOutput: 8_192, supportsCaching: false, supportsThinking: false),
            LLMModelInfo(id: "sonnet", displayName: "Sonnet", contextWindow: 200_000, maxOutput: 16_384, supportsCaching: false, supportsThinking: false),
            LLMModelInfo(id: "opus", displayName: "Opus", contextWindow: 200_000, maxOutput: 16_384, supportsCaching: false, supportsThinking: false),
            LLMModelInfo(id: "haiku", displayName: "Haiku", contextWindow: 200_000, maxOutput: 8_192, supportsCaching: false, supportsThinking: false),
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
        let prompt = renderConversation(request.messages)
        let systemText = renderSystemPrompt(request.systemBlocks)

        var arguments: [String] = [
            executablePath,
            "--print",
            prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
        ]
        if !systemText.isEmpty {
            arguments.append(contentsOf: ["--append-system-prompt", systemText])
        }
        if request.modelID != "default", !request.modelID.isEmpty {
            arguments.append(contentsOf: ["--model", request.modelID])
        }

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

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

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

        while true {
            try Task.checkCancellation()
            let chunk = stdoutHandle.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
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
                    stopReason: &stopReason
                )
            }
        }

        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderrData, encoding: .utf8) ?? "claude exited with status \(process.terminationStatus)"
            throw LLMProviderError.requestFailed(status: Int(process.terminationStatus), message: message)
        }

        let finalText = streamedText.isEmpty ? assistantText : streamedText
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
        stopReason: inout LLMStopReason
    ) {
        let type = event["type"] as? String ?? ""
        switch type {
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
            case "error_during_execution", "error": stopReason = .error
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
                case .toolResult(_, let content, _): return "[tool result]\n\(content)"
                default: return nil
                }
            }.joined(separator: "\n")
            if !text.isEmpty {
                lines.append("\(speaker): \(text)")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private func renderSystemPrompt(_ blocks: [LLMContentBlock]) -> String {
        blocks.compactMap { block -> String? in
            if case .text(let t) = block.content { return t }
            return nil
        }.joined(separator: "\n\n")
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
        await server.stop()
        self.server = nil
        self.missionID = nil
        self.engine = nil
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
