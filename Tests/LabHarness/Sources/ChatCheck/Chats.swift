import Foundation
@testable import LumaCore
import SwiftyPharo
import Observation

@MainActor
func live(engine: Engine, provider: ScriptedProvider, runtime: PharoRuntime, chats: ObjectChats, pid: UInt, gstreamer: String) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    try await waitFor("modules") { engine.node(forSessionID: session.id)?.modules.isEmpty == false }
    note("attached; session \(session.id)")

    note("== image: LumaChat")
    let loaded = try await loadGStreamer(from: gstreamer, into: runtime)
    expect(loaded.printString == "true", "GStreamer instrument classes load (\(loaded.printString))")
    let graph = try await runtime.evaluate("(ChatCheckCode classNamed: 'DotParser') parse: 'digraph pipeline { src -> sink; sink -> out; }'")
    note("   subject: \(graph.className) '\(graph.printString)'")
    _ = graph
    try await chatChecks(engine: engine, provider: provider, runtime: runtime, chats: chats, session: session, graph: graph)
}

@MainActor
func loadGStreamer(from gstreamer: String, into runtime: PharoRuntime) async throws -> PharoObject {
    try await runtime.evaluate(
        """
        | files code |
        files := (('\(gstreamer)' asFileReference filesMatching: '*.st') asSortedCollection: [ :a :b | a basename <= b basename ]) asArray
            collect: [ :each | Dictionary new at: 'path' put: 'gstreamer/' , each basename; at: 'source' put: each contents; yourself ].
        code := LumaInstrumentCode new.
        code install: files.
        Smalltalk globals at: #ChatCheckCode put: code.
        code isSound
        """)
}

