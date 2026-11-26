import Foundation
import Observation
import SwiftyPharo

@Observable
@MainActor
public final class ObjectChats {
    public struct Thread: Sendable {
        public var messages: [ObjectChatMessage] = []
        public var toolCalls: [ObjectChatToolCall] = []
        public var objects: [ObjectChatObject] = []
        public var replyText: String?
        public var liveObjectIDs: Set<String> = []
    }

    public private(set) var chats: [ObjectChat] = [] {
        didSet { engine?.instructionChatsChanged(from: oldValue, to: chats) }
    }
    public private(set) var threads: [UUID: Thread] = [:]
    private var drafts: [UUID: ObjectChat] = [:]
    private var discardedDrafts: Set<UUID> = []
    private var deletedHere: Set<UUID> = []
    private var modelChoiceRevision = 0
    public private(set) var readThrough: [UUID: Int] = [:]
    public private(set) var unsent: [UUID: String] = [:]
    public private(set) var removedInLab: Set<UUID> = []
    public private(set) var problems: [ObjectChatProblem] = []

    @ObservationIgnored public var onMessageArrived: (@MainActor (ObjectChat, ObjectChatMessage) -> Void)?
    @ObservationIgnored private weak var engine: Engine?
    @ObservationIgnored private var turns: [UUID: ObjectChatTurn] = [:]
    @ObservationIgnored private var replies: [UUID: Task<Void, Never>] = [:]

    public static let evaluateTool = "chat_evaluate"
    public static let viewTool = "chat_view"
    public static let objectsTool = "chat_objects"

    static let chatsPerLab = 1000
    static let objectsPerChat = 1000
    static let historyWindow = 100
    static let shortSubjectLength = 40
    static let bodyByteLimit = 64 * 1024
    static let argsByteLimit = 64 * 1024
    static let resultByteLimit = 256 * 1024
    static let summaryByteLimit = 1024
    static let errorByteLimit = 8 * 1024
    static let printStringByteLimit = 8 * 1024
    static let sourceByteLimit = 64 * 1024
    static let replyLimits = ReplyLoop.Limits(iterations: 12, maxOutputTokens: 4096, temperature: 0.3)

    init(engine: Engine) {
        self.engine = engine
    }

    public func thread(of chatID: UUID) -> Thread {
        threads[chatID] ?? Thread()
    }

    public var callsWaitingForMe: [ObjectChatToolCall] {
        threads.values.flatMap(\.toolCalls).filter { $0.status == .proposed && isMine($0.executor) }
    }

    public private(set) var conversationID = ObjectChat.soloConversationID

    func followLab() {
        conversationID = labID.map(ObjectChat.conversationID(ofLab:)) ?? ObjectChat.soloConversationID
    }

    public var conversation: ObjectChat? {
        chats.first { $0.id == conversationID }
    }

    public func chat(withID chatID: UUID) -> ObjectChat? {
        chats.first { $0.id == chatID } ?? drafts[chatID]
    }

    public func isDraft(_ chatID: UUID) -> Bool {
        drafts[chatID] != nil
    }

    public func wasDiscarded(_ chatID: UUID) -> Bool {
        discardedDrafts.contains(chatID)
    }

    public func wasDeletedHere(_ chatID: UUID) -> Bool {
        deletedHere.contains(chatID)
    }

    public func modelChoice(in chatID: UUID) -> ObjectChatModelChoice {
        _ = modelChoiceRevision
        return LumaAppState.shared.chatModelChoice(forChatID: chatID) ?? LumaAppState.shared.lastChatModelChoice
    }

    public func setModelChoice(_ choice: ObjectChatModelChoice, in chatID: UUID) {
        LumaAppState.shared.setChatModelChoice(choice, forChatID: chatID)
        modelChoiceRevision += 1
    }

    public func answerUnavailableReason(in chatID: UUID) async -> String? {
        let choice = modelChoice(in: chatID)
        let engine = engine!
        guard let provider = engine.llmRegistry.provider(id: choice.providerID) else {
            return "There is no provider \(choice.providerID) in this Luma."
        }
        if let reason = provider.unavailableReason() { return reason }
        guard provider.descriptor.capabilities.supports(.apiKey) else { return nil }
        let apiKey = try? await engine.llmCredentials.apiKey(providerID: choice.providerID)
        guard apiKey == nil else { return nil }
        return "\(provider.descriptor.displayName) needs an API key in this Luma."
    }

    public var otherChatCount: Int {
        listed.filter { $0.id != conversationID }.count
    }

    public var listed: [ObjectChat] {
        chats.sorted { a, b in
            guard (a.id == conversationID) == (b.id == conversationID) else { return a.id == conversationID }
            return (lastActivity(of: a), b.id.uuidString) > (lastActivity(of: b), a.id.uuidString)
        }
    }

    public func lastActivity(of chat: ObjectChat) -> Date {
        thread(of: chat.id).messages.last?.createdAt ?? chat.createdAt
    }

    public func subject(of chat: ObjectChat) -> ObjectChatSubjectPlace {
        switch chat.subject {
        case .project:
            .project
        case .instruction(let sessionID, let anchor):
            .instruction(engine!.place(ofInstructionChat: chat.id, sessionID: sessionID, anchor: anchor))
        case .object(let origin, let label, _, _, _, _):
            .object(origin: origin, label: label)
        }
    }

    public func chats(aboutInstructionAt address: UInt64, in sessionID: UUID) -> [ObjectChat] {
        (engine!.addressAnnotations[sessionID]?[address]?.chatIDs ?? []).compactMap { chatID in chats.first { $0.id == chatID } }
    }

    public func displayTitle(of chat: ObjectChat) -> String {
        if chat.id == conversationID { return "Project Chat" }
        if let title = chat.title { return title }
        switch chat.subject {
        case .project:
            return "Chat about the project"
        case .instruction(_, let anchor):
            return "Chat about \(anchor.displayString)"
        case .object(_, _, _, "LumaChat", let printString, _):
            return Self.chatAboutChat(titled: printString)
        case .object(_, _, _, _, let printString, _):
            return "Chat about \(Self.short(Self.withoutAddress(printString)))"
        }
    }

    func displayTitle(ofChatWithID chatID: UUID) -> String? {
        chat(withID: chatID).map(displayTitle(of:))
    }

    private static func chatAboutChat(titled printString: String) -> String {
        let within = shortSubjectLength - "the chat on ".count
        guard printString.hasPrefix("about ") else { return "Chat about the chat “\(short(printString, within: within))”" }
        return "Chat about the chat on \(short(String(printString.dropFirst("about ".count)), within: within))"
    }

    private static func withoutAddress(_ printString: String) -> String {
        printString.replacingOccurrences(of: #" @ 0x[0-9A-Fa-f]+$"#, with: "", options: .regularExpression)
    }

    private static func short(_ printString: String, within length: Int = shortSubjectLength) -> String {
        let line = printString.prefix { !$0.isNewline }
        guard line.count > length else { return String(line) }
        let cut = line.prefix(length)
        return String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut) + "…"
    }

    public func openConversation() -> ObjectChat {
        rekeySoloConversation(heldByLab: false)
        if let conversation { return conversation }
        let opened = ObjectChat(id: conversationID, title: nil, subject: .project, editors: [me].compactMap { $0 })
        keep(opened)
        enqueue(.chatUpsert(opened))
        return opened
    }

