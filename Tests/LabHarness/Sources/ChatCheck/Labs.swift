import Foundation
@testable import LumaCore
import SwiftyPharo
import Observation

@MainActor
func labs(engine: Engine, chats: ObjectChats, second: URL, wireFile: String) async throws {
    let wire = try String(contentsOfFile: wireFile, encoding: .utf8)
    let ids = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("chats.txt"), encoding: .utf8)
        .split(separator: "\n").map { UUID(uuidString: String($0))! }
    let chat = chats.chats.first { $0.id == ids[1] }!
    let thread = chats.thread(of: chat.id)
    let ops: [ObjectChatOp] = [
        ObjectChatOp(.chatUpsert(chat)),
        ObjectChatOp(.messageAppend(thread.messages[0])),
        ObjectChatOp(.messageEdit(chatID: chat.id, messageID: thread.messages[0].id, bodyMarkdown: "edited")),
        ObjectChatOp(.toolCallUpsert(thread.toolCalls[0])),
        ObjectChatOp(.objectUpsert(thread.objects[0])),
        ObjectChatOp(.messageRemove(chatID: chat.id, messageID: thread.messages[0].id)),
        ObjectChatOp(.chatRemove(chatID: chat.id)),
    ]
    for op in ops {
        let data = try JSONSerialization.data(withJSONObject: op.toJSON(), options: [.sortedKeys])
        let decoded = ObjectChatOp.fromJSON(try JSONSerialization.jsonObject(with: data) as! [String: Any])
        let keys = keyPaths(of: op.toJSON())
        let missing = keys.filter { !wire.contains("\"\($0)\"") }
        expect(decoded?.kind == op.kind && decoded?.opID == op.opID && decoded?.chatID == op.chatID && missing.isEmpty && wire.contains(op.kind),
            "\(op.kind) round-trips and every key is in the wire file\(missing.isEmpty ? "" : " (missing \(missing))")")
    }
    let threadJSON = encodeRow(chat).merging([
        "messages": thread.messages.map { encodeRow($0) },
        "tool_calls": thread.toolCalls.map { encodeRow($0) },
        "objects": thread.objects.map { encodeRow($0) },
    ]) { $1 }
    let labThread = ObjectChatThread.fromWireJSON(threadJSON)!
    expect(labThread.messages.count == thread.messages.count && labThread.toolCalls.count == thread.toolCalls.count && labThread.objects.count == thread.objects.count,
        "the join reply's thread type decodes (\(labThread.messages.count) messages, \(labThread.toolCalls.count) calls, \(labThread.objects.count) objects)")
    if case .instruction(_, let anchor) = labThread.chat.subject { note("   subject anchor on the wire: \(String(decoding: try JSONEncoder().encode(anchor), as: UTF8.self))") }

    let peer = try await makeEngine(at: second)
    try peer.store.save(try engine.store.fetchSession(id: chat.sessionID!)!)
    for op in ops.prefix(5) { peer.objectChats.apply(op) }
    let applied = peer.objectChats.thread(of: chat.id)
    expect(peer.objectChats.chats.count == 1 && applied.messages.first?.bodyMarkdown == "edited" && applied.toolCalls.count == 1 && applied.objects.count == 1,
        "remote ops apply to a second store")
    let reopenedPeer = try peer.store.fetchObjectChatMessages(chatID: chat.id)
    expect(reopenedPeer.first?.bodyMarkdown == "edited", "and are persisted there")
    peer.objectChats.apply(ops[5])
    expect(peer.objectChats.thread(of: chat.id).messages.isEmpty, "message remove applies")
    peer.objectChats.apply(ops[6])
    try await waitFor("the chat removal") { peer.objectChats.chats.isEmpty }
    expect(try peer.store.fetchObjectChats().isEmpty, "chat remove applies and cascades in the store")

    peer.collaboration.keepProjectLab("lab-check")
    let mine = ObjectChat(title: "mine, never in the lab", subject: .project, editors: [])
    let removedByPeer = ObjectChat(title: "the lab once held it", subject: .project, editors: [])
    peer.objectChats.apply(ObjectChatOp(.chatUpsert(mine)))
    peer.objectChats.apply(ObjectChatOp(.chatUpsert(removedByPeer)))
    let theirMessage = ObjectChatMessage(chatID: chat.id, index: 0, role: .user, author: Author(id: "peer-1", name: "Pat", avatarURL: ""), bodyMarkdown: "theirs")
    try peer.store.markKnownToLab([LabSubject(.objectChat, removedByPeer.id)])
    peer.objectChats.adopt([labThread])
    try await waitFor("the known chat to go") { !peer.objectChats.chats.contains { $0.id == removedByPeer.id } }
    expect(peer.objectChats.chats.contains { $0.id == mine.id }, "a chat the lab never knew is kept")
    let queued = try peer.store.fetchOutboxOps(ObjectChatOp.self)
    expect(queued.contains { if case .chatUpsert(let uploaded) = $0.change { return uploaded.id == mine.id } else { return false } },
        "and uploaded on join")
    expect(!peer.objectChats.chats.contains { $0.id == removedByPeer.id }, "a chat the lab knew and lost is dropped")
    expect(peer.objectChats.thread(of: chat.id).messages.count == labThread.messages.count, "the lab's thread is adopted whole")
    _ = theirMessage
    expect(!queued.contains { if case .messageAppend(let message) = $0.change { return message.chatID == chat.id } else { return false } },
        "nothing of a thread the lab holds is re-sent")
}

func keyPaths(of value: Any, prefix: String = "") -> [String] {
    guard let dictionary = value as? [String: Any] else {
        if let array = value as? [Any] { return array.flatMap { keyPaths(of: $0, prefix: prefix) } }
        return []
    }
    return dictionary.flatMap { key, nested -> [String] in
        let skipNested = ["snapshot", "args", "views"].contains(key)
        return [key] + (skipNested ? [] : keyPaths(of: nested))
    }
}

