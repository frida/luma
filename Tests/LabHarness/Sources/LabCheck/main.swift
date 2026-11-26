import Foundation
@testable import LumaCore
import SwiftyPharo
import CryptoKit

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(Data("@@".utf8) + data + Data("\n".utf8))
}

final class OfflineWeb: URLProtocol {
    nonisolated(unsafe) static var login = "nobody"
    nonisolated(unsafe) static var seen: [String] = []
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "api.github.com" || host.hasSuffix("example.invalid") || host == "github.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.seen.append(url.absoluteString)
        var body = Data()
        var type = "application/json"
        var status = 200
        if url.host == "api.github.com", url.path == "/user" {
            body = try! JSONSerialization.data(withJSONObject: [
                "login": Self.login, "name": Self.login.capitalized, "avatar_url": "https://example.invalid/\(Self.login).png",
            ])
        } else if url.host?.hasSuffix("example.invalid") == true {
            body = Self.png
            type = "image/png"
        } else {
            status = 404
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    struct Logged {
        var channel: String
        var toolResults: [String]
        var firstText: String
        var messageCount: Int
        var tools: [String]
        var allText: String = ""
    }

    let descriptor = LLMProviderDescriptor(
        id: "scripted",
        displayName: "Scripted",
        capabilities: LLMProviderCapabilities(supported: [.streaming, .toolUse]),
        defaultModelID: "scripted-1",
        defaultBaseURL: URL(string: "http://127.0.0.1")!
    )

    nonisolated(unsafe) var steps: [String: [[String: Any]]] = [:]
    nonisolated(unsafe) var log: [Logged] = []
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
        if system.isEmpty && request.tools.isEmpty {
            continuation.yield(.finalMessage(role: .assistant, blocks: [LLMContentBlock(content: .text("Scripted Title"))]))
            return
        }
        let channel = system.hasPrefix("You are Luma, a goal-driven") ? "mission" : "chat"
        let results = request.messages.last?.blocks.compactMap { block -> String? in
            if case .toolResult(_, let json, _, _) = block.content { return json }
            return nil
        } ?? []
        let first = request.messages.first?.blocks.compactMap { block -> String? in
            if case .text(let text) = block.content { return text }
            return nil
        }.first ?? ""
        let allText = request.messages.flatMap { $0.blocks }.compactMap { block -> String? in
            if case .text(let text) = block.content { return text }
            return nil
        }.joined(separator: "\n---\n")
        log.append(Logged(channel: channel, toolResults: results, firstText: first, messageCount: request.messages.count, tools: request.tools.map(\.name), allText: allText))
        guard var queue = steps[channel], !queue.isEmpty else {
            continuation.yield(.textDelta("(done)"))
            continuation.yield(.finalMessage(role: .assistant, blocks: [LLMContentBlock(content: .text("(done)"))]))
            return
        }
        let step = queue.removeFirst()
        steps[channel] = queue
        if let hang = step["hang"] as? String {
            continuation.yield(.textDelta(hang))
            try await Task.sleep(for: .seconds(600))
            return
        }
        if let mcp = step["mcp"] as? [String: Any] {
            let name = mcp["name"] as! String
            let server = MCPServer(engine: engine!, mission: request.mission!, toolNames: [name])
            let url = try await server.start()
            engine!.registerActiveMCPServer(server, for: request.mission!.id)
            var http = URLRequest(url: url)
            http.httpMethod = "POST"
            http.timeoutInterval = 600
            http.setValue("Bearer \(server.bearerToken)", forHTTPHeaderField: "Authorization")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": mcp["args"] ?? [:]],
            ])
            emit(["event": "mcp-call-sent", "tool": name])
            let (data, _) = try await URLSession.shared.data(for: http)
            engine!.unregisterActiveMCPServer(for: request.mission!.id)
            server.stop()
            let text = "MCP answered: " + String(decoding: data, as: UTF8.self)
            emit(["event": "mcp-answered", "text": String(text.prefix(300))])
            continuation.yield(.textDelta(text))
            continuation.yield(.finalMessage(role: .assistant, blocks: [LLMContentBlock(content: .text(text))]))
            return
        }
        var blocks: [LLMContentBlock] = []
        if let text = step["text"] as? String {
            continuation.yield(.textDelta(text))
            blocks.append(LLMContentBlock(content: .text(text)))
        }
        for tool in (step["tools"] as? [[String: Any]]) ?? [] {
            nextToolID += 1
            let json = String(decoding: try JSONSerialization.data(withJSONObject: tool["args"] ?? [:]), as: UTF8.self)
            blocks.append(LLMContentBlock(content: .toolUse(id: "toolu_\(nextToolID)", name: tool["name"] as! String, inputJSON: json)))
        }
        continuation.yield(.usage(LLMUsage(inputTokens: 100, outputTokens: 10)))
        if !((step["tools"] as? [[String: Any]]) ?? []).isEmpty {
            continuation.yield(.messageStop(.toolUse))
        }
        continuation.yield(.finalMessage(role: .assistant, blocks: blocks))
    }
}

@MainActor
final class Member {
    let engine: Engine
    let provider: ScriptedProvider
    var asks: [UUID: Task<String?, Never>] = [:]
    var arrivals: [[String: Any]] = []
    var lastSeen: [String: String] = [:]
    var transitions: [String] = []
    static let rank: [String: Int] = ["proposed": 0, "pending": 0, "approved": 1, "running": 2, "succeeded": 3, "failed": 3, "rejected": 3]
    var seenEvents = 0
    var warnings: [String] = []
    var statuses: [String] = []
    var objects: [String: PharoObject] = [:]
    var saved: [String: [String: Any]] = [:]