    public func canDelete(_ chatID: UUID) -> Bool {
        guard chatID != conversationID, let chat = chat(withID: chatID) else { return false }
        return removedInLab.contains(chatID) || isMine(chat.creator) || isLabOwner
    }

    public func canRename(_ chatID: UUID) -> Bool {
        chatID != conversationID && !removedInLab.contains(chatID) && chat(withID: chatID) != nil
    }

    public func canEdit(_ message: ObjectChatMessage) -> Bool {
        isMine(message.author)
    }

    public func canRemove(_ message: ObjectChatMessage) -> Bool {
        isMine(message.author) || isLabOwner
    }

    public func unreadCount(in chatID: UUID) -> Int {
        let readThrough = readThrough[chatID] ?? -1
        return thread(of: chatID).messages.filter { $0.index > readThrough && !isMine($0.author) }.count
    }

    public func markRead(_ chatID: UUID) {
        guard let last = thread(of: chatID).messages.last?.index, last != readThrough[chatID] else { return }
        readThrough[chatID] = last
        persist { try $0.saveObjectChatReadMarker(chatID: chatID, readThrough: last) }
    }

    public func isMine(_ message: ObjectChatMessage) -> Bool {
        isMine(message.author)
    }

    public func isAsker(of call: ObjectChatToolCall) -> Bool {
        isMine(call.askedBy)
    }

    public func isExecutor(of call: ObjectChatToolCall) -> Bool {
        isMine(call.executor)
    }

    public func hold(on call: ObjectChatToolCall) -> ObjectChatCallHold? {
        guard call.status == .proposed, let sessionID = sessionID(of: call) else { return nil }
        return engine!.hold(onCallExecutedBy: call.executor, in: sessionID)
    }

    public func isStranded(_ call: ObjectChatToolCall) -> Bool {
        hold(on: call) != nil
    }

    public func resend(_ messageID: UUID, in chatID: UUID) {
        guard let message = thread(of: chatID).messages.first(where: { $0.id == messageID }), unsent[messageID] != nil else { return }
        guard !removedInLab.contains(chatID) else { return markUnsent(messageID, because: ObjectChatError.gone.localizedDescription) }
        markSent(messageID)
        enqueue(.messageAppend(message))
    }

    public func location(of object: PharoObject) async throws -> (chatID: UUID, objectID: String)? {
        try await image(of: UUID()).location(of: object)
    }

    public func start(
        about object: PharoObject,
        from origin: ObjectChat.Origin,
        label: String,
        source: String?
    ) async throws -> (chat: ObjectChat, column: PharoObject) {
        let image = try await image(of: UUID())
        let snapshot = try await PharoSnapshot.capture(of: object, using: image.runtime)
        let subject: ObjectChat.Subject
        if object.isClass, object.printString == "LumaProject" {
            subject = .project
        } else if let identity = try await image.instructionIdentity(of: object) {
            subject = .instruction(sessionID: identity.sessionID, anchor: identity.anchor)
        } else {
            subject = .object(
                origin: origin,
                label: label,
                source: source.map { Self.cut($0, to: Self.sourceByteLimit) },
                className: object.className,
                printString: Self.cut(object.printString, to: Self.printStringByteLimit),
                snapshot: snapshot
            )
        }
        return try await begin(chat(about: object, subject: subject, id: image.chatID), about: object, snapshot: snapshot, in: image)
    }

    public func start(aboutInstructionAt anchor: AddressAnchor, in sessionID: UUID) async throws -> (chat: ObjectChat, column: PharoObject)
    {
        let image = try await image(of: UUID())
        let instruction = try await image.rebuildInstruction(sessionID: sessionID, anchor: anchor)
        let snapshot = try await PharoSnapshot.capture(of: instruction, using: image.runtime)
        let chat = chat(about: instruction, subject: .instruction(sessionID: sessionID, anchor: anchor), id: image.chatID)
        let started = try await begin(chat, about: instruction, snapshot: snapshot, in: image)
        try await image.runtime.release(instruction)
        return started
    }

    private func chat(about object: PharoObject, subject: ObjectChat.Subject, id: UUID) -> ObjectChat {
        ObjectChat(id: id, title: nil, subject: subject, editors: [me].compactMap { $0 })
    }

    private func begin(
        _ chat: ObjectChat,
        about object: PharoObject,
        snapshot: PharoSnapshot,
        in image: ObjectChatImage
    ) async throws -> (chat: ObjectChat, column: PharoObject) {
        guard chats.count < Self.chatsPerLab else { throw ObjectChatError.full("chats", Self.chatsPerLab) }
        drafts[chat.id] = chat
        threads[chat.id] = Thread()
        setModelChoice(modelChoice(in: chat.id), in: chat.id)
        do {
            try await image.store(object, as: "o1", named: "self")
            try await image.retitle(displayTitle(of: chat))
        } catch {
            await discard(chat.id)
            throw error
        }
        threads[chat.id]?.liveObjectIDs.insert("o1")
        let subject = ObjectChatObject(
            chatID: chat.id,
            objectID: "o1",
            name: "self",
            className: object.className,
            printString: Self.cut(object.printString, to: Self.printStringByteLimit),
            snapshot: snapshot,
            producedBy: nil,
            standsFor: nil,
            addedBy: me
        )
        keep(subject)
        return (chat, try await image.column())
    }

    public func discard(_ chatID: UUID) async {
        guard drafts.removeValue(forKey: chatID) != nil else { return }
        discardedDrafts.insert(chatID)
        LumaAppState.shared.setChatModelChoice(nil, forChatID: chatID)
        threads[chatID] = nil
        try? await image(of: chatID).forget()
    }

    func discardDrafts(ofSession sessionID: UUID) {
        for draft in drafts.values where draft.sessionID == sessionID {
            Task { await self.discard(draft.id) }
        }
    }

    private func promote(_ chatID: UUID) {
        let draft = drafts.removeValue(forKey: chatID)!
        keep(draft)
        enqueue(.chatUpsert(draft))
        for object in thread(of: chatID).objects {
            keep(object)
            if !(draft.subject == .project && object.objectID == "o1") {
                enqueue(.objectUpsert(object))
            }
        }
    }

    public func column(of chatID: UUID) async throws -> PharoObject {
        guard let chat = chat(withID: chatID) else { throw ObjectChatError.noSuchChat }
        let image = try await image(of: chatID)
        try? await reviveSubject(of: chat, in: image)
        return try await image.column()
    }

    public func open(_ objectID: String, in chatID: UUID) async throws -> PharoObject {
        try await image(of: chatID).object(objectID)
    }

    public func isLive(_ objectID: String, in chatID: UUID) -> Bool {
        thread(of: chatID).liveObjectIDs.contains(objectID)
    }