@MainActor
func chatChecks(engine: Engine, provider: ScriptedProvider, runtime: PharoRuntime, chats: ObjectChats, session: ProcessSession, graph: PharoObject) async throws {

    let (chat, column) = try await chats.start(about: graph, from: .snippet(snippetID: UUID()), label: "a playground snippet", source: "DotParser parse: …")
    expect(column.className == "LumaChat", "start answers the LumaChat column (\(column.className) '\(column.printString)')")
    let columnViews = try await runtime.views(of: column)
    expect(columnViews.map(\.viewName).contains("lumaChat") && columnViews.first { $0.viewName == "lumaChat" }?.text == chat.id.uuidString,
        "LumaChat declares a lumaChat view whose text is the chat id")
    let objectsPage = try await runtime.items(of: column, view: "gtObjectsFor:", from: 1, count: 5)
    let drilled = try await runtime.drillInto(column, view: "gtObjectsFor:", index: 1)
    expect(objectsPage.total == 1 && drilled.className == graph.className, "Objects view lists o1 and drills to it (\(objectsPage.items.map { $0.map { $0.text ?? "" } }), \(drilled.className))")
    expect(chats.thread(of: chat.id).objects.first?.snapshot != nil, "o1 has a snapshot")
    if case .object(_, let label, _, let className, _, _) = chat.subject { expect(className == graph.className && label == "a playground snippet", "object subject keeps class and origin label") }

    note("== the reply loop")
    provider.steps = [
        .reply([.text("First its node count. "), .tool("chat_evaluate", ["code": "nodes size"])]),
        .reply([.text("Now another class of the instrument. "), .tool("chat_evaluate", ["code": "DotNode name"])]),
        .reply([.text("And the size of that name. "), .tool("chat_evaluate", ["code": "found size", "bindings": [["name": "found", "object_id": "o3"]]])]),
        .reply([.text("Let me define a global. "), .tool("chat_evaluate", ["code": "Smalltalk at: #ChatZork put: 3"])]),
        .reply([.text("Something broken. "), .tool("chat_evaluate", ["code": "3 + + 4"])]),
        .reply([.text("Something endless. "), .tool("chat_evaluate", ["code": "[ true ] whileTrue"])]),
        .reply([.text("Its views and objects. "), .tool("chat_view", ["object_id": "o1", "view": "Raw"]), .tool("chat_objects", [:])]),
        .reply([.text("Done: it has 3 nodes.")]),
    ]
    let asking = Task { try await chats.ask("What is this?", in: chat.id) }
    func call(_ index: Int) -> ObjectChatToolCall? { chats.thread(of: chat.id).toolCalls.count > index ? chats.thread(of: chat.id).toolCalls[index] : nil }
    try await waitFor("the first proposed call") { call(0)?.status == .proposed }
    expect(chats.callsWaitingForMe.contains { $0.id == call(0)!.id }, "a proposed expression waits for me")
    expect(chats.thread(of: chat.id).replyText?.hasPrefix("First its node count.") == true, "reply text streams while the call waits")
    expect(call(0)!.offset == "First its node count. ".count, "call offset is the reply text before it (\(call(0)!.offset))")
    await chats.run(call(0)!.id)
    try await waitFor("the second call") { call(1)?.status == .proposed }
    expect(call(0)!.status == .succeeded && call(0)!.objectID == "o2", "self's instance variable is usable: nodes size -> \(call(0)!.summary ?? "?")")
    await chats.run(call(1)!.id)
    try await waitFor("the third call") { call(2)?.status == .proposed }
    expect(call(1)!.status == .succeeded && (call(1)!.summary ?? "").contains("DotNode"), "an instrument class names another of its classes: \(call(1)!.summary ?? call(1)!.error ?? "?")")
    await chats.run(call(2)!.id)
    try await waitFor("the fourth call") { call(3)?.status == .proposed }
    expect(call(2)!.status == .succeeded && (call(2)!.summary ?? "").hasSuffix("7"), "a binding resolves to a stored object: found size -> \(call(2)!.summary ?? call(2)!.error ?? "?")")
    chats.reject(call(3)!.id, reason: "not on my image")
    try await waitFor("the fifth call") { call(4)?.status == .proposed }
    expect(call(3)!.status == .rejected, "a rejected expression is recorded as rejected")
    expect(toolResults(in: provider.requests.last!).first?.contains("declined") == true, "the model hears the rejection: \(toolResults(in: provider.requests.last!).first ?? "")")
    let globalDefined = try await runtime.evaluate("Smalltalk globals includesKey: #ChatZork")
    expect(globalDefined.printString == "false", "the rejected expression never ran")
    await chats.run(call(4)!.id)
    try await waitFor("the sixth call") { call(5)?.status == .proposed }
    expect(call(4)!.status == .failed && call(4)!.errorPosition != nil, "a compile error fails with a position: \(call(4)!.error ?? "?") at \(String(describing: call(4)!.errorPosition))")
    let started = Date()
    await chats.run(call(5)!.id)
    try await waitFor("the views call", seconds: 40) { call(6) != nil }
    let took = Date().timeIntervalSince(started)
    expect(call(5)!.status == .failed && took > 9 && took < 20, "the deadline stops a runaway expression after \(Int(took)) s: \(call(5)!.error ?? "?")")
    let stillUsable = try await runtime.evaluate("3 + 4")
    expect(stillUsable.printString == "7", "the image is usable after the deadline")
    try await asking.value
    expect(call(6)!.status == .succeeded && call(7)!.status == .succeeded, "chat_view and chat_objects run at once: \(call(6)!.summary ?? "?"), \(call(7)!.summary ?? "?")")
    expect(toolResults(in: provider.requests.last!).first?.contains("rows") == true, "chat_view answers rows")
    var thread = chats.thread(of: chat.id)
    let answer = thread.messages.last!
    expect(thread.messages.count == 2 && answer.role == .assistant && answer.replyTo == thread.messages[0].id && answer.inputTokens == 800,
        "the answer is appended, replying to the question, with its usage (\(answer.inputTokens) in)")
    expect(thread.toolCalls.allSatisfy { $0.messageID == answer.id && $0.replyTo == thread.messages[0].id }, "every call belongs to the answer and its question")
    expect(answer.bodyMarkdown.contains("Done: it has 3 nodes."), "the answer's text is the streamed reply")
    expect(thread.objects.map(\.objectID) == ["o1", "o2", "o3", "o4"] && thread.objects.allSatisfy { $0.snapshot != nil }, "results are stored with snapshots: \(thread.objects.map { "\($0.objectID)=\($0.printString)" })")
    let opened = try await chats.open("o3", in: chat.id)
    let openedViews = try await runtime.views(of: opened)
    expect(opened.printString.contains("DotNode") && !openedViews.isEmpty, "a stored object opens as a fresh PharoObject whose views collect (\(openedViews.map(\.title)))")

    note("== run without asking, and cancel")
    LumaAppState.shared.objectChatRunsWithoutAsking = true
    provider.steps = [.reply([.text("Quickly. "), .tool("chat_evaluate", ["code": "id"])]), .reply([.text("It is pipeline.")])]
    try await chats.ask("Its id?", in: chat.id)
    thread = chats.thread(of: chat.id)
    expect(thread.newestCall!.status == .succeeded && chats.callsWaitingForMe.isEmpty, "with the setting on, an expression runs without waiting: \(thread.newestCall!.summary ?? "?")")
    LumaAppState.shared.objectChatRunsWithoutAsking = false
    provider.steps = [.reply([.text("Let me look. "), .tool("chat_evaluate", ["code": "edges size"])])]
    let cancelled = Task { try await chats.ask("And the edges?", in: chat.id) }
    try await waitFor("a waiting call to cancel") { chats.thread(of: chat.id).newestCall?.status == .proposed }
    chats.cancel(chat.id)
    try await cancelled.value
    thread = chats.thread(of: chat.id)
    expect(thread.newestCall!.status == .rejected && thread.messages.last!.error != nil, "cancel rejects the waiting call and ends the reply: \(thread.messages.last!.error ?? "")")
    provider.steps = [.hang("Thinking about it for a long ")]
    let hanging = Task { try await chats.ask("Take your time.", in: chat.id) }
    try await waitFor("text to stream") { chats.thread(of: chat.id).replyText?.isEmpty == false }
    chats.cancel(chat.id)
    try await hanging.value
    thread = chats.thread(of: chat.id)
    expect(thread.messages.last!.error == "The reply was canceled." && thread.messages.last!.bodyMarkdown.hasPrefix("Thinking"), "cancel mid-reply keeps what streamed and says it was canceled: '\(thread.messages.last!.bodyMarkdown)' \(thread.messages.last!.error ?? "nil")")

    note("== over MCP (the Claude Code path)")
    LumaAppState.shared.objectChatRunsWithoutAsking = true
    provider.steps = [.overMCP("chat_evaluate", ["code": "id"])]
    try await chats.ask("Over MCP?", in: chat.id)
    thread = chats.thread(of: chat.id)
    expect(thread.newestCall!.tool == "chat_evaluate" && thread.newestCall!.status == .succeeded && thread.newestCall!.toolCallID == "t1",
        "MCPServer routes a chat's call through the chat: \(thread.newestCall!.summary ?? thread.newestCall!.error ?? "?")")
    expect(try engine.store.countMissionActions(missionID: chat.id) == 0, "no mission action is recorded for a chat call")

    note("== a chat about an instruction")
    let function = try await runtime.evaluate("(LumaProject sessions items first functionNamed: 'luma_target_score') pointer instruction next next")
    let (instructionChat, _) = try await chats.start(about: function, from: .snippet(snippetID: UUID()), label: "unused", source: nil)
    guard case .instruction(let sessionID, let anchor) = instructionChat.subject else { fail("not an instruction subject") }
    expect(sessionID == session.id && instructionChat.sessionID == session.id, "a LumaInstruction subject is kept as session and anchor (\(anchor.displayString))")
    let instructionAddress = engine.resolveSync(sessionID: session.id, anchor: anchor)!
    expect(chats.isDraft(instructionChat.id) && engine.addressAnnotations[session.id]?[instructionAddress]?.chatIDs ?? [] == []
        && chats.chats(aboutInstructionAt: instructionAddress, in: session.id).isEmpty,
        "a draft about an instruction is not marked")
    let atAddress = try await engine.instruction(at: instructionAddress, in: session.id, runtime: runtime)
    expect(atAddress.className == "LumaInstruction" && atAddress.printString == function.printString,
        "the instruction at an address opens as a LumaInstruction in the given runtime: \(atAddress.printString)")
    do {
        _ = try await engine.instruction(at: instructionAddress, in: UUID(), runtime: runtime)
        expect(false, "an unknown session should throw")
    } catch {
        expect("\(error)".contains("The session is not in this project."), "an unknown session throws the plain reason: \(error)")
    }
    guard case .instruction(let place) = chats.subject(of: instructionChat) else { fail("the subject place is not an instruction") }
    expect(place.address == instructionAddress && place.presence == .attached && place.unavailableReason == nil && place.sessionName == session.processName,
        "the chat's subject place resolves to the address in the attached session")
    let insight = try engine.disassemblyInsight(at: place)
    expect(insight.kind == .disassembly && insight.anchor == anchor, "show subject opens the disassembly at the instruction")
    let disassemblyView = try await runtime.views(of: function).first { $0.viewName == "lumaDisassembly" }
    let reference = disassemblyView.flatMap { $0.text.flatMap(PharoDisassemblyReference.init) }
    expect(reference?.sessionID == session.id && reference?.address == instructionAddress && engine.presence(ofSession: reference!.sessionID) == .attached,
        "a LumaInstruction's Disassembly view names its session and address, and the session's presence is known")
    let listed = chats.listed
    expect(zip(listed, listed.dropFirst()).allSatisfy { chats.lastActivity(of: $0) >= chats.lastActivity(of: $1) } && Set(listed.map(\.id)) == Set(chats.chats.map(\.id)),
        "the listed chats are every chat, newest activity first")
    let toolNames = Set(engine.missionTools.toolSpecs(in: [.chatObjects, .session]).map(\.name))
    expect(toolNames.contains("disassemble") && toolNames.contains("chat_evaluate") && !toolNames.contains("record_finding") && !toolNames.contains("attach_to_process") && !toolNames.contains("pharo_eval"),
        "a session chat is offered chat and session tools, never mission-only ones")
    let plainNames = Set(engine.missionTools.toolSpecs(in: [.chatObjects]).map(\.name))
    expect(plainNames == ["chat_evaluate", "chat_view", "chat_objects"], "a chat without a session gets the three chat tools: \(plainNames.sorted())")
    let missionNames = Set(engine.missionTools.toolSpecs(in: ToolNeed.missionContext).map(\.name))
    expect(missionNames.contains("record_finding") && !missionNames.contains("chat_evaluate"), "missions keep their tools and never see chat tools")
    let sid = session.id.uuidString
    let target = function.printString
    provider.steps = [
        .reply([.text("Its text. "), .tool("chat_evaluate", ["code": "self text"])]),
        .reply([.text("Disassembling. "), .tool("disassemble", ["session_id": sid, "address": "0x\(String(UInt64(try await runtime.evaluate("(LumaProject sessions items first functionNamed: 'luma_target_score') address").printString)!, radix: 16))", "count": 3])]),
        .reply([.text("Patching. "), .tool("write_memory", ["session_id": sid, "address": "0x1000", "bytes_hex": "00"])]),
        .reply([.text("Fine.")]),
    ]
    let instructionAsk = Task { try await chats.ask("What does it do?", in: instructionChat.id) }
    try await waitFor("the instruction chat's first request") {
        provider.requests.contains { $0.systemBlocks.contains { if case .text(let t) = $0.content { return t.contains("It is the instruction at") }; return false } }
    }
    let instructionSystem = provider.requests.compactMap { request -> String? in
        let text = request.systemBlocks.compactMap { block -> String? in
            if case .text(let t) = block.content { return t }
            return nil
        }.joined()
        return text.contains("It is the instruction at") ? text : nil
    }.first!
    expect(engine.addressAnnotations[session.id]?[instructionAddress]?.chatIDs == [instructionChat.id]
        && chats.chats(aboutInstructionAt: instructionAddress, in: session.id).map(\.id) == [instructionChat.id],
        "its first question saves it, and the instruction's annotation then names it")
    expect(instructionSystem.contains("Disassembly around it:") && instructionSystem.contains(String(format: "0x%llx", instructionAddress))
        && instructionSystem.contains("Its function, decompiled:"),
        "an instruction chat's prompt carries the disassembly around it and its decompiled function")
    func instructionCall(_ index: Int) -> ObjectChatToolCall? { chats.thread(of: instructionChat.id).toolCalls.count > index ? chats.thread(of: instructionChat.id).toolCalls[index] : nil }
    try await waitFor("the write to wait") { instructionCall(2)?.status == .proposed }
    let textCallID = instructionCall(0)!.id
    expect(instructionCall(0)!.status == .succeeded && (instructionCall(0)!.summary ?? "").contains("mov"), "self is the instruction: text -> \(instructionCall(0)!.summary ?? instructionCall(0)!.error ?? "?")")
    expect(instructionCall(1)!.status == .succeeded, "a read-only session tool runs at once when the asker is the host: \(instructionCall(1)!.summary ?? instructionCall(1)!.error ?? "?")")
    expect(chats.callsWaitingForMe.contains { $0.id == instructionCall(2)!.id }, "a session tool that changes the target waits for the asker's own Run")
    chats.reject(instructionCall(2)!.id, reason: nil)
    try await instructionAsk.value
    note("   instruction chat target \(target)")

    note("== a session tool routed to another host")
    let peer = CollaborationSession.UserInfo(id: "peer-1", name: "Pat", avatarURL: nil)
    engine.updateSession(id: session.id) { $0.host = peer }
    provider.steps = [.reply([.text("Asking the host. "), .tool("list_modules", ["session_id": sid])]), .reply([.text("Got it.")])]
    let routed = Task { try await chats.ask("Modules?", in: instructionChat.id) }
    try await waitFor("the routed call") { chats.thread(of: instructionChat.id).newestCall?.tool == "list_modules" }
    var routedCall = chats.thread(of: instructionChat.id).newestCall!
    expect(routedCall.status == .proposed && routedCall.executor?.id == "peer-1" && !chats.callsWaitingForMe.contains { $0.id == routedCall.id },
        "a session tool with another host is proposed with that host as executor, and does not wait for me")
    routedCall.status = .running
    chats.apply(ObjectChatOp(.toolCallUpsert(routedCall)))
    try await Task.sleep(for: .milliseconds(200))
    expect(chats.thread(of: instructionChat.id).replyText != nil && routed.isCancelled == false, "the asker keeps waiting while the host runs it")
    routedCall.status = .succeeded
    routedCall.result = #"{"modules":["from the host"]}"#
    routedCall.summary = "1 module"
    chats.apply(ObjectChatOp(.toolCallUpsert(routedCall)))
    try await routed.value
    expect(toolResults(in: provider.requests.last!).first == #"{"modules":["from the host"]}"#, "the host's result reaches the asker's model")
    engine.updateSession(id: session.id) { $0.host = nil }

    note("== a peer's session call waiting for me as host")
    var peerCall = ObjectChatToolCall(
        chatID: instructionChat.id, messageID: UUID(), replyTo: chats.thread(of: instructionChat.id).messages.first!.id, offset: 0, index: 0,
        toolCallID: "toolu_peer", tool: "list_modules", args: ["session_id": .string(sid)],
        askedBy: Author(id: "peer-1", name: "Pat", avatarURL: ""), executor: nil, status: .proposed)
    chats.apply(ObjectChatOp(.toolCallUpsert(peerCall)))
    expect(chats.callsWaitingForMe.contains { $0.id == peerCall.id }, "a peer's proposed session call is listed as waiting for me, the host")
    await chats.run(peerCall.id)
    peerCall = chats.call(peerCall.id)!
    expect(peerCall.status == .succeeded && (peerCall.result ?? "").contains("LabTarget"), "the host runs it only on approval and records the result")

    note("== an echo that changes nothing is not announced")
    let chatMessage = chats.thread(of: chat.id).messages.last!
    let changed = Flag()
    withObservationTracking({ _ = chats.threads }, onChange: { changed.value = true })
    chats.apply(ObjectChatOp(.messageAppend(decodeRow(encodeRow(chatMessage))!)))
    chats.apply(ObjectChatOp(.toolCallUpsert(decodeRow(encodeRow(chats.thread(of: chat.id).newestCall!))!)))
    expect(!changed.value, "an object-chat echo that changes nothing leaves the chat's state untouched")

    note("== approving an external MCP client's action starts no loop here")
    let external = try await engine.enableExternalMCPServer()
    var http = URLRequest(url: external.url)
    http.httpMethod = "POST"
    http.setValue("Bearer \(external.bearerToken)", forHTTPHeaderField: "Authorization")
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.httpBody = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "pharo_add_snippet", "arguments": ["source": "6 * 7"]],
    ])
    let call = Task { try await URLSession.shared.data(for: http) }
    try await waitFor("the MCP action to wait") { (try? engine.store.fetchPendingMissionActions(missionID: external.missionID))?.isEmpty == false }
    let waiting = try engine.store.fetchPendingMissionActions(missionID: external.missionID)[0]
    let turnsBefore = provider.missionTurns
    await engine.approveMissionAction(actionID: waiting.id)
    let (mcpAnswer, _) = try await call.value
    try await Task.sleep(for: .milliseconds(500))
    let externalMission = try engine.store.fetchMission(id: external.missionID)!
    let externalTurns = try engine.store.fetchMissionTurns(missionID: external.missionID)
    expect(String(decoding: mcpAnswer, as: UTF8.self).contains("result") && provider.missionTurns == turnsBefore && externalMission.status == .running
        && externalTurns.isEmpty,
        "the MCP client gets its result and no mission loop starts on the approver's engine (status \(externalMission.status))")
    await engine.disableExternalMCPServer()

    note("== persisted for the reopen check")
    try "\(chat.id.uuidString)\n\(instructionChat.id.uuidString)\n\(textCallID.uuidString)".write(
        to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("chats.txt"), atomically: true, encoding: .utf8)
    engine.removeNode(engine.node(forSessionID: session.id)!)
}