@MainActor
func becomeMember(_ member: String, at projectDirectory: URL) async throws {
    try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    let store = try ProjectStore(path: projectDirectory.appendingPathComponent("db.sqlite").path)
    var state = try store.fetchCollaborationState()
    state.labID = "lab-check"
    try store.save(state)
    try store.save(LabMembership(labID: "lab-check", user: CollaborationSession.UserInfo(id: member, name: member.capitalized, avatarURL: nil), role: .member))
}

@MainActor
func members(engine alice: Engine, provider: ScriptedProvider, chats: ObjectChats, second: URL) async throws {
    try await becomeMember("bob", at: second)
    let bob = try await makeEngine(at: second)
    bob.llmRegistry.register(provider)
    let aliceAuthor = Author(id: "alice", name: "Alice", avatarURL: "")
    let bobAuthor = Author(id: "bob", name: "Bob", avatarURL: "")
    let conversationID = ObjectChat.conversationID(ofLab: "lab-check")
    expect(chats.conversationID == conversationID && bob.objectChats.conversationID == conversationID, "both members derive the same conversation id")
    var serverIndex = 0
    let aliceHeld = chats.thread(of: conversationID)
    var labMessages: [ObjectChatMessage] = []
    let upload = [ObjectChatOp(.chatUpsert(chats.conversation!))] + aliceHeld.messages.map { ObjectChatOp(.messageAppend($0)) }
    for case .messageAppend(let message) in relay(upload, from: aliceAuthor, to: [alice, bob], index: &serverIndex).map(\.change) { labMessages.append(message) }
    expect(bob.objectChats.thread(of: conversationID).messages.count == 3, "a member joining later receives the conversation")
    expect(bob.objectChats.thread(of: conversationID).objects.map(\.objectID) == ["o1"], "and has its o1 without anyone uploading it")
    let alicesFirst = bob.objectChats.thread(of: conversationID).messages[0]
    expect(!bob.objectChats.canDelete(conversationID) && !bob.objectChats.canRename(conversationID)
        && !bob.objectChats.canEdit(alicesFirst) && !bob.objectChats.canRemove(alicesFirst) && chats.canEdit(alicesFirst),
        "rights: nobody deletes or renames the conversation; only its author edits a message, and a member who is not an owner cannot remove another's")
    expect(bob.objectChats.unreadCount(in: conversationID) == 3 && chats.unreadCount(in: conversationID) == 0, "the joiner has three unread; the author none")
    let seven = try await bob.pharo.started().evaluate("3 + 4")
    let (early, _) = try await bob.objectChats.start(about: seven, from: .snippet(snippetID: UUID()), label: "a snippet", source: "3 + 4")
    try bob.objectChats.post("About seven.", in: early.id)
    let earlyOps = try bob.store.fetchOutboxOps(ObjectChatOp.self).filter { $0.chatID == early.id && $0.kind != "object_chat_object_upsert" }
    _ = relay(earlyOps, from: bobAuthor, to: [alice], index: &serverIndex)
    provider.steps = [.reply([.text("Seven, as far as I can tell.")])]
    try await alice.objectChats.ask("What is it?", in: early.id)
    expect(alice.objectChats.thread(of: early.id).objects.isEmpty && alice.objectChats.thread(of: early.id).messages.last?.bodyMarkdown == "Seven, as far as I can tell.",
        "a member who has the chat and its first message but not its o1 yet can ask, from the subject the chat row carries")
    for op in try bob.store.fetchOutboxOps(ObjectChatOp.self) where op.chatID == early.id { _ = try bob.store.removeOutboxOp(opID: op.opID) }
    for op in try alice.store.fetchOutboxOps(ObjectChatOp.self) where op.chatID == early.id { _ = try alice.store.removeOutboxOp(opID: op.opID) }
    let projectClass = try await bob.pharo.started().evaluate("LumaProject")
    let (bobsDraft, _) = try await bob.objectChats.start(about: projectClass, from: .snippet(snippetID: UUID()), label: "a snippet", source: nil)
    expect(try !(bob.store.fetchOutboxOps(ObjectChatOp.self)).contains { $0.chatID == bobsDraft.id } && alice.objectChats.chat(withID: bobsDraft.id) == nil,
        "a draft reaches neither the outbox nor the other member")
    try bob.objectChats.post("A chat about the project.", in: bobsDraft.id)
    let draftOps = try bob.store.fetchOutboxOps(ObjectChatOp.self).filter { $0.chatID == bobsDraft.id }
    expect(draftOps.map(\.kind) == ["object_chat_upsert", "object_chat_message_append"], "its first post sends the chat's upsert and then the message: \(draftOps.map(\.kind))")
    let sentChat = draftOps[0].toJSON()["chat"] as! [String: Any]
    expect(sentChat["provider_id"] == nil && sentChat["model_id"] == nil, "a chat's upsert carries no provider or model: \(sentChat.keys.sorted())")
    _ = relay(draftOps, from: bobAuthor, to: [alice, bob], index: &serverIndex)
    expect(alice.objectChats.chats.contains { $0.id == bobsDraft.id } && alice.objectChats.thread(of: bobsDraft.id).messages.count == 1,
        "and the other member then has the chat and its message")
    var arrivals: [String] = []
    chats.onMessageArrived = { chat, message in arrivals.append("\(chat.id == conversationID):\(message.bodyMarkdown)") }
    try bob.objectChats.post("Hi Alice, look at this.", in: conversationID)
    let bobPosts = try bob.store.fetchOutboxOps(ObjectChatOp.self)
    _ = relay(bobPosts, from: bobAuthor, to: [alice, bob], index: &serverIndex)
    expect(chats.unreadCount(in: conversationID) == 1 && arrivals == ["true:Hi Alice, look at this."], "a peer's post is unread and announced for a notification")
    expect(!chats.isMine(chats.thread(of: conversationID).messages.last!) && bob.objectChats.isMine(bob.objectChats.thread(of: conversationID).messages.last!), "whose message it is is answered on both sides")
    chats.markRead(conversationID)
    expect(chats.unreadCount(in: conversationID) == 0, "reading clears the count")
    provider.steps = [.reply([.text("Checking. "), .tool("list_sessions", [:])]), .reply([.text("No sessions yet, Bob.")])]
    try await bob.objectChats.ask("Assistant, any sessions?", in: conversationID)
    let bobAsk = try bob.store.fetchOutboxOps(ObjectChatOp.self).filter { op in !bobPosts.contains { $0.opID == op.opID } }
    _ = relay(bobAsk, from: bobAuthor, to: [alice, bob], index: &serverIndex)
    let aliceView = chats.thread(of: conversationID)
    expect(aliceView.messages.suffix(2).map(\.role) == [.user, .assistant] && aliceView.messages.last!.bodyMarkdown.contains("No sessions yet") && aliceView.toolCalls.contains { $0.tool == "list_sessions" && $0.askedBy == bobAuthor },
        "a member's question and the assistant's answer with its call reach the other member")
    expect(provider.requests.last!.messages.first?.blocks.first.map { block -> Bool in if case .text(let t) = block.content { return t.hasPrefix("Alice: ") } else { return false } } == true,
        "the asker's model hears who said what")
    expect(chats.unreadCount(in: conversationID) == 2 && arrivals.count == 3, "the question and its answer are unread for Alice")

    let all = chats.thread(of: conversationID).messages
    let rolled = all.prefix(2)
    let held = Array(all.dropFirst(2)).filter { $0.id != all[3].id }
    let labThread = ObjectChatThread(chat: chats.conversation!, messages: held, toolCalls: chats.thread(of: conversationID).toolCalls, objects: chats.thread(of: conversationID).objects, historyFrom: rolled.last!.index + 1)
    try alice.store.markKnownToLab(all.map { LabSubject(.objectChatMessage, $0.id) } + [LabSubject(.objectChat, conversationID)])
    chats.adopt([labThread])
    let kept = chats.thread(of: conversationID).messages.map(\.id)
    expect(rolled.allSatisfy { kept.contains($0.id) }, "messages that rolled out of the lab's window stay in the project")
    expect(!kept.contains(all[3].id), "a message the lab knew and lost inside its window is dropped")
    let resent = try alice.store.fetchOutboxOps(ObjectChatOp.self)
    expect(!resent.contains { $0.chatID == conversationID } && resent.contains { if case .chatUpsert(let chat) = $0.change { chat.subject == .project } else { false } },
        "adopting a thread the lab holds re-sends nothing of it, so a refusal cannot loop; a chat the lab never knew is uploaded (\(resent.map(\.kind)))")
}