    public func add(
        _ object: PharoObject,
        to chatID: UUID,
        named name: String?,
        inPlaceOf standsFor: String? = nil
    ) async throws -> ObjectChatObject {
        guard chat(withID: chatID) != nil else { throw ObjectChatError.noSuchChat }
        guard thread(of: chatID).objects.count < Self.objectsPerChat else { throw ObjectChatError.full("objects", Self.objectsPerChat) }
        let image = try await image(of: chatID)
        let objectID = nextObjectID(in: chatID)
        try await image.store(object, as: objectID, named: name)
        threads[chatID]?.liveObjectIDs.insert(objectID)
        if let standsFor {
            try await image.store(object, as: standsFor, named: name)
            threads[chatID]?.liveObjectIDs.insert(standsFor)
        }
        let added = ObjectChatObject(
            chatID: chatID,
            objectID: objectID,
            name: name,
            className: object.className,
            printString: Self.cut(object.printString, to: Self.printStringByteLimit),
            snapshot: try await PharoSnapshot.capture(of: object, using: image.runtime),
            producedBy: nil,
            standsFor: standsFor,
            addedBy: me
        )
        upsert(added)
        return added
    }

    public func post(_ text: String, in chatID: UUID) throws {
        _ = try append(text, in: chatID, askingAssistant: false)
    }

    public func ask(_ text: String, in chatID: UUID) async throws {
        let question = try append(text, in: chatID, askingAssistant: true)
        let chat = chat(chatID)
        let reply = Task { await self.answer(question, in: chat) }
        replies[chatID] = reply
        await reply.value
        replies[chatID] = nil
    }

    private func append(_ text: String, in chatID: UUID, askingAssistant: Bool) throws -> ObjectChatMessage {
        guard chat(withID: chatID) != nil else { throw ObjectChatError.gone }
        guard text.utf8.count <= Self.bodyByteLimit else { throw ObjectChatError.tooLong }
        if isDraft(chatID) {
            promote(chatID)
        }
        let message = ObjectChatMessage(
            chatID: chatID,
            index: nextMessageIndex(in: chatID),
            role: .user,
            author: me,
            bodyMarkdown: text,
            asksAssistant: askingAssistant
        )
        keep(message)
        enqueue(.messageAppend(message))
        return message
    }

    private func answer(_ question: ObjectChatMessage, in chat: ObjectChat) async {
        let engine = engine!
        let choice = modelChoice(in: chat.id)
        let providerID = choice.providerID
        let modelID = choice.modelID
        let mission = Mission(
            id: chat.id,
            goalText: "Chat about \(chat.title ?? "an object")",
            providerID: providerID,
            modelID: modelID,
            tokenBudgetInput: 0,
            tokenBudgetOutput: 0
        )
        let turn = ObjectChatTurn(chats: self, question: question, mission: mission)
        turns[chat.id] = turn
        threads[chat.id]?.replyText = ""
        defer {
            turns[chat.id] = nil
            threads[chat.id]?.replyText = nil
        }
        guard let provider = engine.llmRegistry.provider(id: providerID) else {
            appendAnswer(of: turn, usage: .zero, error: "There is no provider \(providerID) in this Luma.")
            return
        }
        if let image = try? await image(of: chat.id) {
            try? await reviveSubject(of: chat, in: image)
        }
        let context = toolContext(of: chat)
        let loop = ReplyLoop(
            provider: provider, modelID: modelID, credentials: engine.llmCredentials, mission: mission, limits: Self.replyLimits)
        do {
            let reply = try await loop.run(
                system: await systemPrompt(for: chat),
                messages: history(of: chat.id),
                tools: engine.missionTools.toolSpecs(in: context),
                onDelta: { [weak self] delta in self?.threads[chat.id]?.replyText? += delta },
                runToolUses: { toolUses in await self.run(toolUses, in: turn, context: context) }
            )
            try Task.checkCancellation()
            appendAnswer(of: turn, usage: reply.usage, error: nil)
        } catch {
            appendAnswer(of: turn, usage: .zero, error: error is CancellationError ? "The reply was canceled." : error.localizedDescription)
        }
    }

    private func toolContext(of chat: ObjectChat) -> Set<ToolNeed> {
        switch chat.subject {
        case .project: [.chatObjects, .project, .session]
        case .instruction, .object: chat.sessionID == nil ? [.chatObjects] : [.chatObjects, .session]
        }
    }

    private func systemPrompt(for chat: ObjectChat) async -> String {
        let thread = thread(of: chat.id)
        var slots: [(name: String, value: String)] = []
        if thread.liveObjectIDs.contains("o1"), let image = try? await image(of: chat.id) {
            slots = (try? await image.slots(of: "o1")) ?? []
        }
        let subject = Self.promptSubject(of: chat, stored: thread.objects.first { $0.objectID == "o1" }, slots: slots)
        let instruction = await instructionContext(of: chat)
        return ObjectChatSystemPrompt.build(for: chat, subject: subject, instruction: instruction, objects: thread.objects)
    }

    private static func promptSubject(
        of chat: ObjectChat, stored: ObjectChatObject?, slots: [(name: String, value: String)]
    ) -> ObjectChatSystemPrompt.Subject {
        switch chat.subject {
        case .project:
            return ObjectChatSystemPrompt.Subject(className: "LumaProject class", printString: "LumaProject", views: [], slots: slots)
        case .instruction(_, let anchor):
            return ObjectChatSystemPrompt.Subject(
                className: stored?.className ?? "LumaInstruction", printString: stored?.printString ?? anchor.displayString,
                views: stored?.snapshot?.views.map(\.title) ?? [], slots: slots)
        case .object(_, _, _, let className, let printString, let snapshot):
            return ObjectChatSystemPrompt.Subject(
                className: className, printString: printString, views: snapshot?.views.map(\.title) ?? [], slots: slots)
        }
    }

    private func instructionContext(of chat: ObjectChat) async -> InstructionContext? {
        guard case .instruction(let sessionID, let anchor) = chat.subject else { return nil }
        return await engine!.instructionContext(sessionID: sessionID, anchor: anchor)
    }

    private func history(of chatID: UUID) -> [LLMMessage] {
        var history: [LLMMessage] = []
        let recent = thread(of: chatID).messages.suffix(Self.historyWindow).drop { $0.role == .assistant }
        for message in recent where !message.bodyMarkdown.isEmpty {
            let role: LLMRole = message.role == .assistant ? .assistant : .user
            let text =
                message.author.map { role == .user ? "\($0.name): \(message.bodyMarkdown)" : message.bodyMarkdown } ?? message.bodyMarkdown
            if history.last?.role == role {
                history[history.count - 1].blocks.append(.text(text))
            } else {
                history.append(LLMMessage(role: role, blocks: [.text(text)]))
            }
        }
        return history
    }

    private func run(_ toolUses: [LLMContentBlock], in turn: ObjectChatTurn, context: Set<ToolNeed>) async -> [LLMContentBlock] {
        var results: [LLMContentBlock] = []
        for block in toolUses {
            guard case .toolUse(let id, let name, let inputJSON) = block.content else { continue }
            results.append(LLMContentBlock(content: await toolResult(of: id, name: name, inputJSON: inputJSON, in: turn, context: context)))
        }
        return results
    }