@MainActor
func reopen(engine: Engine, provider: ScriptedProvider, runtime: PharoRuntime, chats: ObjectChats, gstreamer: String) async throws {
    let ids = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("chats.txt"), encoding: .utf8)
        .split(separator: "\n").map { UUID(uuidString: String($0))! }
    let (chatID, instructionChatID, textCallID) = (ids[0], ids[1], ids[2])
    let thread = chats.thread(of: chatID)
    expect(chats.chats.count == 2 && thread.messages.count >= 8 && thread.toolCalls.count >= 10, "the store reopens with the chats, their messages and calls (\(thread.messages.count) messages, \(thread.toolCalls.count) calls)")
    expect(thread.objects.allSatisfy { $0.snapshot != nil } && thread.liveObjectIDs.isEmpty, "objects come back as snapshots, none live")
    func printed(_ title: String) -> String { title.hasPrefix("Chat about ") ? String(title.dropFirst("Chat ".count)) : title }
    let column = try await chats.column(of: chatID)
    let held = try await runtime.evaluate("(LumaChat at: '\(chatID.uuidString)') holds: 'o1'")
    let header = chats.displayTitle(of: chats.chats.first { $0.id == chatID }!)
    expect(column.className == "LumaChat" && column.printString == printed(header) && held.printString == "false",
        "an object chat opens on an empty LumaChat whose print string is its display title: '\(column.printString)'")
    let instructionTitle = chats.displayTitle(of: chats.chats.first { $0.id == instructionChatID }!)
    let typed = try await runtime.evaluate("LumaChat open: '\(instructionChatID.uuidString)'")
    expect(typed.printString == printed(instructionTitle) && instructionTitle.hasPrefix("Chat about LabTarget+0x"),
        "a chat opened again by a plain LumaChat open: prints its display title: '\(typed.printString)'")
    let first = try await runtime.evaluate("OrderedCollection withAll: #(3 1 2)")
    let second = try await runtime.evaluate("OrderedCollection withAll: #(9 8 7 6 5 4 3 2 1 0 11 12 13 14 15 16 17 18)")
    let (one, oneColumn) = try await chats.start(about: first, from: .snippet(snippetID: UUID()), label: "a snippet", source: nil)
    let (two, _) = try await chats.start(about: second, from: .snippet(snippetID: UUID()), label: "a snippet", source: nil)
    let titles = [chats.displayTitle(of: one), chats.displayTitle(of: two)]
    expect(titles[0] != titles[1] && titles.allSatisfy { $0.count <= 60 } && oneColumn.printString == printed(titles[0]),
        "two chats about objects of one class are told apart by a short print string: \(titles), column '\(oneColumn.printString)'")
    let (aboutChat, _) = try await chats.start(about: oneColumn, from: .chat(chatID: one.id, objectID: "o1"), label: "a chat", source: nil)
    let stacked = chats.displayTitle(of: aboutChat)
    expect(stacked == "Chat about the chat on an OrderedCollection(3 1 2)", "a chat about a chat does not stack its titles: '\(stacked)'")
    chats.rename(chatID, to: "Renamed chat")
    try await Task.sleep(for: .milliseconds(300))
    let refreshed = try await runtime.evaluate("SwpBridge current session objectAt: \(column.handle)")
    expect(refreshed.printString == "Renamed chat" && PharoObjectChanges.shared.generation(of: column.handle) > 0,
        "renaming retitles the open column and signals the change; a fresh description reads the new title")
    let binding = thread.toolCalls.first { $0.tool == "chat_evaluate" && $0.status == .succeeded && $0.objectID == "o4" }!
    do {
        try await chats.runAgain(binding.id)
        expect(false, "running a chain over an object subject that is not live should fail")
    } catch {
        expect(error.localizedDescription.contains("o1"), "a chain needing an object not live here says so: \(error.localizedDescription)")
    }
    _ = try await loadGStreamer(from: gstreamer, into: runtime)
    let fresh = try await runtime.evaluate("(ChatCheckCode classNamed: 'DotParser') parse: 'digraph again { a -> b; }'")
    let standIn = try await chats.add(fresh, to: chatID, named: "fresh graph", inPlaceOf: "o1")
    try await chats.runAgain(binding.id)
    let rebuilt = chats.call(binding.id)!
    expect(standIn.standsFor == "o1" && chats.isLive("o3", in: chatID) && chats.isLive("o4", in: chatID) && (rebuilt.summary ?? "").hasSuffix("7"),
        "with a live object in place of o1, run again re-runs the chain of bindings: \(rebuilt.summary ?? "?")")
    _ = try await chats.column(of: instructionChatID)
    expect(chats.isLive("o1", in: instructionChatID), "an instruction subject is rebuilt from its anchor after reopening")
    let reopened = chats.chats.first { $0.id == instructionChatID }!
    guard case .instruction(let place) = chats.subject(of: reopened), case .instruction(let sessionID, let anchor) = reopened.subject else { fail("no instruction place") }
    expect(place.address != nil && place.address == engine.resolveSync(sessionID: sessionID, anchor: anchor)
        && engine.addressAnnotations[sessionID]?[place.address!]?.chatIDs == [instructionChatID],
        "after reopening, the marker and the subject place follow the anchor to its address in this run (\(place.presence))")
    let target = Process()
    target.executableURL = labTarget
    let out = Pipe()
    target.standardOutput = out
    try target.run()
    defer { target.terminate() }
    var pidLine = Data()
    while !pidLine.contains(UInt8(ascii: "\n")) { pidLine += out.fileHandleForReading.availableData }
    let pid = UInt(String(decoding: pidLine, as: UTF8.self).split(separator: "\n")[0])!
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    _ = try await engine.attach(device: device, process: process, session: engine.sessions.first { $0.id == sessionID }!)
    try await waitFor("the re-attached session's modules") {
        engine.presence(ofSession: sessionID) == .attached && engine.node(forSessionID: sessionID)?.modules.isEmpty == false
    }
    let reattached = engine.resolveSync(sessionID: sessionID, anchor: anchor)!
    guard case .instruction(let moved) = chats.subject(of: reopened) else { fail("no instruction place") }
    expect(moved.address == reattached && moved.presence == .attached && engine.addressAnnotations[sessionID]?[reattached]?.chatIDs == [instructionChatID]
        && (reattached == place.address! || engine.addressAnnotations[sessionID]?[place.address!]?.chatIDs == nil),
        "re-attached to a new process, the marker and the subject place move to the instruction's new address (0x\(String(place.address!, radix: 16)) -> 0x\(String(reattached, radix: 16)))")
    engine.removeNode(engine.node(forSessionID: sessionID)!)
    try await chats.runAgain(textCallID)
    let rerun = chats.call(textCallID)!
    expect(chats.isLive(rerun.objectID!, in: instructionChatID) && (rerun.summary ?? "").contains("mov"), "run again rebuilds a result against the rebuilt instruction: \(rerun.summary ?? "?")")
    let opened = try await chats.open(rerun.objectID!, in: instructionChatID)
    expect(!(try await runtime.views(of: opened)).isEmpty, "the rebuilt result opens with views")
    guard case .instruction(let bareSession, let bareAnchor) = chats.chats.first(where: { $0.id == instructionChatID })!.subject else { fail("no anchor") }
    let bare = ObjectChat(title: nil, subject: .instruction(sessionID: bareSession, anchor: bareAnchor), editors: [])
    try engine.store.save(bare)
    chats.load()
    provider.steps = [.reply([.text("Answered without a stored o1.")])]
    try await chats.ask("What is it?", in: bare.id)
    expect(chats.thread(of: bare.id).messages.last?.bodyMarkdown == "Answered without a stored o1.",
        "a stored instruction chat with no object rows answers after a reopen, with o1 rebuilt from its anchor")
}

