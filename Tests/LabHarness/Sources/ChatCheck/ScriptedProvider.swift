import Foundation
@testable import LumaCore
import SwiftyPharo
import Observation

final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    enum Part {
        case text(String)
        case tool(String, [String: Any])
    }

    enum Step {
        case reply([Part])
        case hang(String)
        case overMCP(String, [String: Any])
    }

    let descriptor = LLMProviderDescriptor(
        id: "scripted",
        displayName: "Scripted",
        capabilities: LLMProviderCapabilities(supported: [.streaming, .toolUse]),
        defaultModelID: "scripted-1",
        defaultBaseURL: URL(string: "http://127.0.0.1")!
    )

    nonisolated(unsafe) var steps: [Step] = []
    nonisolated(unsafe) var requests: [LLMTurnRequest] = []
    nonisolated(unsafe) var missionTurns = 0
    nonisolated(unsafe) var holdsMissions = false
    nonisolated(unsafe) var missionSteps: [[Part]] = []
    nonisolated(unsafe) var missionMCP: (String, [String: Any])?
    nonisolated(unsafe) var mcpAnswers: [String] = []
    nonisolated(unsafe) weak var engine: Engine?
    nonisolated(unsafe) var nextToolID = 0

    func suggestedModels(apiKey: String?, baseURL: URL?) async throws -> [LLMModelInfo] { [] }

    func streamTurn(_ request: LLMTurnRequest, apiKey: String?, baseURL: URL?) -> AsyncThrowingStream<LLMTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { @MainActor in
                do {
                    try await self.answer(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    @MainActor
    private func answer(_ request: LLMTurnRequest, into continuation: AsyncThrowingStream<LLMTurnEvent, Error>.Continuation) async throws {
        let system = request.systemBlocks.compactMap { block -> String? in
            if case .text(let text) = block.content { return text }
            return nil
        }.joined()
        if system.hasPrefix("You are Luma, a goal-driven") {
            missionTurns += 1
            if holdsMissions {
                continuation.yield(.textDelta("(holding)"))
                while holdsMissions {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            if let (name, args) = missionMCP {
                missionMCP = nil
                let server = MCPServer(engine: engine!, mission: request.mission!, toolNames: [name])
                let url = try await server.start()
                engine!.registerActiveMCPServer(server, for: request.mission!.id)
                var http = URLRequest(url: url)
                http.httpMethod = "POST"
                http.setValue("Bearer \(server.bearerToken)", forHTTPHeaderField: "Authorization")
                http.setValue("application/json", forHTTPHeaderField: "Content-Type")
                http.httpBody = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args],
                ])
                let (data, _) = try await URLSession.shared.data(for: http)
                engine!.unregisterActiveMCPServer(for: request.mission!.id)
                server.stop()
                mcpAnswers.append(String(decoding: data, as: UTF8.self))
                continuation.yield(.finalMessage(role: .assistant, blocks: [LLMContentBlock(content: .text("after MCP"))]))
                return
            }
            guard !missionSteps.isEmpty else {
                continuation.yield(.textDelta("(mission turn)"))
                continuation.yield(.finalMessage(role: .assistant, blocks: [LLMContentBlock(content: .text("(mission turn)"))]))
                return
            }
            var blocks: [LLMContentBlock] = []
            for case .tool(let name, let args) in missionSteps.removeFirst() {
                nextToolID += 1
                let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                blocks.append(LLMContentBlock(content: .toolUse(id: "toolu_\(nextToolID)", name: name, inputJSON: json)))
            }
            continuation.yield(.messageStop(.toolUse))
            continuation.yield(.finalMessage(role: .assistant, blocks: blocks))
            return
        }
        requests.append(request)
        guard !steps.isEmpty else {
            continuation.yield(.textDelta("(script ran out)"))
            continuation.yield(.finalMessage(role: .assistant, blocks: [LLMContentBlock(content: .text("(script ran out)"))]))
            return
        }
        switch steps.removeFirst() {
        case .reply(let parts):
            var blocks: [LLMContentBlock] = []
            for part in parts {
                switch part {
                case .text(let text):
                    continuation.yield(.textDelta(text))
                    blocks.append(LLMContentBlock(content: .text(text)))
                case .tool(let name, let args):
                    nextToolID += 1
                    let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                    blocks.append(LLMContentBlock(content: .toolUse(id: "toolu_\(nextToolID)", name: name, inputJSON: json)))
                }
            }
            continuation.yield(.usage(LLMUsage(inputTokens: 100, outputTokens: 10)))
            continuation.yield(.finalMessage(role: .assistant, blocks: blocks))
        case .hang(let text):
            continuation.yield(.textDelta(text))
            try await Task.sleep(for: .seconds(120))
        case .overMCP(let name, let args):
            let server = MCPServer(engine: engine!, mission: request.mission!, toolNames: [name])
            let url = try await server.start()
            var http = URLRequest(url: url)
            http.httpMethod = "POST"
            http.setValue("Bearer \(server.bearerToken)", forHTTPHeaderField: "Authorization")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args],
            ])
            let (data, _) = try await URLSession.shared.data(for: http)
            server.stop()
            let text = "MCP answered: " + String(decoding: data, as: UTF8.self)
            continuation.yield(.textDelta(text))
            continuation.yield(.finalMessage(role: .assistant, blocks: [LLMContentBlock(content: .text(text))]))
        }
    }
}