    private func toolResult(of id: String, name: String, inputJSON: String, in turn: ObjectChatTurn, context: Set<ToolNeed>) async
        -> LLMContent
    {
        let catalog = engine!.missionTools
        guard let spec = catalog.spec(named: name), spec.isOffered(in: context) else {
            return Self.toolResult(id, MissionTools.errorResult("this chat has no tool named \(name)", code: .notFound))
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        let call = ToolCallRequest(
            spec: spec,
            args: args,
            argsJSON: inputJSON,
            toolCallID: id,
            sessionID: (args["session_id"] as? String).flatMap(UUID.init(uuidString:)),
            mission: turn.mission
        )
        switch await turn.perform(call, in: catalog) {
        case .completed(let result):
            return Self.toolResult(id, result)
        case .failed(let message):
            return Self.toolResult(id, MissionTools.errorResult(message))
        case .rejected(let reason):
            return Self.toolResult(
                id, MissionTools.errorResult(reason.map { "The user declined: \($0)" } ?? "The user declined to run this.", code: .rejected)
            )
        case .cancelled:
            return Self.toolResult(id, MissionTools.errorResult("The reply was canceled.", code: .rejected))
        }
    }

    private static func toolResult(_ id: String, _ result: ActionResult) -> LLMContent {
        .toolResult(toolUseID: id, contentJSON: result.resultJSON, isError: result.isError, attachments: result.attachments)
    }

    private func appendAnswer(of turn: ObjectChatTurn, usage: LLMUsage, error: String?) {
        let answer = ObjectChatMessage(
            id: turn.messageID,
            chatID: turn.chatID,
            index: nextMessageIndex(in: turn.chatID),
            role: .assistant,
            author: me,
            bodyMarkdown: Self.cut(threads[turn.chatID]?.replyText ?? "", to: Self.bodyByteLimit),
            replyTo: turn.question.id,
            providerID: turn.mission.providerID,
            modelID: turn.mission.modelID,
            error: error.map { Self.cut($0, to: Self.errorByteLimit) },
            usage: usage
        )
        keep(answer)
        enqueue(.messageAppend(answer))
    }

    enum RecordedCall {
        case recorded(UUID)
        case refused(String)
    }

    func recordCall(_ call: ToolCallRequest, in turn: ObjectChatTurn, at index: Int) -> RecordedCall {
        let thread = thread(of: turn.chatID)
        guard call.argsJSON.utf8.count <= Self.argsByteLimit else {
            return .refused("the call's arguments are over \(Self.argsByteLimit / 1024) KiB")
        }
        guard let chat = chat(withID: turn.chatID) else { return .refused("the chat was deleted") }
        let executor = executor(of: call, in: chat)
        let recorded = ObjectChatToolCall(
            chatID: turn.chatID,
            messageID: turn.messageID,
            replyTo: turn.question.id,
            offset: thread.replyText?.count ?? 0,
            index: index,
            toolCallID: call.toolCallID,
            tool: call.spec.name,
            args: (try? JSONDecoder().decode([String: JSONValue].self, from: Data(call.argsJSON.utf8))) ?? [:],
            askedBy: me,
            executor: executor,
            status: initialStatus(of: call.spec, executedBy: executor)
        )
        upsert(recorded)
        return .recorded(recorded.id)
    }

    private func executor(of call: ToolCallRequest, in chat: ObjectChat) -> Author? {
        guard call.spec.needs.contains(.session), let sessionID = call.sessionID ?? chat.sessionID else { return me }
        return host(of: sessionID)
    }

    private func initialStatus(of spec: ActionSpec, executedBy executor: Author?) -> ObjectChatToolCall.Status {
        guard isMine(executor) else { return .proposed }
        if spec.name == Self.evaluateTool {
            return LumaAppState.shared.objectChatRunsWithoutAsking ? .running : .proposed
        }
        return spec.isObserve ? .running : .proposed
    }

    func call(_ callID: UUID) -> ObjectChatToolCall? {
        for thread in threads.values {
            if let found = thread.toolCalls.first(where: { $0.id == callID }) { return found }
        }
        return nil
    }

    func decision(on call: ObjectChatToolCall) -> ToolCallDecision? {
        switch call.status {
        case .proposed:
            nil
        case .running:
            isMine(call.executor) ? .run : nil
        case .succeeded, .failed:
            .settled(
                ActionResult(
                    summary: call.summary ?? "",
                    resultJSON: call.result ?? MissionTools.errorResult(call.error ?? "failed").resultJSON,
                    isError: call.status == .failed))
        case .rejected:
            .rejected(call.error)
        }
    }

    func finishCall(_ callID: UUID, with outcome: ToolCallOutcome) {
        guard var finished = call(callID) else { return }
        switch outcome {
        case .completed(let result):
            finished.status = result.isError ? .failed : .succeeded
            finished.summary = Self.cut(result.summary, to: Self.summaryByteLimit)
            finished.result = Self.cut(result.resultJSON, to: Self.resultByteLimit)
            if result.isError { finished.error = Self.cut(result.summary, to: Self.errorByteLimit) }
        case .failed(let message):
            finished.status = .failed
            finished.error = Self.cut(message, to: Self.errorByteLimit)
        }
        finished.updatedAt = Date()
        upsert(finished)
    }

    public func canRun(_ call: ObjectChatToolCall) -> Bool {
        call.status == .proposed && isMine(call.executor) && hold(on: call) == nil
    }

    public func run(_ callID: UUID) async {
        guard var approved = call(callID), canRun(approved) else { return }
        approved.status = .running
        approved.updatedAt = Date()
        upsert(approved)
        guard !isMine(approved.askedBy) else { return }
        await execute(approved)
    }

    private func execute(_ call: ObjectChatToolCall) async {
        let engine = engine!
        guard let chat = chat(withID: call.chatID) else { return }
        let args = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(call.args))) as? [String: Any] ?? [:]
        let mission = Mission(
            id: chat.id,
            goalText: "Chat about \(chat.title ?? "an object")",
            providerID: "",
            modelID: "",
            tokenBudgetInput: 0,
            tokenBudgetOutput: 0
        )
        let invocation = ActionInvocation(
            args: args,
            mission: mission,
            sessionID: (args["session_id"] as? String).flatMap(UUID.init(uuidString:)),
            toolCallID: call.toolCallID,
            callID: call.id
        )
        do {
            finishCall(call.id, with: .completed(try await engine.missionTools.execute(call.tool, invocation: invocation)))
        } catch {
            finishCall(call.id, with: .failed(error.localizedDescription))
        }
    }

    public func reject(_ callID: UUID, reason: String?) {
        guard var rejected = call(callID), rejected.status == .proposed, isMine(rejected.executor) || isMine(rejected.askedBy)
        else { return }
        rejected.status = .rejected
        rejected.error = reason.map { Self.cut($0, to: Self.errorByteLimit) }
        rejected.updatedAt = Date()
        upsert(rejected)
    }

    public func runAgain(_ callID: UUID) async throws {
        guard let chatID = call(callID)?.chatID, let chat = chat(withID: chatID) else { throw ObjectChatError.noSuchChat }
        let image = try await image(of: chatID)
        try? await reviveSubject(of: chat, in: image)
        for step in chain(endingAt: callID) {
            try await reevaluate(step, in: image)
        }
    }

    private func chain(endingAt callID: UUID) -> [ObjectChatToolCall] {
        var ordered: [ObjectChatToolCall] = []
        func visit(_ step: ObjectChatToolCall) {
            for objectID in Self.expression(of: step).bindings.values {
                if let producer = producer(of: objectID, in: step.chatID), !ordered.contains(where: { $0.id == producer.id }) {
                    visit(producer)
                }
            }
            if !ordered.contains(where: { $0.id == step.id }) {
                ordered.append(step)
            }
        }
        call(callID).map(visit)
        return ordered
    }

    private func producer(of objectID: String, in chatID: UUID) -> ObjectChatToolCall? {
        thread(of: chatID).objects.first { $0.objectID == objectID }?.producedBy.flatMap(call)
    }

    private func reevaluate(_ step: ObjectChatToolCall, in image: ObjectChatImage) async throws {
        let (code, bindings) = Self.expression(of: step)
        try requireLive(["o1"] + bindings.values, in: step.chatID)
        let objectID = step.objectID ?? nextObjectID(in: step.chatID)
        let produced = try await image.evaluate(code, bindings: bindings, as: objectID, runningFor: step.id)
        threads[step.chatID]?.liveObjectIDs.insert(objectID)
        if isMine(step.askedBy) {
            var rerun = step
            rerun.objectID = objectID
            rerun.status = .succeeded
            rerun.error = nil
            rerun.errorPosition = nil
            rerun.summary = Self.cut("\(objectID): \(produced.printString)", to: Self.summaryByteLimit)
            rerun.updatedAt = Date()
            upsert(rerun)
            upsert(try await producedObject(produced, as: objectID, by: rerun, in: image))
        }
        try await image.runtime.release(produced)
    }

    private static func expression(of call: ObjectChatToolCall) -> (code: String, bindings: [String: String]) {
        guard case .string(let code) = call.args["code"] else { return ("", [:]) }
        guard case .array(let listed) = call.args["bindings"] else { return (code, [:]) }
        var bindings: [String: String] = [:]
        for case .object(let binding) in listed {
            if case .string(let name) = binding["name"], case .string(let objectID) = binding["object_id"] {
                bindings[name] = objectID
            }
        }
        return (code, bindings)
    }

    private func requireLive(_ objectIDs: [String], in chatID: UUID) throws {
        for objectID in objectIDs where !isLive(objectID, in: chatID) {
            let holder = thread(of: chatID).objects.first { $0.objectID == objectID }
            guard let holder else { throw ObjectChatError.noSuchObject(objectID) }
            let producer = isMine(holder.addedBy) ? nil : holder.addedBy?.name
            throw ObjectChatError.notLiveHere(objectID, producedIn: producer, canRunAgain: holder.producedBy != nil)
        }
    }

    private func producedObject(
        _ produced: PharoObject,
        as objectID: String,
        by call: ObjectChatToolCall,
        in image: ObjectChatImage
    ) async throws -> ObjectChatObject {
        ObjectChatObject(
            chatID: call.chatID,
            objectID: objectID,
            name: nil,
            className: produced.className,
            printString: Self.cut(produced.printString, to: Self.printStringByteLimit),
            snapshot: try await PharoSnapshot.capture(of: produced, using: image.runtime),
            producedBy: call.id,
            standsFor: nil,
            addedBy: me
        )
    }

    public func cancel(_ chatID: UUID) {
        for proposed in thread(of: chatID).toolCalls where proposed.status == .proposed && isMine(proposed.askedBy) {
            reject(proposed.id, reason: "The reply was canceled.")
        }
        replies[chatID]?.cancel()
    }

    public func rename(_ chatID: UUID, to title: String) {
        guard canRename(chatID) else { return }
        var renamed = chat(chatID)
        renamed.title = String(title.prefix(200))
        renamed.updatedAt = Date()
        if isDraft(chatID) {
            drafts[chatID] = renamed
            Task { try? await self.image(of: chatID).retitle(self.displayTitle(of: renamed)) }
            return
        }
        keep(renamed)
        enqueue(.chatUpsert(renamed))
    }

    public func edit(_ messageID: UUID, in chatID: UUID, to body: String) throws {
        guard var edited = thread(of: chatID).messages.first(where: { $0.id == messageID }), canEdit(edited) else {
            throw ObjectChatError.notYours
        }
        guard body.utf8.count <= Self.bodyByteLimit else { throw ObjectChatError.tooLong }
        edited.bodyMarkdown = body
        keep(edited)
        enqueue(.messageEdit(chatID: chatID, messageID: messageID, bodyMarkdown: body))
    }

    public func remove(_ messageID: UUID, in chatID: UUID) throws {
        guard let removed = thread(of: chatID).messages.first(where: { $0.id == messageID }), canRemove(removed)
        else { throw ObjectChatError.notYours }
        dropMessage(messageID, in: chatID)
        enqueue(.messageRemove(chatID: chatID, messageID: messageID))
    }

    public func delete(_ chatID: UUID) async throws {
        guard chatID != conversationID else { throw ObjectChatError.conversationStays }
        guard !isDraft(chatID) else { return await discard(chatID) }
        guard chats.contains(where: { $0.id == chatID }) else { return }
        guard canDelete(chatID) else { throw ObjectChatError.notYours }
        deletedHere.insert(chatID)
        guard !removedInLab.contains(chatID), !isInSessionTheLabLacks(chatID) else { return await drop(chatID) }
        await drop(chatID)
        enqueue(.chatRemove(chatID: chatID))
    }

    private func drop(_ chatID: UUID) async {
        replies[chatID]?.cancel()
        LumaAppState.shared.setChatModelChoice(nil, forChatID: chatID)
        let calls = thread(of: chatID).toolCalls
        persist(in: chatID) { try $0.deleteObjectChat(id: chatID) }
        chats.removeAll { $0.id == chatID }
        threads[chatID] = nil
        removedInLab.remove(chatID)
        let engine = engine!
        for call in calls {
            await engine.pharo.stopRun(call.id)
        }
        if let image = try? await image(of: chatID) {
            try? await image.forget()
        }
    }

    private func dropKeepingUnsent(_ chatID: UUID) async {
        let known = (try? engine!.store.subjectsKnownToLab(.objectChatMessage)) ?? []
        let unsentHere = thread(of: chatID).messages.filter { isMine($0.author) && !known.contains($0.id) }
        guard !unsentHere.isEmpty else { return await drop(chatID) }
        removedInLab.insert(chatID)
        for message in unsentHere where unsent[message.id] == nil {
            markUnsent(message.id, because: "The chat was deleted in the lab before this reached it.")
        }
    }

    func refused(_ message: ObjectChatMessage, because reason: String) {
        guard chat(withID: message.chatID) != nil else { return }
        markUnsent(message.id, because: reason)
        problems.append(
            ObjectChatProblem(
                kind: .refusedByLab(opKind: "object_chat_message_append"), chatID: message.chatID, messageID: message.id, reason: reason))
    }

    func refused(_ op: ObjectChatOp, because reason: String) {
        guard chat(withID: op.chatID) != nil else { return }
        problems.append(ObjectChatProblem(kind: .refusedByLab(opKind: op.kind), chatID: op.chatID, messageID: nil, reason: reason))
    }

    public func dismiss(_ problemID: UUID) {
        problems.removeAll { $0.id == problemID }
    }

    private func markUnsent(_ messageID: UUID, because reason: String) {
        unsent[messageID] = reason
        persist { try $0.saveUnsentObjectChatMessage(messageID, reason: reason) }
    }

    private func markSent(_ messageID: UUID) {
        unsent[messageID] = nil
        persist { try $0.saveUnsentObjectChatMessage(messageID, reason: nil) }
    }

    func evaluate(_ invocation: ActionInvocation) async -> ActionResult {
        let chatID = invocation.mission.id
        guard var running = thread(of: chatID).toolCalls.first(where: { $0.id == invocation.callID && $0.status == .running })
        else { return MissionTools.errorResult("no chat call is running as \(invocation.toolCallID)", code: .notFound) }
        guard let code = invocation.args["code"] as? String, !code.isEmpty else {
            return MissionTools.errorResult("code is required", code: .invalidInput)
        }
        guard thread(of: chatID).objects.count < Self.objectsPerChat else {
            return MissionTools.errorResult(
                "this chat holds \(Self.objectsPerChat) objects, the most it keeps; start another chat", code: .rejected)
        }
        let bindings = Self.expression(of: running).bindings
        do {
            let image = try await image(of: chatID)
            try requireLive(["o1"] + bindings.values, in: chatID)
            let objectID = nextObjectID(in: chatID)
            let produced = try await image.evaluate(code, bindings: bindings, as: objectID, runningFor: running.id)
            threads[chatID]?.liveObjectIDs.insert(objectID)
            running.objectID = objectID
            keep(running)
            upsert(try await producedObject(produced, as: objectID, by: running, in: image))
            let described = try await describe(produced, as: objectID, in: image)
            try await image.runtime.release(produced)
            return MissionTools.makeResult(jsonObject: described, summary: "\(objectID): \(String(produced.printString.prefix(200)))")
        } catch let failure as PharoRequestError {
            running.errorPosition = failure.sourcePosition
            keep(running)
            var payload: [String: Any] = ["error": failure.localizedDescription]
            payload["position"] = failure.sourcePosition
            var result = MissionTools.makeResult(jsonObject: payload, summary: failure.localizedDescription)
            result.isError = true
            return result
        } catch {
            return MissionTools.errorResult(error.localizedDescription)
        }
    }

    private func describe(_ produced: PharoObject, as objectID: String, in image: ObjectChatImage) async throws -> [String: Any] {
        let views = try await image.runtime.views(of: produced)
        return [
            "object_id": objectID,
            "class": produced.className,
            "print_string": DisplayTruncation.truncated(produced.printString, limit: ObjectChatSystemPrompt.subjectPrintLimit),
            "display": DisplayTruncation.truncated(produced.display, limit: ObjectChatSystemPrompt.subjectPrintLimit),
            "views": views.map { ["title": $0.title, "selector": $0.methodSelector, "kind": $0.viewName] },
            "slots": try await image.slots(of: objectID).map { ["name": $0.name, "value": $0.value] },
        ]
    }

    func view(_ invocation: ActionInvocation) async -> ActionResult {
        let chatID = invocation.mission.id
        guard let objectID = invocation.args["object_id"] as? String, let viewName = invocation.args["view"] as? String else {
            return MissionTools.errorResult("object_id and view are required", code: .invalidInput)
        }
        let from = invocation.args["from"] as? Int ?? 0
        let count = min(invocation.args["count"] as? Int ?? 50, 200)
        guard let stored = thread(of: chatID).objects.first(where: { $0.objectID == objectID }) else {
            return MissionTools.errorResult(ObjectChatError.noSuchObject(objectID).localizedDescription, code: .notFound)
        }
        do {
            let content =
                isLive(objectID, in: chatID)
                ? try await liveView(viewName, of: objectID, in: chatID, from: from, count: count)
                : Self.snapshotView(viewName, of: stored, from: from, count: count)
            return MissionTools.makeResult(jsonObject: content, summary: "\(objectID) \(viewName)")
        } catch {
            return MissionTools.errorResult(error.localizedDescription)
        }
    }

    private func liveView(_ viewName: String, of objectID: String, in chatID: UUID, from: Int, count: Int) async throws -> [String: Any] {
        let image = try await image(of: chatID)
        let object = try await image.object(objectID)
        defer { Task { try? await image.runtime.release(object) } }
        let views = try await image.runtime.views(of: object)
        guard let view = views.first(where: { $0.methodSelector == viewName || $0.title == viewName }) else {
            throw ObjectChatError.noSuchView(viewName, among: views.map(\.title))
        }
        if view.columns != nil {
            let page = try await image.runtime.items(of: object, view: view.methodSelector, from: from + 1, count: count)
            return ["columns": view.columns ?? [], "total": page.total, "from": from, "rows": page.items.map { $0.map { $0.text ?? "" } }]
        }
        if let text = view.text { return ["text": DisplayTruncation.truncated(text, limit: Self.summaryByteLimit * 32)] }
        if let graph = view.graph { return ["graph": ["nodes": graph.nodes.prefix(200).map(\.label), "edges": graph.edges.count]] }
        if let chart = view.chart { return ["chart": chart.series.map { ["kind": $0.kind, "points": $0.points.count] }] }
        return ["kind": view.viewName]
    }

    private static func snapshotView(_ viewName: String, of stored: ObjectChatObject, from: Int, count: Int) -> [String: Any] {
        guard let view = stored.snapshot?.views.first(where: { $0.methodSelector == viewName || $0.title == viewName }) else {
            return ["error": "\(stored.objectID) is not live in this Luma and its snapshot has no view \(viewName)"]
        }
        switch view.content {
        case .items(let kept, let total):
            return [
                "total": total, "from": from, "rows": kept.dropFirst(from).prefix(count).map { $0.map { $0.text ?? "" } },
                "from_snapshot": true,
            ]
        case .text(let text):
            return ["text": text, "from_snapshot": true]
        case .graph(let graph):
            return ["graph": ["nodes": graph.nodes.prefix(200).map(\.label), "edges": graph.edges.count], "from_snapshot": true]
        case .chart(let chart):
            return ["chart": chart.series.map { ["kind": $0.kind, "points": $0.points.count] }, "from_snapshot": true]
        case .canvas, .empty:
            return ["kind": "canvas", "from_snapshot": true]
        }
    }

    func objectsList(_ invocation: ActionInvocation) -> ActionResult {
        let chatID = invocation.mission.id
        let objects = thread(of: chatID).objects
        let listed: [[String: Any]] = objects.map {
            [
                "object_id": $0.objectID,
                "name": $0.name ?? "",
                "class": $0.className,
                "print_string": DisplayTruncation.truncated($0.printString, limit: 500),
                "live_here": isLive($0.objectID, in: chatID),
                "added_by": $0.addedBy?.name ?? "",
            ]
        }
        return MissionTools.makeResult(jsonObject: listed, summary: "\(objects.count) object\(objects.count == 1 ? "" : "s")")
    }

    func turn(of chatID: UUID) -> ObjectChatTurn? {
        turns[chatID]
    }

    func load() {
        followLab()
        let store = engine!.store
        chats = (try? store.fetchObjectChats()) ?? []
        for chat in chats {
            threads[chat.id] = Thread(
                messages: (try? store.fetchObjectChatMessages(chatID: chat.id)) ?? [],
                toolCalls: (try? store.fetchObjectChatToolCalls(chatID: chat.id)) ?? [],
                objects: (try? store.fetchObjectChatObjects(chatID: chat.id)) ?? []
            )
        }
        readThrough = (try? store.fetchObjectChatReadMarkers()) ?? [:]
        unsent = (try? store.fetchUnsentObjectChatMessages()) ?? [:]
    }

    func forgetChats(ofSession sessionID: UUID) {
        discardDrafts(ofSession: sessionID)
        for chat in chats where chat.sessionID == sessionID {
            threads[chat.id] = nil
            try? engine!.store.removeOutboxOps(family: ObjectChatOp.outboxFamily, subject: chat.id)
        }
        chats.removeAll { $0.sessionID == sessionID }
    }

    func apply(_ op: ObjectChatOp) {
        let createsChat: Bool = if case .chatUpsert = op.change { true } else { false }
        guard createsChat || chats.contains(where: { $0.id == op.chatID }) else { return }
        switch op.change {
        case .chatUpsert(let chat):
            guard Self.asSent(chats.first { $0.id == chat.id }) != chat else { return }
            keep(chat)
        case .chatRemove(let chatID):
            Task { await self.dropKeepingUnsent(chatID) }
        case .messageAppend(let message):
            let held = thread(of: message.chatID).messages.first { $0.id == message.id }
            guard Self.asSent(held) != message else { return }
            keep(message)
            if held == nil, !isMine(message.author) { onMessageArrived?(chat(message.chatID), message) }
        case .messageEdit(let chatID, let messageID, let body):
            guard var edited = thread(of: chatID).messages.first(where: { $0.id == messageID }), edited.bodyMarkdown != body else { return }
            edited.bodyMarkdown = body
            keep(edited)
        case .messageRemove(let chatID, let messageID):
            dropMessage(messageID, in: chatID)
        case .toolCallUpsert(let call):
            let held = self.call(call.id)
            let merged = later(of: held, call)
            guard held != merged, Self.asSent(held) != merged else { return }
            keep(merged)
        case .objectUpsert(let object):
            guard Self.asSent(thread(of: object.chatID).objects.first { $0.objectID == object.objectID }) != object else { return }
            keep(object)
        }
    }

    private static func asSent<Row: Codable>(_ row: Row?) -> Row? {
        row.flatMap { decodeRow(encodeRow($0)) }
    }

    private func later(of local: ObjectChatToolCall?, _ arrived: ObjectChatToolCall) -> ObjectChatToolCall {
        guard var local else { return arrived }
        let keepsMine = isMine(local.askedBy) || isMine(local.executor)
        guard
            Self.stage(of: local.status) > Self.stage(of: arrived.status)
                || keepsMine && Self.stage(of: local.status) == Self.stage(of: arrived.status)
        else { return arrived }
        local.askedBy = arrived.askedBy
        local.executor = arrived.executor
        return local
    }

    private static func stage(of status: ObjectChatToolCall.Status) -> Int {
        switch status {
        case .proposed: 0
        case .running: 1
        case .succeeded, .failed, .rejected: 2
        }
    }

    func adopt(_ labThreads: [ObjectChatThread]) {
        let store = engine!.store
        followLab()
        rekeySoloConversation(heldByLab: labThreads.contains { $0.chat.id == conversationID })
        let labChatIDs = Set(labThreads.map(\.chat.id))
        let pending = Set(((try? store.fetchOutboxOps(ObjectChatOp.self)) ?? []).map(\.outboxSubject))
        let knownChats = (try? store.subjectsKnownToLab(.objectChat)) ?? []
        let knownMessages = (try? store.subjectsKnownToLab(.objectChatMessage)) ?? []
        for absent in chats where !labChatIDs.contains(absent.id) && !pending.contains(absent.id) {
            if knownChats.contains(absent.id) {
                Task { await self.dropKeepingUnsent(absent.id) }
            } else {
                upload(absent, withSubject: true)
            }
        }
        for lab in labThreads {
            let local = thread(of: lab.chat.id)
            keep(lab.chat)
            lab.messages.forEach(keep)
            lab.toolCalls.forEach(keep)
            lab.objects.forEach(keep)
            guard !pending.contains(lab.chat.id) else { continue }
            let held = Set(lab.messages.map(\.id))
            for removed in local.messages
            where !held.contains(removed.id) && removed.index >= lab.historyFrom && knownMessages.contains(removed.id) {
                dropMessage(removed.id, in: removed.chatID)
            }
        }
    }

    private func rekeySoloConversation(heldByLab: Bool) {
        followLab()
        guard labID != nil, let solo = chats.first(where: { $0.id == ObjectChat.soloConversationID }) else { return }
        var rekeyed = conversation ?? solo
        rekeyed.id = conversationID
        let store = engine!.store
        guard persist({ try $0.rekeyObjectChat(rekeyed, from: solo.id) }) else { return }
        chats.removeAll { $0.id == solo.id || $0.id == rekeyed.id }
        threads[solo.id] = nil
        readThrough[rekeyed.id] = readThrough.removeValue(forKey: solo.id) ?? readThrough[rekeyed.id]
        chats.append(rekeyed)
        threads[rekeyed.id] = Thread(
            messages: (try? store.fetchObjectChatMessages(chatID: rekeyed.id)) ?? [],
            toolCalls: (try? store.fetchObjectChatToolCalls(chatID: rekeyed.id)) ?? [],
            objects: (try? store.fetchObjectChatObjects(chatID: rekeyed.id)) ?? []
        )
        Task { try? await self.image(of: solo.id).forget() }
        upload(rekeyed, withSubject: !heldByLab)
    }

    private func upload(_ chat: ObjectChat, withSubject: Bool) {
        let thread = thread(of: chat.id)
        if withSubject {
            enqueue(.chatUpsert(chat))
        }
        for var message in thread.messages where isMine(message.author) {
            message.author = message.author ?? me
            keep(message)
            enqueue(.messageAppend(message))
        }
        for var call in thread.toolCalls where isMine(call.askedBy) {
            call.askedBy = call.askedBy ?? me
            call.executor = call.executor ?? me
            upsert(call)
        }
        for var object in thread.objects
        where isMine(object.addedBy) && (withSubject || object.objectID != "o1") && !(chat.subject == .project && object.objectID == "o1") {
            object.addedBy = object.addedBy ?? me
            upsert(object)
        }
    }

    private func keep(_ chat: ObjectChat) {
        persist(in: chat.id) { try $0.save(chat) }
        let retitles = chats.first { $0.id == chat.id }?.title != chat.title || !chats.contains { $0.id == chat.id }
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.append(chat)
            threads[chat.id] = threads[chat.id] ?? Thread()
        }
        if chat.subject == .project, !thread(of: chat.id).objects.contains(where: { $0.objectID == "o1" }) {
            keep(Self.project(in: chat.id))
        }
        if retitles, PharoRuntime.shared.state == .running {
            let title = displayTitle(of: chat)
            Task { try? await self.image(of: chat.id).retitle(title) }
        }
    }

    private func keep(_ message: ObjectChatMessage) {
        persist(in: message.chatID) { try $0.save(message) }
        var messages = thread(of: message.chatID).messages.filter { $0.id != message.id }
        messages.append(message)
        threads[message.chatID]?.messages = messages.sorted { ($0.index, $0.createdAt) < ($1.index, $1.createdAt) }
    }

    private func keep(_ call: ObjectChatToolCall) {
        persist(in: call.chatID) { try $0.save(call) }
        var calls = threads[call.chatID]?.toolCalls.filter { $0.id != call.id } ?? []
        calls.append(call)
        threads[call.chatID]?.toolCalls = calls.sorted(by: ObjectChatToolCall.precedes)
        if let turn = turns[call.chatID], turn.isWaiting(on: call.id), let decided = decision(on: call) {
            turn.settle(call.id, with: decided)
        }
    }

    private static func project(in chatID: UUID) -> ObjectChatObject {
        ObjectChatObject(
            chatID: chatID,
            objectID: "o1",
            name: "self",
            className: "LumaProject class",
            printString: "LumaProject",
            snapshot: nil,
            producedBy: nil,
            standsFor: nil,
            addedBy: nil
        )
    }

    private func keep(_ object: ObjectChatObject) {
        if !isDraft(object.chatID) {
            persist(in: object.chatID) { try $0.save(object) }
        }
        if let index = threads[object.chatID]?.objects.firstIndex(where: { $0.objectID == object.objectID }) {
            threads[object.chatID]?.objects[index] = object
        } else {
            threads[object.chatID]?.objects.append(object)
        }
    }

    private func upsert(_ call: ObjectChatToolCall) {
        keep(call)
        enqueue(.toolCallUpsert(call))
    }

    private func upsert(_ object: ObjectChatObject) {
        keep(object)
        if !isDraft(object.chatID) {
            enqueue(.objectUpsert(object))
        }
    }

    private func dropMessage(_ messageID: UUID, in chatID: UUID) {
        persist(in: chatID) { try $0.deleteObjectChatMessage(id: messageID) }
        threads[chatID]?.messages.removeAll { $0.id == messageID }
    }

    private func enqueue(_ change: ObjectChatOp.Change) {
        let chatID = ObjectChatOp(change).chatID
        guard !isInSessionTheLabLacks(chatID) else { return }
        persist(in: chatID) { _ in try engine!.collaboration.enqueueObjectChat(change) }
    }

    private func isInSessionTheLabLacks(_ chatID: UUID) -> Bool {
        guard let sessionID = chat(withID: chatID)?.sessionID else { return false }
        return engine!.collaboration.isCollaborative && !engine!.collaboration.labHolds(sessionID: sessionID)
    }

    @discardableResult
    private func persist(in chatID: UUID? = nil, _ write: (ProjectStore) throws -> Void) -> Bool {
        do {
            try write(engine!.store)
            return true
        } catch {
            engine!.emitEngineWarning(subsystem: "object-chats", text: "A chat change could not be saved: \(error.localizedDescription)")
            problems.append(ObjectChatProblem(kind: .notSaved, chatID: chatID, messageID: nil, reason: error.localizedDescription))
            return false
        }
    }

    private func reviveSubject(of chat: ObjectChat, in image: ObjectChatImage) async throws {
        guard !isLive("o1", in: chat.id) else { return }
        let subject: PharoObject
        switch chat.subject {
        case .project:
            subject = try await image.project()
        case .instruction(let sessionID, let anchor):
            subject = try await image.rebuildInstruction(sessionID: sessionID, anchor: anchor)
        case .object:
            return
        }
        try await image.store(subject, as: "o1", named: "self")
        try await image.runtime.release(subject)
        threads[chat.id]?.liveObjectIDs.insert("o1")
    }

    private func image(of chatID: UUID) async throws -> ObjectChatImage {
        ObjectChatImage(runtime: try await engine!.pharo.started(), chatID: chatID)
    }

    private func chat(_ chatID: UUID) -> ObjectChat {
        chat(withID: chatID)!
    }

    private func nextObjectID(in chatID: UUID) -> String {
        let suffix = me.map { ".\($0.id)" } ?? ""
        let numbers = thread(of: chatID).objects.compactMap { object -> Int? in
            guard object.objectID.hasSuffix(suffix), object.objectID.dropFirst().dropLast(suffix.count).allSatisfy(\.isNumber) else {
                return nil
            }
            return Int(object.objectID.dropFirst().dropLast(suffix.count))
        }
        return "o\(max(numbers.max() ?? 0, 1) + 1)\(suffix)"
    }

    private func nextMessageIndex(in chatID: UUID) -> Int {
        (thread(of: chatID).messages.map(\.index).max() ?? -1) + 1
    }

    private var me: Author? {
        (engine!.collaboration.localUser ?? engine!.gitHubAuth.currentUser).map(Self.author)
    }

    private func isMine(_ author: Author?) -> Bool {
        author == nil || author?.id == me?.id
    }

    private var labID: String? {
        engine!.collaboration.projectLabID
    }

    private func sessionID(of call: ObjectChatToolCall) -> UUID? {
        guard case .string(let text) = call.args["session_id"] else { return chat(withID: call.chatID)?.sessionID }
        return UUID(uuidString: text)
    }

    private var isLabOwner: Bool {
        engine!.collaboration.members.first { $0.user.id == me?.id }?.role == .owner
    }

    private func host(of sessionID: UUID) -> Author? {
        engine!.sessions.first { $0.id == sessionID }?.host.map(Self.author) ?? me
    }

    private static func author(_ user: CollaborationSession.UserInfo) -> Author {
        Author(id: user.id, name: user.name, avatarURL: user.avatarURL?.absoluteString ?? "")
    }

    private static func cut(_ text: String, to byteLimit: Int) -> String {
        DisplayTruncation.truncated(text, limit: byteLimit - 64)
    }
}