@MainActor
func relay(_ ops: [ObjectChatOp], from sender: Author, to engines: [Engine], index: inout Int) -> [ObjectChatOp] {
    ops.map { op in
        var change = op.change
        switch change {
        case .messageAppend(var message):
            message.author = sender
            message.index = index
            index += 1
            change = .messageAppend(message)
        case .toolCallUpsert(var call):
            call.askedBy = sender
            change = .toolCallUpsert(call)
        case .objectUpsert(var object):
            object.addedBy = sender
            change = .objectUpsert(object)
        case .chatUpsert(var chat):
            if !chat.editors.contains(sender) { chat.editors.append(sender) }
            change = .chatUpsert(chat)
        default:
            break
        }
        let stamped = ObjectChatOp(opID: op.opID, change)
        let json = try! JSONSerialization.data(withJSONObject: stamped.toJSON())
        let wired = ObjectChatOp.fromJSON(try! JSONSerialization.jsonObject(with: json) as! [String: Any])!
        for engine in engines { engine.objectChats.apply(wired) }
        return wired
    }
}

@MainActor
func merge(engine: Engine, chats: ObjectChats) async throws {
    let solo = chats.openConversation()
    try chats.post("solo one", in: solo.id)
    try chats.post("solo two", in: solo.id)
    engine.collaboration.keepProjectLab("lab-merge")
    let labConversation = ObjectChat.conversationID(ofLab: "lab-merge")
    var labCopy = solo
    labCopy.id = labConversation
    let peer = Author(id: "peer-1", name: "Pat", avatarURL: "")
    labCopy.editors = [peer]
    chats.apply(ObjectChatOp(.chatUpsert(labCopy)))
    var peerSubject = chats.thread(of: solo.id).objects[0]
    peerSubject.chatID = labConversation
    peerSubject.addedBy = peer
    chats.apply(ObjectChatOp(.objectUpsert(peerSubject)))
    chats.apply(ObjectChatOp(.messageAppend(ObjectChatMessage(chatID: labConversation, index: 0, role: .user, author: peer, bodyMarkdown: "the lab's own"))))
    let opened = chats.openConversation()
    let projectChats = chats.chats.filter { $0.subject == .project }
    let merged = try engine.store.fetchObjectChatMessages(chatID: labConversation).map(\.bodyMarkdown)
    expect(opened.id == labConversation && projectChats.count == 1 && Set(merged) == ["solo one", "solo two", "the lab's own"],
        "re-keying into a lab conversation that already exists merges, leaving one conversation: \(merged)")
    expect(try engine.store.fetchObjectChats().filter { $0.id == ObjectChat.soloConversationID }.isEmpty && chats.thread(of: labConversation).objects.count == 1,
        "the solo chat is gone from the store and o1 did not collide")

    let doomed = ObjectChat(title: "doomed", subject: .project, editors: [peer])
    chats.apply(ObjectChatOp(.chatUpsert(doomed)))
    try chats.post("typed as it went", in: doomed.id)
    chats.apply(ObjectChatOp(.chatRemove(chatID: doomed.id)))
    try await waitFor("the removal") { chats.removedInLab.contains(doomed.id) || !chats.chats.contains { $0.id == doomed.id } }
    let kept = chats.thread(of: doomed.id).messages.first { $0.bodyMarkdown == "typed as it went" }
    expect(chats.removedInLab.contains(doomed.id) && kept.map { chats.unsent[$0.id] != nil } == true,
        "a chat removed in the lab while it holds my unsent post is kept, the post unsent with a reason: \(kept.flatMap { chats.unsent[$0.id] } ?? "nil")")
    do {
        try chats.post("into nothing", in: UUID())
        expect(false, "posting into a chat that is gone should throw")
    } catch {
        expect(error.localizedDescription.contains("deleted in the lab"), "posting into a chat that is gone throws, so the draft stays: \(error.localizedDescription)")
    }
    let refusedMessage = chats.thread(of: labConversation).messages.first { $0.bodyMarkdown == "solo one" }!
    chats.refused(refusedMessage, because: "object_chat_message_append: unknown chat")
    expect(chats.unsent[refusedMessage.id] == "object_chat_message_append: unknown chat", "a refused post is kept, unsent, with the lab's reason")
    let problem = chats.problems.last
    expect(problem?.kind == .refusedByLab(opKind: "object_chat_message_append") && problem?.chatID == labConversation && problem?.messageID == refusedMessage.id,
        "the refusal is a typed problem naming the op, chat and message: \(String(describing: problem))")
    chats.dismiss(problem!.id)
    expect(chats.problems.isEmpty, "and can be dismissed")
    chats.resend(refusedMessage.id, in: labConversation)
    expect(chats.unsent[refusedMessage.id] == nil, "and resending clears it")
    let queuedBefore = try engine.store.fetchOutboxOps(ObjectChatOp.self).count
    chats.resend(kept!.id, in: doomed.id)
    let queuedAfter = try engine.store.fetchOutboxOps(ObjectChatOp.self).count
    expect(chats.unsent[kept!.id] == ObjectChatError.gone.localizedDescription && queuedAfter == queuedBefore,
        "resending into a chat removed in the lab sends nothing and says why: \(chats.unsent[kept!.id] ?? "nil")")
    let queuedBeforeRename = try engine.store.fetchOutboxOps(ObjectChatOp.self).count
    chats.rename(doomed.id, to: "too late")
    let queuedAfterRename = try engine.store.fetchOutboxOps(ObjectChatOp.self).count
    expect(!chats.canRename(doomed.id) && queuedAfterRename == queuedBeforeRename && chats.chats.first { $0.id == doomed.id }?.title == "doomed",
        "a chat the lab removed is not renamed and no upsert is sent for it")
    try await chats.delete(doomed.id)
    expect(!chats.chats.contains { $0.id == doomed.id }, "a chat kept only for its unsent posts can be let go")
}