    init(engine: Engine, provider: ScriptedProvider) {
        self.engine = engine
        self.provider = provider
        engine.objectChats.onMessageArrived = { [weak self] chat, message in
            self?.arrivals.append(["chat": chat.id.uuidString, "message": message.id.uuidString, "body": message.bodyMarkdown,
                                   "author": message.author?.id ?? ""])
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await status in engine.collaboration.statusChanges {
                self.statuses.append(Self.describe(status))
                emit(["event": "status", "status": Self.describe(status)])
            }
        }
        Task { @MainActor [weak self] in
            while let self {
                self.watch()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        Task { @MainActor [weak self] in
            while let self {
                self.collectWarnings()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func watch() {
        var now: [String: String] = [:]
        for (_, thread) in engine.objectChats.threads {
            for call in thread.toolCalls { now["call:" + call.id.uuidString] = call.status.rawValue }
            for m in thread.messages { now["msg:" + m.id.uuidString] = "\(m.index)" }
        }
        for mission in engine.missions {
            for action in (try? engine.store.fetchMissionActions(missionID: mission.id)) ?? [] { now["action:" + action.id.uuidString] = action.status.rawValue }
        }
        for (key, value) in now {
            guard let old = lastSeen[key], old != value else { continue }
            if key.hasPrefix("msg:") {
                transitions.append("\(key) index \(old)->\(value)")
            } else if (Self.rank[value] ?? 9) < (Self.rank[old] ?? 9) || ((Self.rank[old] ?? 9) == 3 && old != value) {
                transitions.append("BACKWARD \(key) \(old)->\(value)")
            } else {
                transitions.append("\(key) \(old)->\(value)")
            }
        }
        lastSeen.merge(now) { $1 }
    }

    func collectWarnings() {
        let events = engine.eventLog.events
        guard events.count > seenEvents else { return }
        for event in events.dropFirst(seenEvents) {
            guard case .engine(let subsystem) = event.source, case .consoleMessage(let message) = event.payload else { continue }
            let text = message.values.map { value -> String in
                if case .string(let s) = value { return s }
                return "\(value)"
            }.joined(separator: " ")
            warnings.append("\(subsystem): \(text)")
            emit(["event": "warning", "text": "\(subsystem): \(text)"])
        }
        seenEvents = events.count
    }

    static func describe(_ status: CollaborationSession.Status) -> String {
        switch status {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .joined(let labID): "joined:\(labID)"
        case .error(let message): "error:\(message)"
        }
    }

    static func settled(_ status: CollaborationSession.Status) -> Bool {
        switch status {
        case .joined, .error: true
        case .disconnected, .connecting: false
        }
    }

    func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let text = args[key] as? String, let id = UUID(uuidString: text) else { throw Failure("missing \(key)") }
        return id
    }

    func handle(_ cmd: String, _ a: [String: Any]) async throws -> [String: Any] {
        let chats = engine.objectChats
        let collaboration = engine.collaboration
        switch cmd {
        case "collab":
            engine.startCollaboration(joiningLab: a["lab"] as? String)
            let deadline = Date().addingTimeInterval((a["timeout"] as? Double) ?? 30)
            while !Self.settled(collaboration.status) {
                guard Date() < deadline else { throw Failure("timed out waiting for the lab to be joined or to fail: \(Self.describe(collaboration.status))") }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(300))
            return try await handle("status", [:])
        case "stop":
            await collaboration.stop()
            return ["status": Self.describe(collaboration.status)]
        case "status":
            return [
                "status": Self.describe(collaboration.status),
                "lab": collaboration.labID ?? NSNull(),
                "stored_lab": (try? engine.store.fetchCollaborationState().labID) ?? NSNull(),
                "user": collaboration.localUser?.id ?? NSNull(),
                "github_user": engine.gitHubAuth.currentUser?.id ?? NSNull(),
                "members": collaboration.members.map { ["id": $0.user.id, "role": "\($0.role)", "presence": "\($0.presence)"] },
                "statuses": statuses,
                "web": OfflineWeb.seen,
            ]
        case "conv":
            let conversation = chats.openConversation()
            return ["id": conversation.id.uuidString, "conversation_id": chats.conversationID.uuidString]
        case "post":
            try chats.post(a["text"] as! String, in: try uuid(a, "chat"))
            return ["index": chats.thread(of: try uuid(a, "chat")).messages.last?.index ?? -1]
        case "post-many":
            let chatID = try uuid(a, "chat")
            let count = a["count"] as! Int
            let prefix = a["prefix"] as? String ?? "m"
            for i in 0..<count {
                try chats.post("\(prefix) \(i)", in: chatID)
                if i % 50 == 49 { try await Task.sleep(for: .milliseconds(1)) }
            }
            return ["posted": count]
        case "ask":
            let chatID = try uuid(a, "chat")
            let text = a["text"] as! String
            let task = Task<String?, Never> { @MainActor in
                do {
                    try await chats.ask(text, in: chatID)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            asks[chatID] = task
            if a["wait"] as? Bool == true {
                return ["error": await task.value ?? NSNull()]
            }
            try await Task.sleep(for: .milliseconds(200))
            return ["started": true]
        case "await-ask":
            let chatID = try uuid(a, "chat")
            guard let task = asks[chatID] else { return ["error": "no ask"] }
            let timeout = (a["timeout"] as? Double) ?? 30
            let done = Task { await task.value }
            let deadline = Date().addingTimeInterval(timeout)
            while chats.turn(of: chatID) != nil {
                guard Date() < deadline else { throw Failure("timed out waiting for the ask in \(chatID) to end") }
                try await Task.sleep(for: .milliseconds(50))
            }
            return ["error": await done.value ?? NSNull()]
        case "answering":
            return ["answering": chats.turn(of: try uuid(a, "chat")) != nil, "reply_text": chats.thread(of: try uuid(a, "chat")).replyText ?? NSNull()]
        case "steps":
            provider.steps[a["channel"] as? String ?? "chat"] = a["steps"] as? [[String: Any]] ?? []
            return [:]
        case "requests":
            return ["requests": provider.log.map { ["channel": $0.channel, "tool_results": $0.toolResults, "first_text": $0.firstText, "messages": $0.messageCount, "tools": $0.tools, "all_text": $0.allText] }]
        case "thread":
            return describeThread(try uuid(a, "chat"))
        case "chats":
            return ["chats": chats.chats.map { chat -> [String: Any] in
                ["id": chat.id.uuidString, "title": chat.title ?? NSNull(), "subject": "\(chat.subject)".prefix(40).description,
                 "editors": chat.editors.map(\.id), "session": chat.sessionID?.uuidString ?? NSNull()]
            }, "conversation_id": chats.conversationID.uuidString]
        case "unread":
            return ["unread": chats.unreadCount(in: try uuid(a, "chat")), "read_through": chats.readThrough[try uuid(a, "chat")] ?? NSNull()]
        case "mark-read":
            chats.markRead(try uuid(a, "chat"))
            return ["unread": chats.unreadCount(in: try uuid(a, "chat"))]
        case "waiting":
            return ["calls": chats.callsWaitingForMe.map { ["id": $0.id.uuidString, "tool": $0.tool, "chat": $0.chatID.uuidString, "asked_by": nul($0.askedBy?.id)] }]
        case "run":
            await chats.run(try uuid(a, "call"))
            return ["call": describe(chats.call(try uuid(a, "call")))]
        case "reject":
            chats.reject(try uuid(a, "call"), reason: a["reason"] as? String)
            return ["call": describe(chats.call(try uuid(a, "call")))]
        case "stranded":
            let call = chats.call(try uuid(a, "call"))
            return ["stranded": call.map(chats.isStranded) ?? NSNull(), "call": describe(call)]
        case "cancel":
            chats.cancel(try uuid(a, "chat"))
            return [:]
        case "delete":
            do {
                try await chats.delete(try uuid(a, "chat"))
                return ["deleted": true]
            } catch {
                return ["error": error.localizedDescription]
            }
        case "edit":
            do {
                try chats.edit(try uuid(a, "message"), in: try uuid(a, "chat"), to: a["text"] as! String)
                return ["edited": true]
            } catch {
                return ["error": error.localizedDescription]
            }
        case "remove":
            do {
                try chats.remove(try uuid(a, "message"), in: try uuid(a, "chat"))
                return ["removed": true]
            } catch {
                return ["error": error.localizedDescription]
            }
        case "rename":
            chats.rename(try uuid(a, "chat"), to: a["title"] as! String)
            return [:]
        case "eval":
            let runtime = try await engine.pharo.started()
            let object = try await runtime.evaluate(a["code"] as! String)
            if let name = a["keep"] as? String { objects[name] = object }
            return ["class": object.className, "print": String(object.printString.prefix(300))]
        case "start-chat":
            let runtime = try await engine.pharo.started()
            let object = try await runtime.evaluate(a["code"] as! String)
            let (chat, _) = try await chats.start(about: object, from: .snippet(snippetID: UUID()), label: a["label"] as? String ?? "a snippet",
                                                  source: a["code"] as? String)
            return ["id": chat.id.uuidString, "class": object.className]
        case "show-subject":
            let chat = chats.chat(withID: try uuid(a, "chat"))!
            guard case .instruction(let place) = chats.subject(of: chat) else { return ["error": "not an instruction chat"] }
            var out: [String: Any] = [
                "address": (place.address.map { String(format: "0x%llx", $0) } as Any?) ?? NSNull(), "presence": "\(place.presence)",
                "reason": place.unavailableReason ?? NSNull(), "has_node": engine.node(forSessionID: place.sessionID) != nil,
            ]
            out["memory_reason"] = await engine.disassemblyUnavailableReason(at: place) ?? NSNull()
            if let address = place.address {
                do {
                    let insight = try engine.disassemblyInsight(at: place)
                    out["insight"] = insight.id.uuidString
                    out["in_cache"] = (engine.insightsBySession[place.sessionID] ?? []).contains { $0.id == insight.id }
                    out["in_store"] = ((try? engine.store.fetchInsights(sessionID: place.sessionID)) ?? []).contains { $0.id == insight.id }
                } catch {
                    out["insight_error"] = "\(error)"
                }
                let lines = await engine.disassembler(forSessionID: place.sessionID)?.disassemble(DisassemblyRequest(address: address, count: 3, appearance: .light)) ?? []
                out["lines"] = lines.map { String(format: "0x%llx ", $0.address) + $0.asmText.plainText }
                let runtime = try await engine.pharo.started()
                do {
                    let instruction = try await engine.instruction(at: address, in: place.sessionID, runtime: runtime)
                    out["instruction"] = instruction.printString
                } catch {
                    out["instruction_error"] = "\(error)"
                }
            }
            return out
        case "add-object":
            let runtime = try await engine.pharo.started()
            let object = try await runtime.evaluate(a["code"] as! String)
            do {
                let added = try await chats.add(object, to: try uuid(a, "chat"), named: a["name"] as? String, inPlaceOf: a["in_place_of"] as? String)
                let size = added.snapshot.map { (try? JSONEncoder().encode($0).count) ?? -1 } ?? -1
                return ["object_id": added.objectID, "snapshot_bytes": size]
            } catch {
                return ["error": error.localizedDescription]
            }
        case "column":
            _ = try await chats.column(of: try uuid(a, "chat"))
            return ["live": Array(chats.thread(of: try uuid(a, "chat")).liveObjectIDs).sorted()]
        case "outbox":
            let queued = (try? engine.store.fetchOutbox()) ?? []
            var kinds: [String: Int] = [:]
            for op in queued {
                let kind: String
                switch op {
                case .notebook: kind = "notebook"
                case .session: kind = "session"
                case .customInstrument: kind = "custom-instrument"
                case .pattern: kind = "pattern"
                case .mission(let m): kind = "mission:\(m.toJSON()["kind"] as? String ?? "?")"
                case .objectChat(let o): kind = o.kind
                }
                kinds[kind, default: 0] += 1
            }
            return ["total": queued.count, "kinds": kinds]
        case "warnings":
            collectWarnings()
            return ["warnings": warnings]
        case "arrivals":
            return ["arrivals": arrivals]
        case "attach":
            let pid = UInt(a["pid"] as! Int)
            let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
            let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
            var session = engine.prepareAttachSession(device: device, process: process)
            if let reuse = (a["session"] as? String).flatMap(UUID.init(uuidString:)), var existing = engine.sessions.first(where: { $0.id == reuse }) {
                existing.lastKnownPID = process.pid
                session = existing
            }
            _ = try await engine.attach(device: device, process: process, session: session)
            let deadline = Date().addingTimeInterval(30)
            while engine.node(forSessionID: session.id)?.modules.isEmpty != false {
                guard Date() < deadline else { throw Failure("timed out waiting for the attached session's modules") }
                try await Task.sleep(for: .milliseconds(50))
            }
            return ["session": session.id.uuidString]
        case "send-shapes":
            let sessionID = try uuid(a, "session")
            let shapes = try Shapes(sessionID: sessionID)
            for cell in shapes.cells {
                try engine.store.save(cell)
                collaboration.enqueueAddReplCell(sessionID: sessionID, cell: cell)
            }
            try engine.store.save(shapes.trace)
            collaboration.enqueueUpsertTrace(sessionID: sessionID, trace: shapes.trace)
            engine.addNotebookEntry(shapes.entry)
            return ["ids": shapes.ids, "encoded": try shapes.encoded(cells: shapes.cells, trace: shapes.trace, entry: shapes.entry)]
        case "read-shapes":
            let sessionID = try uuid(a, "session")
            let ids = a["ids"] as! [String: Any]
            let cellIDs = (ids["cells"] as! [String]).compactMap(UUID.init(uuidString:))
            let cells = try cellIDs.compactMap { try engine.store.fetchREPLCell(id: $0) }
            let trace = try engine.store.fetchITraces(sessionID: sessionID).first { $0.id.uuidString == ids["trace"] as? String }
            let entry = try engine.store.fetchNotebookEntry(id: UUID(uuidString: ids["entry"] as! String)!)
            guard cells.count == cellIDs.count, let trace, let entry else {
                return ["complete": false, "cells": cells.count, "trace": trace != nil, "entry": entry != nil]
            }
            return ["complete": true, "encoded": try Shapes.encode(cells: cells, trace: trace, entry: entry)]
        case "detach":
            let sessionID = try uuid(a, "session")
            if let node = engine.node(forSessionID: sessionID) { engine.removeNode(node) }
            try await Task.sleep(for: .milliseconds(300))
            return try await handle("sessions", [:])
        case "sessions":
            return ["sessions": engine.sessions.map { ["id": $0.id.uuidString, "host": nul($0.host?.id), "phase": "\($0.phase)", "process": $0.processName, "pid": $0.lastKnownPID,
                                                       "live_here": engine.node(forSessionID: $0.id) != nil] }]
        case "mission-start":
            let mission = engine.startMission(goal: a["goal"] as! String, providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 4096)
            return ["id": mission?.id.uuidString ?? NSNull()]
        case "missions":
            let missions = (try? engine.store.fetchMissions()) ?? []
            return ["missions": missions.map { mission -> [String: Any] in
                let actions = (try? engine.store.fetchMissionActions(missionID: mission.id)) ?? []
                let turns = (try? engine.store.fetchMissionTurns(missionID: mission.id)) ?? []
                return [
                    "id": mission.id.uuidString, "status": mission.status.rawValue, "editors": mission.editors.map(\.id), "goal": mission.goalText,
                    "pending_text": engine.pendingSteering(missionID: mission.id).map(\.text).joined(separator: "\n\n"), "tokens_in": mission.tokensUsedInput, "tokens_out": mission.tokensUsedOutput,
                    "actions": actions.map { ["id": $0.id.uuidString, "tool": $0.toolName, "status": $0.status.rawValue, "executor": nul($0.executor?.id), "session": nul($0.sessionID?.uuidString), "summary": nul($0.resultSummary),
                                              "result": nul($0.resultJSON.map { String($0.prefix(200)) })] },
                    "turns": turns.map { ["id": $0.id.uuidString, "index": $0.index, "role": $0.role.rawValue, "content": String($0.contentJSON.prefix(240))] },
                ]
            }]
        case "approve":
            await engine.approveMissionAction(actionID: try uuid(a, "action"))
            return [:]
        case "reject-action":
            await engine.rejectMissionAction(actionID: try uuid(a, "action"), reason: a["reason"] as? String)
            return [:]
        case "answer":
            engine.submitUserInputResponse(actionID: try uuid(a, "action"), answer: a["text"] as! String)
            return [:]
        case "mission-delete":
            engine.deleteMission(missionID: try uuid(a, "mission"))
            return [:]
        case "mission-say":
            engine.appendMissionUserMessage(missionID: try uuid(a, "mission"), text: a["text"] as! String)
            return [:]
        case "mission-cancel":
            engine.cancelMission(missionID: try uuid(a, "mission"))
            return [:]
        case "set":
            if let value = a["runs_without_asking"] as? Bool { LumaAppState.shared.objectChatRunsWithoutAsking = value }
            return [:]
        case "unsent":
            return ["unsent": Dictionary(uniqueKeysWithValues: chats.unsent.map { ($0.key.uuidString, $0.value) }), "removed_in_lab": chats.removedInLab.map(\.uuidString)]
        case "resend":
            chats.resend(try uuid(a, "message"), in: try uuid(a, "chat"))
            return [:]
        case "can-delete":
            return ["can": engine.canDelete(missionID: try uuid(a, "mission"))]
        case "push-subscribe":
            collaboration.registerPushSubscriptions([["platform": "web", "endpoint": a["endpoint"] as! String, "p256dh": a["p256dh"] as! String, "auth": a["auth"] as! String]])
            try await Task.sleep(for: .milliseconds(500))
            return ["registered": Array(collaboration.registeredPushPlatforms)]
        case "transitions":
            return ["transitions": transitions]
        case "can":
            let chatID = try uuid(a, "chat")
            var reply: [String: Any] = ["delete": chats.canDelete(chatID), "rename": chats.canRename(chatID)]
            if let messageID = (a["message"] as? String).flatMap(UUID.init(uuidString:)), let message = chats.thread(of: chatID).messages.first(where: { $0.id == messageID }) {
                reply["edit"] = chats.canEdit(message)
                reply["remove"] = chats.canRemove(message)
            }
            return reply
        case "problems":
            return ["problems": chats.problems.map { p -> [String: Any] in
                ["id": p.id.uuidString, "kind": "\(p.kind)", "chat": p.chatID?.uuidString ?? NSNull(), "message": p.messageID?.uuidString ?? NSNull(), "reason": p.reason]
            }]
        case "dismiss":
            chats.dismiss(try uuid(a, "problem"))
            return ["left": chats.problems.count]
        case "start-instruction-chat":
            let sessionID = try uuid(a, "session")
            let address = UInt64((a["address"] as! String).dropFirst(2), radix: 16)!
            do {
                let (chat, _) = try await chats.start(aboutInstructionAt: engine.anchor(sessionID: sessionID, address: address), in: sessionID)
                return ["id": chat.id.uuidString]
            } catch {
                return ["error": "\(error)"]
            }
        case "choice":
            let choice = chats.modelChoice(in: try uuid(a, "chat"))
            return ["provider": choice.providerID, "model": choice.modelID]
        case "set-choice":
            chats.setModelChoice(ObjectChatModelChoice(providerID: a["provider"] as! String, modelID: a["model"] as! String), in: try uuid(a, "chat"))
            return [:]
        case "can-answer":
            return ["reason": await chats.answerUnavailableReason(in: try uuid(a, "chat")) ?? NSNull()]
        case "instr-rich":
            var def = engine.createCustomInstrument(name: a["name"] as! String)
            let rule = ObjectField(id: "depth", name: "Depth", schema: .uint(default: 3, min: 1, max: 9), optional: false, enabledByDefault: true)
            def.settings = [
                .init(id: "on", name: "On", schema: .boolean(default: true)),
                .init(id: "count", name: "Count", schema: .int(default: -2, min: -5, max: 5)),
                .init(id: "size", name: "Size", schema: .uint(default: 7, min: nil, max: nil)),
                .init(id: "ratio", name: "Ratio", schema: .double(default: 0.5, min: 0, max: 1)),
                .init(id: "label", name: "Label", schema: .string(default: "hi")),
                .init(id: "pattern", name: "Pattern", schema: .regex(default: "^a.*")),
                .init(id: "mode", name: "Mode", schema: .combo(choices: [.init(id: "fast", name: "Fast"), .init(id: "slow", name: "Slow")], default: "slow")),
                .init(id: "nested", name: "Nested", schema: .object(fields: [ObjectField(id: "deep", name: "Deep", schema: .boolean(default: false), optional: true, enabledByDefault: false)])),
                .init(id: "ports", name: "Ports", schema: .array(item: .int, default: [.int(80), .int(443)])),
                .init(id: "rules", name: "Rules", schema: .array(item: .object(fields: [rule]), default: [.object(["depth": .uint(5)])]), optional: true, enabledByDefault: false),
            ]
            def.widgets = [
                InstrumentWidget(id: "hits", name: "Hits", kind: .counter(.init(unit: "calls")), actions: [.init(id: "reset", name: "Reset")]),
                InstrumentWidget(id: "rows", name: "Rows", kind: .table(.init(columns: [.init(id: "addr", name: "Address", alignment: .trailing)],
                    rowActions: [.init(id: "open", name: "Open")])), actions: [.init(id: "clear", name: "Clear")]),
                InstrumentWidget(id: "plain", name: nil, kind: .counter(.init())),
            ]
            engine.updateCustomInstrument(def)
            return ["def": def.id.uuidString]
        case "counter-instr":
            var def = engine.createCustomInstrument(name: "Counters")
            def.widgets = [InstrumentWidget(id: "bytes", name: "Bytes", kind: .counter(.init()), persistence: .session)]
            engine.updateCustomInstrument(def)
            try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: """
                export const instrument: CustomInstrument = {
                    create(ctx) {
                        const bytes = ctx.widget("bytes");
                        const steps = [
                            { value: 2.5, unit: "calls" },
                            { value: 3, unit: "calls" },
                            { value: 4, unit: "calls", fractionDigits: 7 },
                            { value: 1, unit: "KiB", fractionDigits: 1 },
                        ];
                        steps.forEach((step, i) => setTimeout(() => bytes.setCounter(step), 300 * (i + 1)));
                        return {};
                    },
                };
                """)
            return ["def": def.id.uuidString]
        case "counter-text":
            let instanceID = try uuid(a, "instance")
            guard let counter = engine.widgetState(instanceID: instanceID, widget: "bytes").counter else { return ["counter": NSNull()] }
            let text = engine.counterText(counter, instanceID: instanceID, widget: "bytes")
            return ["counter": ["value": counter.value, "unit": nul(counter.unit), "fraction_digits": nul(counter.fractionDigits), "text": text.value]]
        case "instr-shape":
            let def = try engine.store.fetchCustomInstrumentDef(id: try uuid(a, "def"))
            let shape = def.map { d -> String in
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let data = try! encoder.encode(["settings": AnyEncodable(d.settings), "widgets": AnyEncodable(d.widgets)])
                return String(decoding: data, as: UTF8.self)
            }
            return ["shape": shape ?? NSNull()]
        case "files-instrument":
            let sessionID = try uuid(a, "session")
            let names = ["export", "bad", "badtype", "big", "full", "twice", "late", "slow", "throws", "stream", "streambig", "hex4", "three"]
            let def = engine.createCustomInstrument(name: "Files")
            try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: fileInstrumentSource)
            var laidOut = try engine.store.fetchCustomInstrumentDef(id: def.id)!
            laidOut.widgets = [
        InstrumentWidget(id: "log", name: "Log", kind: .console(.init()), actions: names.map { .init(id: $0, name: $0) }),
        InstrumentWidget(id: "dump", name: "Dump", kind: .hex(.init(maxBytes: 8 * 1024 * 1024))),
    ]
            engine.updateCustomInstrument(laidOut)
            for _ in 0..<100 where engine.customInstruments.bundle(forDefID: def.id)?.def.widgets.isEmpty != false {
                try await Task.sleep(for: .milliseconds(50))
            }
            await engine.awaitCustomInstrumentReload(defID: def.id)
            let descriptor = engine.descriptor(withID: "custom:\(def.id.uuidString)")!
            let instance = await engine.addInstrument(
                kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: sessionID)!
            return ["instance": instance.id.uuidString]
        case "children-instrument":
            let sessionID = try uuid(a, "session")
            let names = ["add", "add2", "rename", "remove", "show", "addtmp", "many", "bad"]
            let def = engine.createCustomInstrument(name: "Kids")
            try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: childrenInstrumentSource)
            var laidOut = try engine.store.fetchCustomInstrumentDef(id: def.id)!
            laidOut.widgets = [InstrumentWidget(id: "log", name: "Log", kind: .console(.init()), actions: names.map { .init(id: $0, name: $0) })]
            laidOut.children = [
                InstrumentChildTemplate(id: "bin", name: "Bins", widgets: [
                    InstrumentWidget(id: "rows", name: "Rows", kind: .table(.init(columns: [.init(id: "name", name: "Name")], rowActions: [.init(id: "poke", name: "Poke")])),
                                     persistence: .session),
                    InstrumentWidget(id: "note", name: "Note", kind: .console(.init())),
                ]),
                InstrumentChildTemplate(id: "tmp", name: "Temporaries", widgets: [InstrumentWidget(id: "count", name: "Count", kind: .counter(.init()))]),
            ]
            engine.updateCustomInstrument(laidOut)
            for _ in 0..<100 where engine.customInstruments.bundle(forDefID: def.id)?.def.children.count != 2 {
                try await Task.sleep(for: .milliseconds(50))
            }
            await engine.awaitCustomInstrumentReload(defID: def.id)
            let descriptor = engine.descriptor(withID: "custom:\(def.id.uuidString)")!
            let instance = await engine.addInstrument(
                kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: sessionID)!
            return ["instance": instance.id.uuidString]
        case "kids":
            let instanceID = try uuid(a, "instance")
            return ["children": engine.children(of: instanceID).map { child -> [String: Any] in
                ["template": child.ref.template, "id": child.ref.id, "title": child.title, "position": child.position, "subtitle": child.subtitle ?? NSNull(),
                 "badge": child.badge.map { ["text": $0.text, "tone": $0.tone.rawValue] } ?? NSNull(),
                 "rows": engine.widgetState(instanceID: instanceID, widget: child.widgetKey("rows")).tableRows.map(\.id),
                 "note": engine.widgetState(instanceID: instanceID, widget: child.widgetKey("note")).consoleEntries.map(\.text)]
            }]
        case "press-child-row":
            let instance = try engine.store.fetchInstrument(id: try uuid(a, "instance"))!
            let child = engine.children(of: instance.id).first { $0.ref == ChildRef(template: a["template"] as! String, id: a["id"] as! String) }!
            await engine.invokeRowAction(instance: instance, widget: child.widgetKey(a["widget"] as! String), action: a["action"] as! String, item: a["item"] as! String)
            return [:]
        case "selection":
            guard let request = engine.childSelectionRequest else { return ["selection": NSNull()] }
            return ["selection": ["instance": request.instanceID.uuidString, "child": request.child.map { ["template": $0.template, "id": $0.id] } ?? NSNull()]]
        case "consume-selection":
            engine.consumeChildSelectionRequest()
            return [:]
        case "descriptor":
            return ["found": engine.descriptor(withID: a["id"] as! String) != nil]
        case "gated-def":
            let def = engine.createCustomInstrument(name: "Gated")
            try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: """
                export const instrument: CustomInstrument = {
                    create(ctx) {
                        ctx.children("pane").add("p1", { title: "pane" });
                        ctx.widget("log").appendOutput("created");
                        return {};
                    },
                };
                """)
            try engine.writeCustomInstrumentFile(defID: def.id, path: "GateView.class.st", content: gateSource())
            var laidOut = try engine.store.fetchCustomInstrumentDef(id: def.id)!
            laidOut.widgets = [
                InstrumentWidget(id: "log", name: "Log", kind: .console(.init()), actions: [.init(id: "ping", name: "Ping")]),
                InstrumentWidget(id: "graph", name: "Graph", kind: .view(.init(className: "GateView"))),
            ]
            laidOut.children = [InstrumentChildTemplate(id: "pane", name: "Panes", widgets: [InstrumentWidget(id: "note", name: "Note", kind: .console(.init()))])]
            engine.updateCustomInstrument(laidOut)
            for _ in 0..<100 where engine.customInstruments.bundle(forDefID: def.id)?.def.children.count != 1 {
                try await Task.sleep(for: .milliseconds(50))
            }
            return ["def": def.id.uuidString]
        case "edit-gated-def":
            try engine.writeCustomInstrumentFile(defID: try uuid(a, "def"), path: "GateView.class.st", content: gateSource())
            return [:]
        case "gate":
            let instanceID = try uuid(a, "instance")
            guard let instance = try engine.store.fetchInstrument(id: instanceID) else { return ["known": false] }
            let node = engine.node(forSessionID: instance.sessionID)
            return [
                "known": true,
                "wanted": engine.instrumentViews.approvalWanted(byInstance: instanceID).map(\.provenance) ?? NSNull(),
                "awaits_host": engine.approvalAwaitedFromHost(of: instance)?.name ?? NSNull(),
                "attached": node?.instruments.first { $0.id == instanceID }?.attachment == .attached,
                "children": engine.children(of: instanceID).map(\.ref.id),
                "log": engine.widgetState(instanceID: instanceID, widget: "log").consoleEntries.map(\.text),
                "can_ping": engine.canChoose("ping", of: "log", instance: instance),
                "gate": { switch engine.gate(of: instance) {
                    case .none: "none"
                    case .awaitingHost(let name): "host:\(name)"
                    case .awaitingYou: "you"
                } }(),
                "waiting": engine.gate(of: instance).waitingLabel ?? NSNull(),
                "shown_children": engine.shownChildren(of: instanceID).map(\.ref.id),
            ]
        case "allow":
            engine.instrumentViews.allow(instance: try uuid(a, "instance"))
            return [:]
        case "can-press":
            guard let instance = try engine.store.fetchInstrument(id: try uuid(a, "instance")) else { return ["can": false] }
            return ["can": engine.canChoose(a["action"] as! String, of: "log", instance: instance)]
        case "press":
            let instance = try engine.store.fetchInstrument(id: try uuid(a, "instance"))!
            await engine.invokeWidgetAction(instance: instance, widget: "log", action: a["action"] as! String)
            return [:]
        case "offered":
            return ["files": engine.offeredFiles.map { ["id": $0.id.uuidString, "name": $0.name, "media_type": $0.mediaType, "instrument": $0.instrumentName] }]
        case "save-offered":
            let file = engine.offeredFiles.first { $0.id.uuidString == a["id"] as? String }!
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAB_PROJECT"]!).appendingPathComponent("saved", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(file.id.uuidString)-\(file.name)")
            let key = a["key"] as! String
            saved[key] = ["state": "saving"]
            Task { @MainActor in
                do {
                    try await engine.saveOfferedFile(file.id, to: url)
                    let bytes = try Data(contentsOf: url)
                    saved[key] = ["state": "saved", "size": bytes.count, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
                } catch {
                    saved[key] = ["state": "failed", "error": error.localizedDescription, "exists": FileManager.default.fileExists(atPath: url.path)]
                }
            }
            return [:]
        case "saved":
            return ["saved": saved]
        case "decline-offered":
            engine.declineOfferedFile(UUID(uuidString: a["id"] as! String)!)
            return [:]
        case "decline-all":
            for file in engine.offeredFiles { engine.declineOfferedFile(file.id) }
            return [:]
        case "log":
            return ["log": engine.widgetState(instanceID: try uuid(a, "instance"), widget: "log").consoleEntries.map(\.text)]
        case "press-log":
            let instance = try engine.store.fetchInstrument(id: try uuid(a, "instance"))!
            await engine.invokeWidgetAction(instance: instance, widget: "log", action: a["action"] as! String)
            return [:]
        case "high-insights":
            let sessionID = try uuid(a, "session")
            var ids: [String] = []
            for high: UInt64 in [0xffff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0x7fff_ffff_ffff_ffff] {
                ids.append(try engine.getOrCreateInsight(sessionID: sessionID, pointer: high, kind: .memory, preferredAnchor: .absolute(high)).id.uuidString)
            }
            return ["insights": ids]
        case "insight-anchors":
            let sessionID = try uuid(a, "session")
            return ["insights": ((try? engine.store.fetchInsights(sessionID: sessionID)) ?? []).map {
                ["id": $0.id.uuidString, "anchor": $0.anchor.toolJSON, "last": ($0.lastResolvedAddress.map(HexAddress.string) as Any?) ?? NSNull()]
            }]
        case "tracer-with-hook":
            let sessionID = try uuid(a, "session")
            let added = await engine.addTracerHook(
                sessionID: sessionID, address: 0, kind: .function,
                preferredAnchor: .moduleExport(name: "LabTarget", export: "luma_target_score"), preferredDisplayName: "luma_target_score")
            return ["instance": added?.instrumentID.uuidString ?? NSNull()]
        case "codeshare-add":
            let config = CodeShareConfig(
                name: "Check", description: "A check", source: "", exports: [], project: CodeShareProjectRef(id: "1", owner: "lab", slug: "check"),
                lastSyncedHash: "abc", fridaVersion: "17.0.0")
            let instance = await engine.addInstrument(
                kind: .codeShare, sourceIdentifier: "lab/check", configJSON: try JSONEncoder().encode(config), sessionID: try uuid(a, "session"))
            return ["instance": instance?.id.uuidString ?? NSNull()]
        case "instance-add":
            let sessionID = try uuid(a, "session")
            let descriptor = engine.descriptor(withID: a["descriptor"] as! String)!
            let config = (a["config"] as? [String: Any]).map { try! JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) } ?? descriptor.makeInitialConfigJSON()
            let instance = await engine.addInstrument(kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: config, sessionID: sessionID)
            return ["instance": instance?.id.uuidString ?? NSNull()]
        case "instances":
            let sessionID = try uuid(a, "session")
            return ["instances": ((try? engine.store.fetchInstruments(sessionID: sessionID)) ?? []).map { i -> [String: Any] in
                let config = (try? JSONSerialization.jsonObject(with: i.configJSON, options: .fragmentsAllowed)).map { try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
                return ["id": i.id.uuidString, "kind": i.kind.rawValue, "source": i.sourceIdentifier, "config": config.map { String(decoding: $0, as: UTF8.self) } ?? NSNull()]
            }]
        case "listed":
            return ["listed": chats.listed.map(\.id.uuidString)]
        case "markers":
            let sessionID = try uuid(a, "session")
            return ["markers": (engine.addressAnnotations[sessionID] ?? [:]).filter { !$0.value.chatIDs.isEmpty }.map { address, annotation -> [String: Any] in
                ["address": String(format: "0x%llx", address), "chats": annotation.chatIDs.map(\.uuidString)]
            }]
        case "repl-eval":
            let result = await engine.node(forSessionID: try uuid(a, "session"))!.evalInREPL(a["code"] as! String)
            return ["ok_result": result != nil]
        case "lab-holds":
            return ["holds": engine.collaboration.labHolds(sessionID: try uuid(a, "session"))]
        case "can-remove-from-lab":
            let sessionID = try uuid(a, "session")
            return ["can": engine.canRemoveFromLab(engine.sessions.first { $0.id == sessionID }!)]
        case "session-delete":
            engine.deleteSession(id: try uuid(a, "session"))
            return [:]
        case "calls":
            return ["calls": chats.thread(of: try uuid(a, "chat")).toolCalls.map { ["id": $0.id.uuidString, "tool": $0.tool, "status": "\($0.status)",
                "executor": nul($0.executor?.id), "asked_by": nul($0.askedBy?.id), "hold": chats.hold(on: $0).map { "\($0)" } ?? NSNull()] }]
        case "hold":
            let call = chats.call(try uuid(a, "call"))
            return ["hold": call.flatMap { chats.hold(on: $0) }.map { "\($0)" } ?? NSNull()]
        case "set-role":
            await collaboration.setMemberRole(userID: a["user"] as! String, role: a["role"] as! String == "owner" ? .owner : .member)
            return [:]
        case "claim":
            let pid = UInt(a["pid"] as! Int)
            let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
            let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
            await engine.claimHosting(sessionID: try uuid(a, "session"), device: device, process: process)
            try await Task.sleep(for: .milliseconds(500))
            return try await handle("sessions", [:])
        case "external-mcp":
            let info = try await engine.enableExternalMCPServer()
            return ["url": info.url.absoluteString, "token": info.bearerToken, "mission": info.missionID.uuidString]
        case "instr-create":
            let def = engine.createCustomInstrument(name: a["name"] as! String)
            return ["def": def.id.uuidString, "name": def.name]
        case "instr-edit":
            let defID = try uuid(a, "def")
            engine.updateCustomInstrument(defID) { $0.name = a["name"] as! String }
            return [:]
        case "instr-delete":
            await engine.deleteCustomInstrument(try uuid(a, "def"))
            return [:]
        case "instrs":
            let defs = (try? engine.store.fetchCustomInstrumentDefs()) ?? []
            return ["defs": defs.map { ["id": $0.id.uuidString, "name": $0.name] }]
        case "instr-link":
            let def = try engine.linkInstrumentFolder(at: URL(fileURLWithPath: a["path"] as! String, isDirectory: true))
            return ["def": def.id.uuidString, "name": def.name]
        case "def-state":
            let defID = try uuid(a, "def")
            let def = try engine.store.fetchCustomInstrumentDef(id: defID)
            return [
                "stored": def != nil,
                "files": (try engine.store.fetchCustomInstrumentFiles(defID: defID)).count,
                "kept_from_lab": engine.subjectsKeptFromLab.contains(LabSubject(.definition, defID)),
                "lab_problems": engine.labProblems.map(\.reason),
                "queued": (try engine.store.fetchOutboxOps(CustomInstrumentOp.self)).filter { $0.defID == defID }.count,
            ]
        case "instr-export":
            try engine.exportCustomInstrument(defID: try uuid(a, "def"), to: URL(fileURLWithPath: a["path"] as! String, isDirectory: true))
            return [:]
        case "instr-reload":
            try engine.reloadCustomInstrumentFromFolder(defID: try uuid(a, "def"))
            return [:]
        case "pattern-create":
            let source = try engine.patterns.create(named: a["name"] as! String, kind: .pattern, text: a["text"] as? String ?? "u8 x @ 0;")
            return ["id": source.id]
        case "pattern-write":
            try engine.patterns.write(a["text"] as! String, to: a["id"] as! String)
            return [:]
        case "pattern-delete":
            try engine.patterns.delete(a["id"] as! String)
            return [:]
        case "patterns":
            let records = (try? engine.store.fetchPatternSources()) ?? []
            return ["patterns": records.map { ["id": $0.id.uuidString, "name": $0.name] }]
        case "kept":
            return ["kept": engine.subjectsKeptFromLab.map { ["family": "\($0.family)", "id": $0.id.uuidString] }]
        case "add-to-lab":
            let family: LabSubject.Family = (a["family"] as! String) == "pattern" ? .pattern : .definition
            engine.addToLab(LabSubject(family, try uuid(a, "id")))
            return [:]
        case "action-rights":
            guard let action = try? engine.store.fetchMissionAction(id: try uuid(a, "action")) else { return ["missing": true] }
            return ["can_approve": engine.canApprove(action), "is_executor": engine.isExecutor(of: action), "hold": engine.hold(on: action).map { "\($0)" } ?? NSNull(),
                    "executor": action.executor?.id ?? NSNull(), "status": action.status.rawValue]
        case "waiting-for-starter":
            guard let mission = try? engine.store.fetchMission(id: try uuid(a, "mission")) else { return ["missing": true] }
            return ["waiting": engine.isWaitingForStarter(mission), "status": mission.status.rawValue]
        case "lab-problems":
            return ["problems": engine.labProblems.map { ["id": $0.id.uuidString, "concern": String("\($0.concern)".prefix(160)), "reason": $0.reason] }]
        case "steering":
            let missionID = try uuid(a, "mission")
            let row = { (s: MissionSteer) -> [String: Any] in ["id": s.id.uuidString, "author": nul(s.author?.id), "text": String(s.text.prefix(200)), "created_at": "\(s.createdAt)"] }
            return ["all": engine.pendingSteering(missionID: missionID).map(row), "mine": engine.myPendingSteering(missionID: missionID).map(row)]
        case "sleep":
            try await Task.sleep(for: .milliseconds(Int((a["seconds"] as? Double ?? 1) * 1000)))
            return [:]
        case "quit":
            await engine.shutdown()
            try? await engine.deviceManager.close()
            emit(["_id": a["_id"] ?? 0, "ok": true])
            exit(0)
        default:
            throw Failure("unknown command \(cmd)")
        }
    }

    func describe(_ call: ObjectChatToolCall?) -> Any {
        guard let call else { return NSNull() }
        return [
            "id": call.id.uuidString, "tool": call.tool, "status": call.status.rawValue, "executor": call.executor?.id ?? NSNull(),
            "asked_by": call.askedBy?.id ?? NSNull(), "summary": call.summary ?? NSNull(), "error": call.error ?? NSNull(),
            "object_id": call.objectID ?? NSNull(), "result": call.result.map { String($0.prefix(300)) } ?? NSNull(),
            "message_id": call.messageID.uuidString, "reply_to": call.replyTo.uuidString, "tool_call_id": call.toolCallID,
            "session_arg": { if case .string(let s) = call.args["session_id"] { return s } else { return NSNull() } }() as Any,
            "stranded": engine.objectChats.isStranded(call),
        ]
    }

    func describeThread(_ chatID: UUID) -> [String: Any] {
        let chats = engine.objectChats
        let thread = chats.thread(of: chatID)
        return [
            "exists": chats.chats.contains { $0.id == chatID },
            "removed_in_lab": chats.removedInLab.contains(chatID),
            "messages": thread.messages.map { m -> [String: Any] in
                ["id": m.id.uuidString, "index": m.index, "role": m.role.rawValue, "author": m.author?.id ?? NSNull(), "body": String(m.bodyMarkdown.prefix(160)),
                 "asks": m.asksAssistant, "reply_to": m.replyTo?.uuidString ?? NSNull(), "error": m.error ?? NSNull(),
                 "unsent": chats.unsent[m.id] ?? NSNull(), "provider": m.providerID ?? NSNull(), "model": m.modelID ?? NSNull()]
            },
            "calls": thread.toolCalls.map { describe($0) },
            "objects": thread.objects.map { o -> [String: Any] in
                ["object_id": o.objectID, "class": o.className, "print": String(o.printString.prefix(80)), "added_by": o.addedBy?.id ?? NSNull(),
                 "produced_by": o.producedBy?.uuidString ?? NSNull(), "has_snapshot": o.snapshot != nil, "live": thread.liveObjectIDs.contains(o.objectID)]
            },
            "unread": chats.unreadCount(in: chatID),
            "reply_text": thread.replyText ?? NSNull(),
            "stored_messages": ((try? engine.store.fetchObjectChatMessages(chatID: chatID)) ?? []).count,
        ]
    }
}

struct Failure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func sanitize(_ value: Any) -> Any {
    if let dict = value as? [String: Any] { return dict.mapValues(sanitize) }
    if let array = value as? [Any] { return array.map(sanitize) }
    if value is NSNull || value is String || value is Bool || value is Int || value is Double { return value }
    if let number = value as? NSNumber { return number }
    return "\(value)"
}

@MainActor
func main() async throws {
    let env = ProcessInfo.processInfo.environment
    let login = env["LAB_LOGIN"]!
    let gid = env["LAB_GID"]!
    let project = URL(fileURLWithPath: env["LAB_PROJECT"]!, isDirectory: true)
    OfflineWeb.login = login
    URLProtocol.registerClass(OfflineWeb.self)

    let data = project.appendingPathComponent("data", isDirectory: true)
    let tokens = data.appendingPathComponent("Tokens", isDirectory: true)
    try FileManager.default.createDirectory(at: tokens, withIntermediateDirectories: true)
    try Data("user:\(login):\(gid)".utf8).write(to: tokens.appendingPathComponent("github"))
    let traces = project.appendingPathComponent("traces", isDirectory: true)
    try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)

    let store = try ProjectStore(path: project.appendingPathComponent("db.sqlite").path)
    let engine = Engine(store: store, blobs: try BlobStore(directory: traces), dataDirectory: data)
    await engine.start()
    let provider = ScriptedProvider()
    provider.engine = engine
    engine.llmRegistry.register(provider)
    var defaults = LumaAppState.shared.missionDefaults
    defaults.providerID = "scripted"
    defaults.modelID = "scripted-1"
    LumaAppState.shared.missionDefaults = defaults
    LumaAppState.shared.objectChatRunsWithoutAsking = false
    let member = Member(engine: engine, provider: provider)
    emit(["event": "ready", "login": login, "portal": BackendConfig.portalAddress, "version": LumaVersion.string,
          "app_support": LumaAppPaths.shared.dataDirectory.path])

    let lines = AsyncStream<String> { continuation in
        Thread.detachNewThread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(0, &buffer, buffer.count)
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                while let newline = pending.firstIndex(of: 10) {
                    continuation.yield(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            continuation.finish()
        }
    }
    for await line in lines {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let cmd = object["cmd"] as? String else { continue }
        let id = object["_id"] ?? 0
        Task { @MainActor in
            do {
                var reply = try await member.handle(cmd, object)
                reply["_id"] = id
                reply["ok"] = true
                emit(sanitize(reply) as! [String: Any])
            } catch {
                emit(["_id": id, "ok": false, "error": "\(error.localizedDescription)"])
            }
        }
    }
    exit(0)
}

Task { @MainActor in
    do {
        try await main()
    } catch {
        emit(["event": "fatal", "error": "\(error)"])
        exit(1)
    }
}
RunLoop.main.run()

func nul<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

struct AnyEncodable: Encodable {
    let encode: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encode = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encode(encoder)
    }
}

var fileInstrumentSource: String { """
const ascii = (text: string): number[] => Array.from(text, (c: string) => c.charCodeAt(0));
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

export const instrument: CustomInstrument = {
    create(ctx) {
        const log = ctx.widget("log");
        const tell = (e: Error) => log.appendOutput(`${e.constructor.name}: ${e.message}`);
        return {
            async onAction({ action }, respond) {
                try {
                    switch (action) {
                        case "export":
                            respond.file({ name: "cube.obj", mediaType: "model/obj", bytes: ascii("v 0 0 0\\n") });
                            break;
                        case "bad":
                            respond.file({ name: "a/b.obj", mediaType: "model/obj", bytes: [1] });
                            break;
                        case "badtype":
                            respond.file({ name: "b.obj", mediaType: "obj", bytes: [1] });
                            break;
                        case "big":
                            respond.file({ name: "big.bin", mediaType: "application/octet-stream", bytes: new Uint8Array(64 * 1024 * 1024 + 1) });
                            break;
                        case "full":
                            respond.file({ name: "full.bin", mediaType: "application/octet-stream", bytes: new Uint8Array(64 * 1024 * 1024).fill(7) });
                            break;
                        case "twice":
                            respond.file({ name: "one.txt", mediaType: "text/plain", bytes: ascii("1") });
                            respond.file({ name: "two.txt", mediaType: "text/plain", bytes: ascii("2") });
                            break;
                        case "late":
                            setTimeout(() => { try { respond.file({ name: "late.txt", mediaType: "text/plain", bytes: [1] }); } catch (e) { tell(e as Error); } }, 50);
                            break;
                        case "slow":
                            await sleep(800);
                            respond.file({ name: "slow.txt", mediaType: "text/plain", bytes: ascii("slow") });
                            break;
                        case "three": {
                            const bytes = new Uint8Array(3 * 1024 * 1024);
                            for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 7) % 256;
                            respond.file({ name: "three.bin", mediaType: "application/octet-stream", bytes });
                            break;
                        }
                        case "hex4":
                            ctx.widget("dump").setHex({ bytes: new Uint8Array(4 * 1024 * 1024 + 1024).fill(9).buffer });
                            break;
                        case "stream":
                        case "streambig": {
                            const out = respond.file({ name: `${action}.bin`, mediaType: "application/octet-stream" });
                            out.on("error", (e: Error) => log.appendOutput(`stream error: ${e.constructor.name}: ${e.message}`));
                            const pieces = action === "stream" ? 3 : 65;
                            const size = action === "stream" ? 2 * 1024 * 1024 : 1024 * 1024;
                            (async () => {
                                for (let i = 1; i <= pieces; i++) {
                                    await new Promise<void>((resolve, reject) =>
                                        out.write(new Uint8Array(size).fill(i), (e?: Error | null) => e ? reject(e) : resolve()));
                                    log.appendOutput(`written ${i}`);
                                }
                                out.end(() => log.appendOutput("finished"));
                            })().catch(() => {});
                            break;
                        }
                        case "throws":
                            respond.file({ name: "thrown.txt", mediaType: "text/plain", bytes: [1] });
                            throw new Error("after offering");
                    }
                } catch (e) {
                    if (action === "throws") throw e;
                    tell(e as Error);
                }
            },
            onConsoleInput({ text }, respond) {
                respond.file({ name: "typed.txt", mediaType: "text/plain", bytes: ascii(text) });
            },
        };
    },
};
""" }

var childrenInstrumentSource: String { """
const tell = (e: unknown) => `${(e as Error).constructor.name}: ${(e as Error).message}`;

export const instrument: CustomInstrument = {
    create(ctx, config, restored) {
        const bins = ctx.children("bin");
        const temps = ctx.children("tmp");
        const log = ctx.widget("log");
        log.appendOutput(`restored ${Object.keys(restored.children?.bin ?? {}).join(",")} live ${bins.ids().join(",")}`);
        return {
            onAction(action, respond) {
                if (action.child !== undefined) {
                    log.appendOutput(`pressed ${action.action} on ${action.child.template}/${action.child.id} row ${action.item}`);
                    return;
                }
                switch (action.action) {
                    case "add": {
                        const bin = bins.add("b1", { title: "first", subtitle: "GstPipeline", badge: { text: "playing", tone: "active" } });
                        bin.widget("rows").upsertRow({ id: "r", cells: { name: "x" } });
                        bin.widget("note").appendOutput("hello from b1");
                        break;
                    }
                    case "add2":
                        bins.add("b2", { title: "second" });
                        break;
                    case "rename":
                        bins.get("b1")!.update({ title: "renamed", badge: { text: "paused", tone: "waiting" } });
                        break;
                    case "remove":
                        bins.remove("b2");
                        break;
                    case "show":
                        respond.show(bins.get("b1")!);
                        break;
                    case "addtmp":
                        temps.add("t1", { title: "transient" }).widget("count").setCounter({ value: 3 });
                        break;
                    case "many":
                        try {
                            for (let i = 0; i < 300; i++) temps.add(`m${i}`, { title: `m${i}` });
                        } catch (e) {
                            log.appendOutput(tell(e));
                        }
                        break;
                    case "bad":
                        try {
                            ctx.children("nope" as any);
                        } catch (e) {
                            log.appendOutput(tell(e));
                        }
                        break;
                }
            },
        };
    },
};
""" }

func gateSource() -> String {
    """
    "\(UUID().uuidString)"
    Class {
    \t#name : 'GateView',
    \t#superclass : 'Object',
    \t#category : 'Gate'
    }
    """
}

struct Shapes {
    let cells: [REPLCell]
    let trace: ITrace
    let entry: NotebookEntry