public struct ObjectChatProblem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case refusedByLab(opKind: String)
        case notSaved
    }

    public let id = UUID()
    public let kind: Kind
    public let chatID: UUID?
    public let messageID: UUID?
    public let reason: String
    public let date = Date()
}

public enum ObjectChatCallHold: Sendable, Equatable {
    case executorOffline
    case executorNoLongerHosts(currentHost: Author?)
    case sessionDetached
}

public enum ObjectChatError: Error, LocalizedError {
    case full(String, Int)
    case tooLong
    case notYours
    case conversationStays
    case gone
    case noSuchChat
    case noSuchObject(String)
    case noSuchView(String, among: [String])
    case notLiveHere(String, producedIn: String?, canRunAgain: Bool)

    public var errorDescription: String? {
        switch self {
        case .full(let what, let cap):
            "This chat holds \(cap) \(what), the most it keeps; start another chat."
        case .tooLong:
            "That is longer than a chat message may be."
        case .notYours:
            "Only its author, or a lab owner, may change that."
        case .conversationStays:
            "The project's conversation is kept for as long as the project."
        case .gone:
            "This chat was deleted in the lab; what you wrote was not sent."
        case .noSuchChat:
            "This chat is not in the project any more."
        case .noSuchObject(let objectID):
            "This chat holds no object \(objectID)."
        case .noSuchView(let view, let views):
            "No view \(view); it has \(views.joined(separator: ", "))."
        case .notLiveHere(let objectID, let producer, let canRunAgain):
            "\(objectID) is not live in this Luma: it was produced in \(producer.map { "\($0)'s Luma" } ?? "an earlier run of this Luma"). "
                + (canRunAgain ? "Run the call that produced it again here to rebuild it." : "Add it here as a live object first.")
        }
    }
}