@MainActor
func solo(engine: Engine, provider: ScriptedProvider, runtime: PharoRuntime, chats: ObjectChats) async throws {
    LumaAppState.shared.objectChatRunsWithoutAsking = true
    let conversation = chats.openConversation()
    expect(conversation.id == ObjectChat.soloConversationID && conversation.subject == .project && chats.conversation?.id == conversation.id,
        "a solo project has its conversation, about the project")
    expect(chats.openConversation().id == conversation.id && chats.chats.count == 1, "opening it again finds the same one")
    try chats.post("A note to myself.", in: conversation.id)
    expect(provider.requests.isEmpty && chats.thread(of: conversation.id).messages.count == 1 && chats.thread(of: conversation.id).messages[0].asksAssistant == false,
        "posting appends a message and asks no one")
    let projectTools = Set(engine.missionTools.toolSpecs(in: [.chatObjects, .project, .session]).map(\.name))
    expect(projectTools.isSuperset(of: ["chat_evaluate", "list_sessions", "list_patterns", "disassemble"]) && !projectTools.contains("record_finding") && !projectTools.contains("attach_to_process") && !projectTools.contains("pharo_eval"),
        "a project chat is offered chat, project and session tools, never mission-only ones")
    provider.steps = [
        .reply([.text("Listing sessions. "), .tool("list_sessions", [:])]),
        .reply([.text("Asking the project. "), .tool("chat_evaluate", ["code": "self sessions items size"])]),
        .reply([.text("There are none.")]),
    ]
    try await chats.ask("What sessions are there?", in: conversation.id)
    let thread = chats.thread(of: conversation.id)
    expect(thread.messages.map(\.role) == [.user, .user, .assistant] && thread.messages[1].asksAssistant && thread.messages[2].replyTo == thread.messages[1].id,
        "asking appends a question the assistant answers")
    expect(thread.toolCalls.count == 2 && thread.toolCalls.allSatisfy { $0.status == .succeeded }, "a project tool and an expression on self run: \(thread.toolCalls.map { $0.summary ?? $0.error ?? "?" })")
    let firstRequest = provider.requests[0]
    expect(firstRequest.messages.count == 1 && firstRequest.messages[0].blocks.count == 2, "the model hears the earlier post and the question as one user turn")
    expect(chats.isLive("o1", in: conversation.id) && thread.toolCalls[1].summary?.hasSuffix("0") == true, "self is LumaProject, rebuilt without being asked")
    expect(chats.unreadCount(in: conversation.id) == 0, "nothing of my own is unread")
    expect(chats.isMine(thread.messages[0]) && chats.isAsker(of: thread.toolCalls[0]) && chats.isExecutor(of: thread.toolCalls[0]), "mine, asked by me and run by me, without a lab")
    let column = try await chats.column(of: conversation.id)
    let before = PharoObjectChanges.shared.generation(of: column.handle)
    let opened = try await chats.open("o2", in: conversation.id)
    let located = try await chats.location(of: opened)
    expect(located?.chatID == conversation.id && located?.objectID == "o2", "a shown object is found as o2 of its chat: \(String(describing: located))")
    let stranger = try await runtime.evaluate("Object new")
    expect(try await chats.location(of: stranger) == nil, "an object no chat holds is not found")
    _ = try await chats.add(stranger, to: conversation.id, named: "stranger")
    try await Task.sleep(for: .milliseconds(200))
    expect(PharoObjectChanges.shared.generation(of: column.handle) > before, "storing an object tells the chat's columns to reload")
    do {
        try await chats.delete(conversation.id)
        expect(false, "the conversation should not be deletable")
    } catch {
        expect(error is ObjectChatError, "the conversation cannot be deleted: \(error.localizedDescription)")
    }
    let projectClass = try await runtime.evaluate("LumaProject")
    let (aboutProject, projectColumn) = try await chats.start(about: projectClass, from: .snippet(snippetID: UUID()), label: "a snippet", source: "LumaProject")
    expect(aboutProject.subject == .project && aboutProject.id != conversation.id && projectColumn.className == "LumaChat", "Chat about this object on LumaProject starts a new project chat")
    expect(try chats.isDraft(aboutProject.id) && !chats.chats.contains { $0.id == aboutProject.id } && chats.chat(withID: aboutProject.id) == aboutProject
        && !(engine.store.fetchObjectChats()).contains { $0.id == aboutProject.id } && !chats.listed.contains { $0.id == aboutProject.id }
        && chats.subject(of: aboutProject) == .project && chats.isLive("o1", in: aboutProject.id),
        "a started chat is a draft: its o1 is usable, its subject known, and it is neither saved nor listed")
    chats.rename(aboutProject.id, to: "Drafted")
    expect(chats.displayTitle(of: chats.chat(withID: aboutProject.id)!) == "Drafted" && chats.canDelete(aboutProject.id) && chats.canRename(aboutProject.id),
        "a draft can be renamed and deleted")
    let (scratch, _) = try await chats.start(about: projectClass, from: .snippet(snippetID: UUID()), label: "a snippet", source: "LumaProject")
    let seven = try await runtime.evaluate("3 + 4")
    _ = try await chats.add(seven, to: scratch.id, named: "seven")
    expect(try chats.thread(of: scratch.id).objects.count == 2 && (engine.store.fetchObjectChatObjects(chatID: scratch.id)).isEmpty,
        "an object added to a draft is held, not saved")
    await chats.discard(scratch.id)
    let inImage = try await runtime.evaluate("LumaChat at: '\(scratch.id.uuidString)' ifPresent: [ :c | true ] ifAbsent: [ false ]")
    expect(!chats.isDraft(scratch.id) && chats.chat(withID: scratch.id) == nil && inImage.printString == "false" && chats.wasDiscarded(scratch.id),
        "discarding a draft leaves nothing, in the image either")
    let field = ObjectField(id: "depth", name: "Depth", schema: .uint(default: 3, min: nil, max: nil), optional: false, enabledByDefault: false)
    let def = CustomInstrumentDef(
        name: "Wire settings", entrypoint: "main.ts",
        settings: [
            .init(id: "ports", name: "Ports", schema: .array(item: .int, default: [.int(80), .int(443)])),
            .init(id: "rules", name: "Rules", schema: .array(item: .object(fields: [field]), default: [.object(["depth": .uint(5)])])),
            .init(id: "nested", name: "Nested", schema: .object(fields: [ObjectField(id: "on", name: "On", schema: .boolean(default: true), optional: true, enabledByDefault: false)])),
        ])
    let wireDef = def.toJSON()
    let wireSettings = wireDef["settings"] as! [[String: Any]]
    let portsDefault = (wireSettings[0]["schema"] as! [String: Any])["default"] as! [Any]
    let rulesDefault = (wireSettings[1]["schema"] as! [String: Any])["default"] as! [[String: Any]]
    let nestedField = ((wireSettings[2]["schema"] as! [String: Any])["fields"] as! [[String: Any]])[0]
    expect(wireDef["features"] == nil && portsDefault as? [Int] == [80, 443] && rulesDefault.first?["depth"] as? Int == 5
        && nestedField["enabled_by_default"] as? Bool == false && nestedField["enabledByDefault"] == nil,
        "an instrument's settings go on the wire as settings, with plain array defaults and one spelling at every depth")
    expect(CustomInstrumentDef.fromJSON(wireDef)?.settings == def.settings, "and come back from the wire as they were")
    let instanceConfig = CustomInstrumentConfig(defID: def.id, settings: ["on": SettingState(enabled: true, value: .boolean(true))])
    let configObject = try JSONSerialization.jsonObject(with: instanceConfig.encode()) as! [String: Any]
    expect(try Set(configObject.keys) == ["def_id", "settings"] && (configObject["settings"] as? [String: Any])?["on"] != nil
        && (try CustomInstrumentConfig.decode(from: instanceConfig.encode())) == instanceConfig,
        "a custom instrument instance's config is {def_id, settings} and round-trips")
    let missingCLI = ClaudeCodeProvider(engine: nil, executablePath: "luma-no-such-cli").unavailableReason()
    let presentCLI = ClaudeCodeProvider(engine: nil, executablePath: "/bin/sh").unavailableReason()
    expect(missingCLI?.contains("not installed") == true && presentCLI == nil, "Claude Code says when its command is missing, without running it: \(missingCLI ?? "nil")")
    engine.setSidebarExpansion(section: .chats, .collapsed)
    let instrument = engine.createCustomInstrument(name: "Starts collapsed")
    expect(engine.sidebarExpansion(forCustomInstrumentDefID: instrument.id) == .collapsed, "a new custom instrument starts collapsed in the sidebar")
    engine.setSidebarExpansion(customInstrumentDefID: instrument.id, .expanded)
    try await waitFor("the first expand to be saved") { engine.sidebarExpansion(forCustomInstrumentDefID: instrument.id) == .expanded }
    try "\(instrument.id.uuidString)".write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("instrument.txt"), atomically: true, encoding: .utf8)
    let started = chats.modelChoice(in: aboutProject.id)
    chats.setModelChoice(ObjectChatModelChoice(providerID: "nowhere", modelID: "m"), in: aboutProject.id)
    let unavailable = await chats.answerUnavailableReason(in: aboutProject.id)
    expect(unavailable == "There is no provider nowhere in this Luma.", "a choice this Luma cannot answer with is said before asking: \(unavailable ?? "nil")")
    chats.setModelChoice(ObjectChatModelChoice(providerID: "scripted", modelID: "scripted-2"), in: aboutProject.id)
    let (another, _) = try await chats.start(about: projectClass, from: .snippet(snippetID: UUID()), label: "a snippet", source: nil)
    let anotherReason = await chats.answerUnavailableReason(in: another.id)
    expect(started.providerID == "scripted" && chats.modelChoice(in: another.id) == ObjectChatModelChoice(providerID: "scripted", modelID: "scripted-2")
        && anotherReason == nil,
        "a new chat starts with my most recent choice in any chat, and it can answer here")
    await chats.discard(another.id)
    try chats.post("About the project.", in: aboutProject.id)
    await chats.discard(aboutProject.id)
    expect(try !chats.isDraft(aboutProject.id) && chats.chats.contains { $0.id == aboutProject.id && $0.title == "Drafted" }
        && (engine.store.fetchObjectChats()).contains { $0.id == aboutProject.id } && chats.thread(of: aboutProject.id).messages.count == 1,
        "the first post saves the draft as it stands; a late discard does nothing")
    provider.steps = [.reply([.text("Fine.")])]
    try await chats.ask("Which model?", in: aboutProject.id)
    let answered = chats.thread(of: aboutProject.id).messages.last!
    expect(provider.requests.last!.modelID == "scripted-2" && answered.modelID == "scripted-2" && answered.providerID == "scripted",
        "a reply uses my choice for the chat and records it on the answer")
    let projectViews = try await runtime.views(of: projectClass).map(\.title)
    expect(Set(projectViews).isSuperset(of: ["Sessions", "Notebook", "Events"]), "LumaProject shows Sessions, Notebook and Events: \(projectViews)")
}