@MainActor
func missions(engine alice: Engine, provider: ScriptedProvider, second: URL) async throws {
    try await becomeMember("bob", at: second)
    let bob = try await makeEngine(at: second)
    let bobProvider = ScriptedProvider()
    bob.llmRegistry.register(bobProvider)
    let aliceAuthor = Author(id: "alice", name: "Alice", avatarURL: "")
    let bobAuthor = Author(id: "bob", name: "Bob", avatarURL: "")
    func sync() {
        relayMissions(from: alice, as: aliceAuthor, to: [alice, bob])
        relayMissions(from: bob, as: bobAuthor, to: [alice, bob])
    }

    provider.missionSteps = [[.tool("create_notebook_entry", ["title": "From the mission", "body": "b"])]]
    let mission = alice.startMission(goal: "Write it down", providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 0)!
    try await waitFor("alice's loop to propose an action") { (try alice.store.fetchMission(id: mission.id))?.status == .awaitingApproval }
    sync()
    try await Task.sleep(for: .milliseconds(300))
    let proposed = try bob.store.fetchMissionActions(missionID: mission.id).first!
    expect(proposed.executor?.id == "alice" && alice.canApprove(proposed) && !bob.canApprove(proposed) && !bob.isExecutor(of: proposed),
        "an action the model asks for in alice's mission is executed by alice; only she can approve it")
    expect(try bob.hold(on: proposed) == .executorOffline && bob.isWaitingForStarter(try bob.store.fetchMission(id: mission.id)!),
        "while alice is away bob sees it wait for her, and the mission wait for its starter")
    await bob.approveMissionAction(actionID: proposed.id)
    try await Task.sleep(for: .milliseconds(300))
    expect(try bob.store.fetchMissionAction(id: proposed.id)?.status == .pending && (try bob.store.fetchOutboxOps(MissionOp.self)).isEmpty
        && bobProvider.missionTurns == 0, "bob approving does nothing: nothing runs, nothing is sent, his model is not asked")

    bob.appendMissionUserMessage(missionID: mission.id, text: "Bob steers.")
    expect(try bobProvider.missionTurns == 0 && (try bob.store.fetchMission(id: mission.id))?.status == .awaitingApproval, "bob steering does not run the loop in his engine")
    let turnsBefore = provider.missionTurns
    await bob.rejectMissionAction(actionID: proposed.id, reason: "Not that.")
    sync()
    try await waitFor("alice's loop to continue after bob's rejection") { provider.missionTurns > turnsBefore }
    try await waitFor("alice's mission to finish") { (try alice.store.fetchMission(id: mission.id))?.status == .completed }
    sync()
    let aliceTurns = try alice.store.fetchMissionTurns(missionID: mission.id)
    let steeredTurn = aliceTurns.contains { $0.role == .user && $0.contentJSON.contains("Bob steers.") }
    expect(bobProvider.missionTurns == 0 && provider.missionTurns == turnsBefore + 1 && steeredTurn,
        "bob's rejection and steering continue alice's loop in alice's engine only, once, with bob's text in it")

    provider.missionSteps = [[.tool("create_notebook_entry", ["title": "Again", "body": "b"])]]
    bob.appendMissionUserMessage(missionID: mission.id, text: "One more, please.")
    sync()
    try await waitFor("alice's loop to pick up steering of a finished mission") { (try alice.store.fetchMission(id: mission.id))?.status == .awaitingApproval }
    sync()
    let second = try alice.store.fetchPendingMissionActions(missionID: mission.id).first!
    let turnsAtApproval = provider.missionTurns
    await alice.approveMissionAction(actionID: second.id)
    try await waitFor("alice's loop to finish after her approval") { (try alice.store.fetchMission(id: mission.id))?.status == .completed }
    sync()
    try await Task.sleep(for: .milliseconds(300))
    let ran = try alice.store.fetchMissionAction(id: second.id)!
    expect(try [.succeeded, .failed].contains(ran.status) && ran.completedAt != nil && provider.missionTurns == turnsAtApproval + 1 && bobProvider.missionTurns == 0
        && (try bob.store.fetchMissionAction(id: second.id))?.status == ran.status,
        "alice approving runs the action in her engine and her loop continues once; bob sees the result and never forks it")

    let labTurns = try alice.store.fetchMissionTurns(missionID: mission.id)
    let bobsStray = MissionTurn(missionID: mission.id, index: labTurns.count - 1, role: .user,
        contentJSON: String(decoding: try JSONEncoder().encode([LLMContentBlock(content: .text("Typed by bob, refused."))]), as: UTF8.self))
    let duplicate = MissionTurn(missionID: mission.id, index: 0, role: .assistant, contentJSON: "[]")
    try bob.store.save(bobsStray)
    try bob.store.save(duplicate)
    var queuedTurn = MissionTurn(missionID: mission.id, index: labTurns.count, role: .user,
        contentJSON: String(decoding: try JSONEncoder().encode([LLMContentBlock(content: .text("Not sent yet."))]), as: UTF8.self))
    queuedTurn.missionID = mission.id
    try bob.store.save(queuedTurn)
    bob.collaboration.enqueueMissionTurn(queuedTurn)
    let held = try alice.store.fetchMissionActions(missionID: mission.id)
    var labMission = try alice.store.fetchMission(id: mission.id)!
    labMission.editors = [aliceAuthor]
    bob.collaboration.onMissionSnapshot?(MissionSnapshot(missions: [labMission], turns: labTurns, actions: held))
    try await Task.sleep(for: .milliseconds(300))
    let bobTurns = try bob.store.fetchMissionTurns(missionID: mission.id).map(\.id)
    expect(Set(bobTurns) == Set(labTurns.map(\.id) + [queuedTurn.id]),
        "after a resync bob holds exactly the lab's turns plus the one still queued; refused ones are dropped")
    expect(bob.myPendingSteering(missionID: mission.id).map(\.text) == ["Typed by bob, refused."],
        "what bob typed in a refused turn is put back as steering, not lost")

    expect(try bob.executor(of: bob.store.fetchMissionAction(id: second.id)!)?.id == "alice" && !bob.isStartedByMe(try bob.store.fetchMission(id: mission.id)!)
        && alice.isStartedByMe(try alice.store.fetchMission(id: mission.id)!), "who started a mission and who executes an action are public questions")

    provider.holdsMissions = true
    bob.appendMissionUserMessage(missionID: mission.id, text: "Keep going.")
    sync()
    try await waitFor("alice's loop to run again") { (try alice.store.fetchMission(id: mission.id))?.status == .running }
    sync()
    let live = try bob.store.fetchMission(id: mission.id)!
    expect(alice.canStop(live) && !bob.canStop(live), "the starter can stop a mission; a member who neither started it nor owns the lab cannot")
    bob.cancelMission(missionID: mission.id)
    expect(try bob.store.fetchOutboxOps(MissionOp.self).isEmpty, "and stopping it as such a member sends nothing")
    var cancelled = try alice.store.fetchMission(id: mission.id)!
    cancelled.status = .cancelled
    alice.collaboration.onMissionOpReceived?(.missionUpsert(.init(mission: cancelled)))
    try await Task.sleep(for: .milliseconds(300))
    expect(try alice.store.fetchMission(id: mission.id)?.status == .cancelled
        && alice.labProblems.contains { if case .missionStoppedByOwner(mission.id, _) = $0.concern { return true }; return false },
        "a cancellation from the lab's owner stops the starter's running loop, and the starter is told as a lab problem")
    provider.holdsMissions = false
    let ownerProblem = alice.labProblems.first { if case .missionStoppedByOwner = $0.concern { return true }; return false }!
    alice.dismiss(ownerProblem)
    expect(!alice.labProblems.contains { $0.id == ownerProblem.id }, "a lab problem can be dismissed")

    for op in try bob.store.fetchOutboxOps(MissionOp.self) { _ = try bob.store.removeOutboxOp(opID: op.opID) }

    provider.holdsMissions = true
    let turnsAtApproval2 = provider.missionTurns
    let steered = alice.startMission(goal: "Steer me", providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 0)!
    try await waitFor("alice's loop to be busy") { provider.missionTurns > turnsAtApproval2 }
    sync()
    let turnsAtSteering = provider.missionTurns
    alice.appendMissionUserMessage(missionID: steered.id, text: "Alice adds.")
    bob.appendMissionUserMessage(missionID: steered.id, text: "Bob adds.")
    expect(bob.myPendingSteering(missionID: steered.id).map(\.text) == ["Bob adds."] && alice.myPendingSteering(missionID: steered.id).map(\.text) == ["Alice adds."],
        "each member's input shows their own pending steering")
    sync()
    expect(alice.pendingSteering(missionID: steered.id).count == 2, "two members steering at once: the starter holds both texts")
    provider.holdsMissions = false
    try await waitFor("alice's loop to take up the steering") { (try alice.store.fetchMission(id: steered.id))?.status == .completed && provider.missionTurns == turnsAtSteering + 1 }
    sync()
    let steeredTurns = try alice.store.fetchMissionTurns(missionID: steered.id).map(\.contentJSON).joined()
    expect(steeredTurns.components(separatedBy: "Alice adds.").count == 2 && steeredTurns.components(separatedBy: "Bob writes:\\nBob adds.").count == 2,
        "both texts reach the starter's model exactly once, bob's attributed to him")
    expect(alice.pendingSteering(missionID: steered.id).isEmpty && bob.pendingSteering(missionID: steered.id).isEmpty && bobProvider.missionTurns == 0,
        "consuming them clears them for everyone")

    provider.missionSteps = [[.tool("create_notebook_entry", ["title": "Offline", "body": "b"])]]
    let offline = alice.startMission(goal: "Approve offline", providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 0)!
    try await waitFor("an action to approve") { (try alice.store.fetchMission(id: offline.id))?.status == .awaitingApproval }
    sync()
    let olderMission = try alice.store.fetchMission(id: offline.id)!
    let olderTurns = try alice.store.fetchMissionTurns(missionID: offline.id)
    let olderActions = try alice.store.fetchMissionActions(missionID: offline.id)
    let turnsAtOffline = provider.missionTurns
    await alice.approveMissionAction(actionID: olderActions[0].id)
    try await waitFor("the approved action to run and the loop to finish") { (try alice.store.fetchMission(id: offline.id))?.status == .completed }
    let ranOffline = try alice.store.fetchMissionAction(id: olderActions[0].id)!
    alice.collaboration.onMissionSnapshot?(MissionSnapshot(missions: [olderMission], turns: olderTurns, actions: olderActions))
    try await Task.sleep(for: .milliseconds(300))
    expect(try alice.store.fetchMissionAction(id: ranOffline.id) == ranOffline && (try alice.store.fetchMission(id: offline.id))?.status == .completed,
        "rejoining: the lab's older copy of a row with queued writes does not replace the newer local one")
    let queuedAtRejoin = try alice.store.fetchOutboxOps(MissionOp.self).count
    sync()
    try await Task.sleep(for: .milliseconds(300))
    expect(try alice.store.fetchMissionAction(id: ranOffline.id) == ranOffline && (try alice.store.fetchOutboxOps(MissionOp.self)).isEmpty && queuedAtRejoin > 0
        && provider.missionTurns == turnsAtOffline + 1,
        "the echoes of the replayed writes never move the action back, it does not run again, and nothing more is sent")

    let refusedHere = MissionTurn(missionID: offline.id, index: 99, role: .user,
        contentJSON: String(decoding: try JSONEncoder().encode([LLMContentBlock(content: .text("Alice typed, refused."))]), as: UTF8.self))
    try alice.store.save(refusedHere)
    var labCopy = try alice.store.fetchMission(id: offline.id)!
    labCopy.status = .running
    let turnsAtRefusal = provider.missionTurns
    alice.collaboration.onMissionSnapshot?(MissionSnapshot(
        missions: [labCopy], turns: try alice.store.fetchMissionTurns(missionID: offline.id).filter { $0.id != refusedHere.id },
        actions: try alice.store.fetchMissionActions(missionID: offline.id)))
    try await waitFor("the starter's loop to continue with the returned text") {
        try provider.missionTurns == turnsAtRefusal + 1 && (try alice.store.fetchMission(id: offline.id))?.status == .completed
    }
    try await Task.sleep(for: .milliseconds(300))
    let afterRefusal = try alice.store.fetchMissionTurns(missionID: offline.id).map(\.contentJSON).joined()
    expect(afterRefusal.components(separatedBy: "Alice typed, refused.").count == 2 && provider.missionTurns == turnsAtRefusal + 1,
        "after the starter's turn is refused, her loop continues once from the lab's turns with her text")
    sync()

    let chats = alice.objectChats
    let chatID = chats.openConversation().id
    let base = Date()
    var calls: [ObjectChatToolCall] = []
    for offset in [2, 0, 1] {
        var call = ObjectChatToolCall(chatID: chatID, messageID: UUID(), replyTo: UUID(), offset: 0, index: offset, toolCallID: "t\(offset)",
            tool: "list_sessions", args: [:], askedBy: bobAuthor, executor: bobAuthor, status: .succeeded)
        call.createdAt = base.addingTimeInterval(Double(offset))
        calls.append(call)
    }
    for call in calls { chats.apply(ObjectChatOp(.toolCallUpsert(call))) }
    let ordered = chats.thread(of: chatID).toolCalls.filter { calls.map(\.id).contains($0.id) }.map(\.index)
    expect(ordered == [0, 1, 2], "a thread's calls are in the same order however they arrived")
    let wholeSecond = Date(timeIntervalSince1970: (Date().timeIntervalSince1970).rounded(.down))
    var sameSecond: [ObjectChatToolCall] = []
    for offset in 0..<4 {
        var call = ObjectChatToolCall(chatID: chatID, messageID: UUID(), replyTo: UUID(), offset: 0, index: 0, toolCallID: "s\(offset)",
            tool: "list_sessions", args: [:], askedBy: bobAuthor, executor: bobAuthor, status: .succeeded)
        call.createdAt = wholeSecond.addingTimeInterval(Double(offset) * 0.2)
        sameSecond.append(call)
    }
    let wired = sameSecond.map { call -> ObjectChatToolCall in
        var w = call
        w.createdAt = wholeSecond
        return w
    }
    for call in sameSecond { chats.apply(ObjectChatOp(.toolCallUpsert(call))) }
    expect(bob.objectChats.openConversation().id == chatID, "bob has the same conversation")
    for call in wired.reversed() { bob.objectChats.apply(ObjectChatOp(.toolCallUpsert(call))) }
    let ids = Set(sameSecond.map(\.id))
    let atAlice = chats.thread(of: chatID).toolCalls.filter { ids.contains($0.id) }.map(\.id)
    let atBob = bob.objectChats.thread(of: chatID).toolCalls.filter { ids.contains($0.id) }.map(\.id)
    let stored = try bob.store.fetchObjectChatToolCalls(chatID: chatID).filter { ids.contains($0.id) }.map(\.id)
    expect(atAlice == atBob && atBob == stored,
        "calls made in the same second by different replies sort the same for the maker (sub-second clock), a member holding the wire's seconds, and the store")
}