    init(sessionID: UUID) throws {
        let styled = StyledText(spans: [StyledText.Span(text: "a", foreground: RGBColor(r: 1, g: 2, b: 3), isBold: true), StyledText.Span(text: "b")])
        let graph = try JSONDecoder().decode(PharoGraph.self, from: Data(#"{"layout":"tree","nodes":[{"label":"a"},{"label":"b"}],"edges":[{"from":0,"to":1}]}"#.utf8))
        let chart = try JSONDecoder().decode(
            PharoChart.self,
            from: Data(#"{"scaleX":"linear","scaleY":"log","titleX":"t","titleY":"n","series":[{"kind":"bar","orientation":"vertical","points":[{"label":"p","x":1,"y":2}]}]}"#.utf8))
        let snapshot = PharoSnapshot(printString: "a Graph", className: "Graph", views: [
            .init(title: "Text", methodSelector: "gtTextFor:", content: .text("t"), priority: 1),
            .init(title: "Graph", methodSelector: "gtGraphFor:", content: .graph(graph), priority: 2),
            .init(title: "Chart", methodSelector: "gtChartFor:", content: .chart(chart), priority: 3),
        ])
        let results: [REPLCell.Result] = [
            .text("hi"), .styled(styled), .js(.string("v")),
            .binary(Data([1, 2]), meta: .init(typedArray: "Uint8Array", baseAddress: 0xffff_ffff_ffff_ff00)),
        ]
        cells = results.enumerated().map { REPLCell(sessionID: sessionID, code: "c\($0.offset)", result: $0.element) }
        trace = ITrace(sessionID: sessionID, origin: .functionCall(hookID: UUID(), callIndex: 3), displayName: "shapes", stoppedAt: Date())
        entry = NotebookEntry(kind: .pharo, title: "shapes", details: "d", styledDetails: styled, pharoSnapshot: snapshot, sessionID: sessionID)
    }

    var ids: [String: Any] {
        ["cells": cells.map(\.id.uuidString), "trace": trace.id.uuidString, "entry": entry.id.uuidString]
    }

    func encoded(cells: [REPLCell], trace: ITrace, entry: NotebookEntry) throws -> [String: Any] {
        try Self.encode(cells: cells, trace: trace, entry: entry)
    }

    static func encode(cells: [REPLCell], trace: ITrace, entry: NotebookEntry) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = { (value: any Encodable) in String(decoding: try encoder.encode(value), as: UTF8.self) }
        return [
            "results": try cells.map { try text($0.result) },
            "origin": try text(trace.origin),
            "styled_details": try entry.styledDetails.map(text) ?? NSNull(),
            "pharo_snapshot": try entry.pharoSnapshot.map(text) ?? NSNull(),
        ]
    }
}