@MainActor
func soloReopen(engine: Engine, chats: ObjectChats, wireFile: String) async throws {
    let solo = ObjectChat.soloConversationID
    expect(chats.thread(of: solo).messages.count == 3, "the solo conversation survives a restart")
    expect(engine.sidebarExpansion(of: .chats) == .collapsed, "the Chats section stays collapsed across a reopen")
    let expandedID = UUID(uuidString: try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("instrument.txt"), encoding: .utf8))!
    expect(engine.sidebarExpansion(forCustomInstrumentDefID: expandedID) == .expanded, "and the first expand of a new custom instrument is remembered across a reopen")
    chats.markRead(solo)
    engine.collaboration.keepProjectLab("lab-check")
    chats.adopt([])
    let labConversation = ObjectChat.conversationID(ofLab: "lab-check")
    expect(chats.conversationID == labConversation && chats.conversation != nil && !chats.chats.contains { $0.id == solo },
        "when the project becomes a lab, its conversation becomes the lab's (\(labConversation))")
    expect(chats.thread(of: labConversation).messages.count == 3 && chats.readThrough[labConversation] != nil, "its messages and read marker come with it")
    let queued = try engine.store.fetchOutboxOps(ObjectChatOp.self).filter { $0.chatID == labConversation }
    expect(queued.contains { if case .chatUpsert(let c) = $0.change { c.id == labConversation } else { false } } && queued.filter { if case .messageAppend = $0.change { true } else { false } }.count == 3,
        "and is uploaded to the lab: \(queued.map(\.kind))")
    expect(!queued.contains { if case .objectUpsert(let object) = $0.change { object.objectID == "o1" } else { false } },
        "the project's o1 is not uploaded: every member rebuilds it")
    let wire = try String(contentsOfFile: wireFile, encoding: .utf8)
    expect(wire.contains(labConversation.uuidString.lowercased()) || wire.contains(labConversation.uuidString), "the wire file's conversation id example matches the client's derivation")
    for op in queued {
        let decoded = ObjectChatOp.fromJSON(try JSONSerialization.jsonObject(with: try JSONSerialization.data(withJSONObject: op.toJSON())) as! [String: Any])
        let missing = keyPaths(of: op.toJSON()).filter { !wire.contains("\"\($0)\"") }
        expect(decoded?.kind == op.kind && missing.isEmpty, "\(op.kind) round-trips with every key in the wire file\(missing.isEmpty ? "" : " (missing \(missing))")")
    }
    _ = try engine.store.fetchOutboxOps(ObjectChatOp.self).map { try engine.store.removeOutboxOp(opID: $0.opID) }
}