@MainActor
func relayMissions(from sender: Engine, as author: Author, to engines: [Engine]) {
    for op in try! sender.store.fetchOutboxOps(MissionOp.self) {
        _ = try! sender.store.removeOutboxOp(opID: op.opID)
        var stamped = op
        if case .missionUpsert(var upsert) = op {
            let held = try! sender.store.fetchMission(id: upsert.mission.id)
            upsert.mission.editors = held?.editors.isEmpty == false ? held!.editors : [author]
            stamped = .missionUpsert(upsert)
        }
        for engine in engines { engine.collaboration.onMissionOpReceived?(stamped) }
    }
}

@MainActor
func removals(engine: Engine, provider: ScriptedProvider) async throws {
    let store = engine.store
    func queued(_ family: String, _ subject: UUID) throws -> Int {
        switch family {
        case "mission": try store.fetchOutboxOps(MissionOp.self).filter { $0.missionID == subject }.count
        case "instrument": try store.fetchOutboxOps(CustomInstrumentOp.self).filter { $0.defID == subject }.count
        default: try store.fetchOutboxOps(PatternSourceOp.self).filter { $0.sourceID == subject }.count
        }
    }
    func refuse(_ opID: UUID, _ reason: String) {
        engine.collaboration.handleOpRejected(["op_id": opID.uuidString, "reason": reason])
    }
    var generic: [String] = []
    let reportRefusal = engine.collaboration.onOpRejected
    engine.collaboration.onOpRejected = { subject, reason in
        generic.append(reason)
        reportRefusal?(subject, reason)
    }
    func problems() -> Int { engine.labProblems.count }

    provider.holdsMissions = true
    let running = engine.startMission(goal: "Hold on", providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 0)!
    try await waitFor("the mission's loop to ask the model") { provider.missionTurns >= 1 }
    engine.collaboration.onMissionOpReceived?(.missionRemove(.init(missionID: running.id)))
    try await Task.sleep(for: .milliseconds(500))
    expect(try store.fetchMission(id: running.id) == nil && (try queued("mission", running.id)) == 0,
        "a mission removed in the lab while its loop runs here is stopped, deleted, and nothing is queued for it")
    expect(engine.labProblems.contains { if case .missionDeletedInLab(running.id, _) = $0.concern { return true }; return false },
        "and the member is told as a lab problem naming the mission")
    engine.collaboration.enqueueMissionUpsert(running)
    expect(try queued("mission", running.id) == 0, "and nothing can be queued for it afterwards")

    let refusedMission = engine.startMission(goal: "Hold on again", providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 0)!
    try await waitFor("the second loop") { provider.missionTurns >= 2 }
    let queuedOps = try store.fetchOutboxOps(MissionOp.self).filter { $0.missionID == refusedMission.id }
    refuse(queuedOps[0].opID, "mission_upsert: the mission was removed")
    try await Task.sleep(for: .milliseconds(500))
    expect(try store.fetchMission(id: refusedMission.id) == nil && (try queued("mission", refusedMission.id)) == 0 && queuedOps.count >= 1,
        "a refusal saying the mission was removed stops it the same way, and purges its other queued ops so no refusal repeats")
    let problemsAfterRemovals = problems()
    refuse(queuedOps.last!.opID, "action_upsert: the mission was removed")
    engine.collaboration.onMissionOpReceived?(.missionRemove(.init(missionID: refusedMission.id)))
    expect(generic.isEmpty && problems() == problemsAfterRemovals && problemsAfterRemovals == 2,
        "each removal is one problem; refusals and removals that follow from it are not reported again")

    provider.holdsMissions = true
    let mine = engine.startMission(goal: "Mine to delete", providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 0)!
    try await waitFor("my loop to run") { provider.missionTurns >= 3 }
    engine.deleteMission(missionID: mine.id)
    provider.holdsMissions = false
    try await Task.sleep(for: .milliseconds(500))
    let left = try store.fetchOutboxOps(MissionOp.self).filter { $0.missionID == mine.id }
    expect(left.map(\.kind) == ["mission_remove"] && problems() == problemsAfterRemovals && generic.isEmpty,
        "deleting my own running mission reports nothing and sends only its removal, none of its loop's late writes")
    _ = try store.removeOutboxOp(opID: left[0].opID)

    provider.missionMCP = ("pharo_add_snippet", ["source": "removed"])
    let waiting = engine.startMission(goal: "Removed during an MCP wait", providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 0)!
    try await waitFor("the MCP call to wait for approval") { !(try store.fetchPendingMissionActions(missionID: waiting.id)).isEmpty }
    engine.collaboration.onMissionOpReceived?(.missionRemove(.init(missionID: waiting.id)))
    try await waitFor("the waiting MCP call to return") { !provider.mcpAnswers.isEmpty }
    try await Task.sleep(for: .milliseconds(500))
    expect(try provider.mcpAnswers[0].contains("this mission was deleted in the lab") && problems() == problemsAfterRemovals + 1
        && (try queued("mission", waiting.id)) == 0 && provider.missionTurns == 4,
        "a mission removed during an MCP wait answers the call with why, warns once, sends nothing and asks the model no more")
    provider.holdsMissions = false

    let untouched = engine.createCustomInstrument(name: "Untouched")
    let edited = engine.createCustomInstrument(name: "Edited")
    try store.markKnownToLab([LabSubject(.definition, untouched.id), LabSubject(.definition, edited.id)])
    for op in try store.fetchOutboxOps(CustomInstrumentOp.self) { _ = try store.removeOutboxOp(opID: op.opID) }
    var offline = try store.fetchCustomInstrumentDef(id: edited.id)!
    offline.name = "Edited offline"
    engine.updateCustomInstrument(offline)
    let edit = try store.fetchOutboxOps(CustomInstrumentOp.self).first { $0.defID == edited.id }!
    refuse(edit.opID, "upsert: the instrument was removed")
    let kept = try store.fetchCustomInstrumentDefs().first { $0.name == "Edited offline" && $0.id != edited.id }
    expect(kept != nil && engine.subjectsKeptFromLab.contains(LabSubject(.definition, kept!.id)) && generic.isEmpty,
        "an instrument edit refused because the lab removed it is kept as a copy under a new id, withheld from the lab")
    engine.collaboration.onCustomInstrumentSnapshot?([], [:])
    let remaining = Set(try store.fetchCustomInstrumentDefs().map(\.id))
    expect(try !remaining.contains(edited.id) && !remaining.contains(untouched.id) && remaining.contains(kept!.id) && (try queued("instrument", kept!.id)) == 0,
        "the resync drops the removed original and an untouched copy as before, keeps mine, and does not upload it")
    expect(engine.labProblems.contains { if case .copyKeptFromLab(LabSubject(.definition, kept!.id), "Edited offline") = $0.concern { return true }; return false },
        "the kept copy is a lab problem leading to it")
    engine.addToLab(LabSubject(.definition, kept!.id))
    expect(!engine.labProblems.contains { if case .copyKeptFromLab(LabSubject(.definition, kept!.id), _) = $0.concern { return true }; return false },
        "and adding it to the lab settles that problem")
    expect(try queued("instrument", kept!.id) == 1 && !engine.subjectsKeptFromLab.contains(LabSubject(.definition, kept!.id)),
        "adding it to the lab again uploads it under its new id")

    let pattern = try engine.patterns.create(named: "header", kind: .pattern, text: "struct H { u32 a; };")
    let patternID = UUID(uuidString: pattern.id)!
    try store.markKnownToLab([LabSubject(.pattern, patternID)])
    for op in try store.fetchOutboxOps(PatternSourceOp.self) { _ = try store.removeOutboxOp(opID: op.opID) }
    try engine.patterns.write("struct H { u32 a; u32 b; };", to: pattern.id)
    try engine.patterns.write("struct H { u32 a; u32 b; u32 c; };", to: pattern.id)
    let patternEdit = try store.fetchOutboxOps(PatternSourceOp.self).first { $0.sourceID == patternID }!
    refuse(patternEdit.opID, "upsert: the pattern was removed")
    engine.collaboration.onPatternSourcesSnapshot?([])
    let patterns = try store.fetchPatternSources()
    let keptPattern = patterns.first { $0.text.contains("u32 b") && $0.id != patternID }
    expect(patterns.filter { $0.text.contains("u32 b") && $0.id != patternID }.count == 1 && generic.isEmpty,
        "two queued edits of a removed pattern make one copy and one problem; the second edit is not sent to be refused again")
    expect(try keptPattern != nil && !patterns.contains { $0.id == patternID } && (try queued("pattern", keptPattern!.id)) == 0,
        "a pattern edit refused because the lab removed it is kept under a new id, the original dropped, nothing uploaded")

    let copied = try engine.patterns.create(named: "copied", kind: .pattern, text: "struct C { u8 c; };")
    let copiedID = UUID(uuidString: copied.id)!
    for op in try store.fetchOutboxOps(PatternSourceOp.self) { _ = try store.removeOutboxOp(opID: op.opID) }
    engine.collaboration.onPatternSourcesSnapshot?([])
    let upload = try store.fetchOutboxOps(PatternSourceOp.self).first { $0.sourceID == copiedID }!
    refuse(upload.opID, "upsert: the pattern was removed")
    engine.collaboration.onPatternSourcesSnapshot?([])
    engine.collaboration.onPatternSourcesSnapshot?([])
    let afterJoin = try store.fetchPatternSources().filter { $0.text.contains("u8 c") }
    expect(try afterJoin.count == 1 && afterJoin[0].id != copiedID && (try store.fetchOutboxOps(PatternSourceOp.self)).allSatisfy { $0.sourceID != afterJoin[0].id && $0.sourceID != copiedID },
        "a project copied before a subject was synced keeps it as one local copy when the lab refuses it as removed, and does not upload it again")
}