@MainActor
func teardown(engine: Engine, provider: ScriptedProvider, runtime: PharoRuntime, chats: ObjectChats, pid: UInt) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    try await waitFor("modules") { engine.node(forSessionID: session.id)?.modules.isEmpty == false }
    func instruction(_ hops: Int) async throws -> PharoObject {
        try await runtime.evaluate("(LumaProject sessions items first functionNamed: 'luma_target_score') pointer instruction"
            + String(repeating: " next", count: hops))
    }
    func located(_ chatID: UUID) async throws -> Bool {
        try await runtime.evaluate("LumaChat at: '\(chatID.uuidString)' ifPresent: [ :chat | true ] ifAbsent: [ false ]").printString == "true"
    }
    func rows(_ chatID: UUID) throws -> Int {
        try engine.store.fetchObjectChatMessages(chatID: chatID).count + engine.store.fetchObjectChatToolCalls(chatID: chatID).count
            + engine.store.fetchObjectChatObjects(chatID: chatID).count + (engine.store.fetchObjectChats().contains { $0.id == chatID } ? 1 : 0)
    }
    func queued(_ chatIDs: [UUID]) throws -> Int {
        try engine.store.fetchOutboxOps(ObjectChatOp.self).filter { chatIDs.contains($0.chatID) }.count
    }

    let (streaming, _) = try await chats.start(about: try await instruction(1), from: .snippet(snippetID: UUID()), label: "streaming", source: nil)
    let (waiting, _) = try await chats.start(about: try await instruction(2), from: .snippet(snippetID: UUID()), label: "waiting", source: nil)
    let (running, _) = try await chats.start(about: try await instruction(3), from: .snippet(snippetID: UUID()), label: "running", source: nil)
    var ended: Set<String> = []
    provider.steps = [.hang("Thinking about it for a long ")]
    let streamingAsk = Task { _ = try? await chats.ask("Take your time.", in: streaming.id); ended.insert("streaming") }
    try await waitFor("text to stream") { chats.thread(of: streaming.id).replyText?.isEmpty == false }
    provider.steps = [.reply([.text("Let me look. "), .tool("chat_evaluate", ["code": "3 + 4"])])]
    let waitingAsk = Task { _ = try? await chats.ask("Add them.", in: waiting.id); ended.insert("waiting") }
    try await waitFor("a call waiting for approval") { chats.thread(of: waiting.id).newestCall?.status == .proposed }
    LumaAppState.shared.objectChatRunsWithoutAsking = true
    provider.steps = [.reply([.text("Forever. "), .tool("chat_evaluate", ["code": "[ true ] whileTrue"])])]
    let runningAsk = Task { _ = try? await chats.ask("Spin.", in: running.id); ended.insert("running") }
    try await waitFor("a call running in the image") { chats.thread(of: running.id).newestCall?.status == .running }
    try await Task.sleep(for: .milliseconds(300))
    let sessionChats = [streaming.id, waiting.id, running.id]
    let (draft, _) = try await chats.start(about: try await instruction(4), from: .snippet(snippetID: UUID()), label: "draft", source: nil)
    let draftBefore = chats.isDraft(draft.id)
    let locatedBefore = try await located(running.id)
    let removedAt = Date()
    engine.deleteSession(id: session.id)
    try await waitFor("the three replies to end", seconds: 8) { ended.count == 3 }
    let took = Date().timeIntervalSince(removedAt)
    try await Task.sleep(for: .milliseconds(500))
    var locatedAfter: [Bool] = []
    for chatID in sessionChats {
        locatedAfter.append(try await located(chatID))
    }
    let left = try sessionChats.map(rows)
    let queuedAfter = try queued(sessionChats)
    expect(locatedBefore && took < 5 && left.allSatisfy { $0 == 0 } && queuedAfter == 0 && !locatedAfter.contains(true)
        && engine.labProblems.isEmpty && chats.problems.isEmpty,
        "removing a session ends its chats' streaming, waiting and running replies in \(String(format: "%.1f", took)) s, leaves no rows \(left), nothing queued, and the image no longer locates them \(locatedAfter)")
    _ = (streamingAsk, waitingAsk, runningAsk)
    try await waitFor("the session's draft to be discarded") { chats.wasDiscarded(draft.id) }
    expect(sessionChats.allSatisfy(chats.wasDeletedHere) && draftBefore,
        "a session deleted here marks each of its chats deleted here \(sessionChats.map(chats.wasDeletedHere)), and its draft reports discarded")

    let device2 = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process2 = try await device2.enumerateProcesses(pids: [pid], scope: .full).first!
    let session2 = engine.prepareAttachSession(device: device2, process: process2)
    _ = try await engine.attach(device: device2, process: process2, session: session2)
    try await waitFor("modules again") { engine.node(forSessionID: session2.id)?.modules.isEmpty == false }
    let (deleted, _) = try await chats.start(about: try await instruction(1), from: .snippet(snippetID: UUID()), label: "deleted", source: nil)
    provider.steps = [
        .reply([.text("Two quick ones. "), .tool("chat_evaluate", ["code": "1"]), .tool("chat_evaluate", ["code": "2"])]),
        .reply([.text("And one forever. "), .tool("chat_evaluate", ["code": "[ true ] whileTrue"])]),
    ]
    var deletedEnded = false
    _ = Task { _ = try? await chats.ask("Go.", in: deleted.id); deletedEnded = true }
    try await waitFor("two finished calls and one running") {
        let calls = chats.thread(of: deleted.id).toolCalls
        return calls.filter { $0.status == .succeeded }.count == 2 && calls.contains { $0.status == .running }
    }
    try await Task.sleep(for: .milliseconds(300))
    let deletedAt = Date()
    try await chats.delete(deleted.id)
    let deletedLocated = try await located(deleted.id)
    try await waitFor("the reply to end", seconds: 8) { deletedEnded }
    let deleteTook = Date().timeIntervalSince(deletedAt)
    let stillUsable = try await runtime.evaluate("3 + 4").printString
    let deletedRows = try rows(deleted.id)
    let deletedQueued = try queued([deleted.id])
    expect(!deletedLocated && deleteTook < 12 && deletedRows == 0 && deletedQueued == 0 && stillUsable == "7",
        "deleting a chat with two finished calls and one running: when delete returns (\(String(format: "%.1f", deleteTook)) s, the running expression's own deadline) the image no longer locates it, its reply has ended, and nothing of it is left")

    let (removedInLab, _) = try await chats.start(about: try await instruction(2), from: .snippet(snippetID: UUID()), label: "removed in the lab", source: nil)
    provider.steps = [.reply([.text("Noted.")])]
    _ = try await chats.ask("Remember this.", in: removedInLab.id)
    let keptBefore = chats.chats.contains { $0.id == removedInLab.id }
    engine.collaboration.onSessionRemoved?(session2.id)
    try await waitFor("the lab's removal to take the session's chat") { !chats.chats.contains { $0.id == removedInLab.id } }
    expect(keptBefore && !chats.wasDeletedHere(removedInLab.id) && !engine.sessions.contains { $0.id == session2.id },
        "a session the lab removes takes its chats without marking them deleted here")
    LumaAppState.shared.objectChatRunsWithoutAsking = false
}

@MainActor
func deleteOps(engine: Engine, provider: ScriptedProvider, runtime: PharoRuntime, chats: ObjectChats) async throws {
    engine.collaboration.keepProjectLab("lab-delete-ops")
    func removalQueued(_ chatID: UUID) throws -> Bool {
        try engine.store.fetchOutboxOps(ObjectChatOp.self).contains { op in
            if case .chatRemove(chatID) = op.change { true } else { false }
        }
    }
    func chatWithMessage(_ label: String) async throws -> UUID {
        let (chat, _) = try await chats.start(about: try await runtime.evaluate("OrderedCollection new"), from: .snippet(snippetID: UUID()), label: label, source: nil)
        try chats.post("\(label): a message", in: chat.id)
        return chat.id
    }
    LumaAppState.shared.objectChatRunsWithoutAsking = true

    let plain = try await chatWithMessage("no call")
    try await chats.delete(plain)
    expect(try removalQueued(plain), "deleting a chat with a message and no call queues its removal for the lab")

    let finished = try await chatWithMessage("finished calls")
    provider.steps = [.reply([.text("Two. "), .tool("chat_evaluate", ["code": "1"]), .tool("chat_evaluate", ["code": "2"])]), .reply([.text("Done.")])]
    try await chats.ask("Go.", in: finished)
    try await chats.delete(finished)
    expect(try removalQueued(finished), "deleting a chat with finished calls queues its removal for the lab")

    let running = try await chatWithMessage("running call")
    provider.steps = [.reply([.text("Forever. "), .tool("chat_evaluate", ["code": "[ true ] whileTrue"])])]
    _ = Task { try? await chats.ask("Spin.", in: running) }
    try await waitFor("a call running in the image") { chats.thread(of: running).newestCall?.status == .running }
    let deleting = Task { try await chats.delete(running) }
    let askedAt = Date()
    try await waitFor("the removal to be queued", seconds: 2) { try removalQueued(running) }
    let queuedAfter = Date().timeIntervalSince(askedAt)
    try await deleting.value
    expect(queuedAfter < 1, "deleting a chat with a running call queues its removal at once (\(String(format: "%.2f", queuedAfter)) s), not after the expression ends")
    LumaAppState.shared.objectChatRunsWithoutAsking = false
}
