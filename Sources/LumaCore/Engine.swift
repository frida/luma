import Foundation
import Frida
import Observation
import SwiftyR2

public enum EngineError: Swift.Error, LocalizedError {
    case spawnedProcessNotFound(pid: UInt)

    public var errorDescription: String? {
        switch self {
        case .spawnedProcessNotFound(let pid):
            return "Spawned pid \(pid) not found"
        }
    }
}

@Observable
@MainActor
public final class Engine {
    public let deviceManager: DeviceManager
    public let systemParameters = SystemParametersCache()
    public let store: ProjectStore
    public let traces: TraceStore
    public let eventStore: EventStore?
    public let compilerWorkspace: CompilerWorkspace

    public private(set) var processNodes: [ProcessNode] = []
    private var drainServices: [String: SystemDrainService] = [:]
    public private(set) var descriptors: [InstrumentDescriptor] = []
    private var descriptorsByID: [String: InstrumentDescriptor] = [:]

    public let llmRegistry: LLMProviderRegistry
    public let llmCredentials: LLMCredentialStore
    public let missionTools: ToolCatalog
    public var imageProcessor: ImageProcessor?
    private let missionExecutor: MissionExecutor

    private var activeNoteReplyTasks: [UUID: Task<AddressNoteMessage?, Never>] = [:]
    private(set) public var noteReplyProgress: [UUID: NoteReplyProgress] = [:]
    private var missionLiveTextByID: [UUID: String] = [:]
    private var externalMissionLiveDeltaSink: (@MainActor (UUID, LLMTurnEvent) -> Void)?

    #if canImport(Network) || canImport(CSoup)
    private var activeMCPServersByMissionID: [UUID: MCPServer] = [:]

    public private(set) var externalMCPServer: MCPServer?
    public private(set) var externalMCPURL: URL?
    public private(set) var externalMCPMissionID: UUID?
    #endif

    private let _events = AsyncEventSource<RuntimeEvent>()
    public var events: AsyncStream<RuntimeEvent> { _events.makeStream() }

    private let _widgetUpdates = AsyncEventSource<WidgetUpdate>()
    public var widgetUpdates: AsyncStream<WidgetUpdate> { _widgetUpdates.makeStream() }
    private var widgetStates: [UUID: [String: WidgetState]] = [:]

    public let eventLog = EventLog()

    private var deviceEventTasks: [String: Task<Void, Never>] = [:]
    private var gatingEnabledDevices: Set<String> = []
    private var gatingIntendedDevices: Set<String> = []
    private var deviceChangeWatcher: Task<Void, Never>?
    private var eventLogTask: Task<Void, Never>?
    private var eventStoreFlushTail: Task<Void, Never> = Task {}

    public let hookPacks: HookPackLibrary
    public let customInstruments: CustomInstrumentLibrary

    @ObservationIgnored private var disassemblers: [UUID: Disassembler] = [:]
    @ObservationIgnored private var seekRestoredSessions: Set<UUID> = []
    @ObservationIgnored private var memoryReaders: [UUID: CachingMemoryReader] = [:]

    public let collaboration: CollaborationSession
    public let gitHubAuth: GitHubAuth
    public let dataDirectory: URL

    public private(set) var addressAnnotations: [UUID: [UInt64: AddressAnnotation]] = [:]
    public private(set) var tracerInstanceIDBySession: [UUID: UUID] = [:]
    public private(set) var sessions: [ProcessSession] = []
    public private(set) var notebookEntries: [NotebookEntry] = []
    public private(set) var instrumentsBySession: [UUID: [InstrumentInstance]] = [:]
    public private(set) var insightsBySession: [UUID: [AddressInsight]] = [:]
    public private(set) var tracesBySession: [UUID: [ITrace]] = [:]
    public private(set) var moduleAnalysisStatuses: [UUID: [String: ModuleAnalysisStatus]] = [:]
    public internal(set) var projectUIState: ProjectUIState = ProjectUIState()
    public internal(set) var sessionUIStates: [UUID: SessionUIState] = [:]
    public internal(set) var customInstrumentDefUIStates: [UUID: CustomInstrumentDefUIState] = [:]
    public private(set) var missions: [Mission] = []
    public private(set) var installedPackages: [InstalledPackage] = []
    public private(set) var editorFSSnapshot: EditorFSSnapshot?
    @ObservationIgnored public var editorFSSnapshotDirty: Bool = true
    @ObservationIgnored private var editorFSSnapshotVersion: Int = 0
    @ObservationIgnored private var cachedNodeModulesSnapshotFiles: [EditorFSSnapshotFile]?

    private var addressActionProviders: [AddressActionProvider] = []
    @ObservationIgnored private var protectionRegionsBySession: [UUID: [ProtectionRegion]] = [:]
    @ObservationIgnored private var unmappedPagesBySession: [UUID: Set<UInt64>] = [:]
    @ObservationIgnored private var mappingProbesBySession: [UUID: [UInt64: Task<AddressFacts.Mapping, Never>]] = [:]
    @ObservationIgnored private var functionStartsBySession: [UUID: [UInt64: Bool]] = [:]
    @ObservationIgnored private var factsIdentityBySession: [UUID: String] = [:]
    private var runningCustomInstrumentReloads: Set<UUID> = []
    private var pendingCustomInstrumentReloads: Set<UUID> = []
    private var customInstrumentReloadWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var threadActionProviders: [ThreadActionProvider] = []
    @ObservationIgnored public var onSessionListChanged: (@MainActor (SessionListChange) -> Void)?
    @ObservationIgnored public var onREPLCellAdded: (@MainActor (REPLCell) -> Void)?
    @ObservationIgnored public var onNotebookChanged: (@MainActor (NotebookChange) -> Void)?
    @ObservationIgnored public var onAddressNoteChanged: (@MainActor (AddressNoteChange) -> Void)?
    @ObservationIgnored public var onInstalledPackagesChanged: (@MainActor ([InstalledPackage]) -> Void)?
    @ObservationIgnored public var onUserNotification: (@MainActor (UserNotification) -> Void)?
    @ObservationIgnored public var onMissionsChanged: (@MainActor ([Mission]) -> Void)?
    @ObservationIgnored private var sessionsObservation: StoreObservation?
    @ObservationIgnored private var notebookObservation: StoreObservation?
    @ObservationIgnored private var instrumentsObservation: StoreObservation?
    @ObservationIgnored private var insightsObservation: StoreObservation?
    @ObservationIgnored private var tracesObservation: StoreObservation?
    @ObservationIgnored private var missionsObservation: StoreObservation?
    @ObservationIgnored private var lastUploadedTraceSize: [UUID: Int] = [:]
    @ObservationIgnored private let _traceCacheInvalidations = AsyncEventSource<TraceCacheInvalidation>()
    public var traceCacheInvalidations: AsyncStream<TraceCacheInvalidation> { _traceCacheInvalidations.makeStream() }

    public struct TraceCacheInvalidation: Sendable {
        public let traceID: UUID
        public let knownTotalSize: Int
    }
    private static let traceDataPageSize: Int = 1 * 1024 * 1024
    @ObservationIgnored private var packagesObservation: StoreObservation?

    public init(
        store: ProjectStore,
        traces: TraceStore,
        eventStore: EventStore? = nil,
        dataDirectory: URL,
        tokenStore: TokenStore? = nil,
        gitHubAuth: GitHubAuth? = nil,
        deviceManager: DeviceManager = .shared
    ) {
        self.deviceManager = deviceManager
        self.store = store
        self.traces = traces
        self.eventStore = eventStore
        self.dataDirectory = dataDirectory
        self.compilerWorkspace = CompilerWorkspace(store: store)
        let hookPacksDir = dataDirectory.appendingPathComponent("HookPacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hookPacksDir, withIntermediateDirectories: true)
        self.hookPacks = HookPackLibrary(directory: hookPacksDir)
        self.customInstruments = CustomInstrumentLibrary()
        self.collaboration = CollaborationSession(
            deviceManager: deviceManager,
            store: store,
            portalAddress: BackendConfig.portalAddress,
            portalCertificate: BackendConfig.certificate
        )

        let resolvedTokenStore = tokenStore ?? defaultTokenStore(dataDirectory: dataDirectory)

        if let gitHubAuth {
            self.gitHubAuth = gitHubAuth
        } else {
            self.gitHubAuth = GitHubAuth(tokenStore: resolvedTokenStore)
        }

        let registry = LLMProviderRegistry()
        let credentials = LLMCredentialStore(backing: resolvedTokenStore)
        let catalog = ToolCatalog()
        self.llmRegistry = registry
        self.llmCredentials = credentials
        self.missionTools = catalog
        self.missionExecutor = MissionExecutor(
            store: store,
            registry: registry,
            credentials: credentials,
            catalog: catalog,
            collaboration: collaboration,
            systemPromptBuilder: { mission in
                MissionSystemPrompt.build(for: mission)
            }
        )

        registerDescriptor(Self.tracerDescriptor)
        for desc in hookPacks.descriptors() {
            registerDescriptor(desc)
        }
        customInstruments.start(store: store)
        for desc in customInstruments.descriptors() {
            registerDescriptor(desc)
        }
        customInstruments.observers.append { [weak self] in
            self?.refreshCustomInstrumentDescriptors()
        }
        bindCollaborationCallbacks()
        missionExecutor.liveDeltaSink = { [weak self] missionID, event in
            self?.handleMissionLiveEvent(missionID: missionID, event: event)
        }

        registerAddressActionProvider { [weak self] sessionID, address, context, facts in
            self?.tracerAddressActions(sessionID: sessionID, address: address, context: context, facts: facts) ?? []
        }

        registerThreadActionProvider { [weak self] sessionID, thread in
            self?.threadTraceActions(sessionID: sessionID, thread: thread) ?? []
        }

        Task { @MainActor [auth = self.gitHubAuth] in
            await auth.loadPersistedToken()
        }

        APNsRegistration.shared.observe { [weak self] _ in
            self?.syncAPNsSubscription()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await status in self.collaboration.statusChanges {
                if case .joined = status {
                    self.syncAPNsSubscription()
                    self.lastUploadedTraceSize.removeAll()
                }
            }
        }

        eventLogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self._events.makeStream() {
                self.eventLog.append(event)
            }
        }

        if let eventStore {
            eventLog.onEventsToPersist = { [weak self] batch in
                guard let self else { return }
                let previous = self.eventStoreFlushTail
                self.eventStoreFlushTail = Task {
                    await previous.value
                    await eventStore.append(batch)
                }
            }
        }

        #if os(macOS) || os(Linux) || os(Windows)
        llmRegistry.register(ClaudeCodeProvider(engine: self))
        #endif
        llmRegistry.register(AnthropicProvider())
        llmRegistry.register(OpenAIProvider())
        llmRegistry.register(OpenAICompatibleProvider.local())
        llmRegistry.register(OpenAICompatibleProvider.remote())
        MissionTools.registerStandard(in: missionTools, engine: self)
        missionsObservation = store.observeMissions { [weak self] missions in
            Task { @MainActor in
                guard let self else { return }
                self.missions = missions
                self.onMissionsChanged?(missions)
            }
        }
        hookPacks.onError = { [weak self] message in
            self?.emitEngineError(subsystem: "hookpacks", text: message)
        }
        hookPacks.reload()
    }

    private func syncAPNsSubscription() {
        guard case .joined = collaboration.status else { return }
        guard let token = APNsRegistration.shared.deviceTokenHex else { return }
        collaboration.registerPushSubscriptions([[
            "platform": "apns",
            "endpoint": token,
            "environment": APNsRegistration.environment,
        ]])
    }

    // MARK: - Collaboration

    public func startCollaboration(joiningLab labID: String? = nil) {
        let existing = labID ?? (try? store.fetchCollaborationState())?.labID
        Task { @MainActor in
            guard let token = await gitHubAuth.requestToken() else { return }
            await collaboration.start(token: token, existingLabID: existing)
        }
    }

    public func signOut() async {
        await gitHubAuth.signOut()
        await collaboration.stop()
    }

    /// Ask the portal for a one-time enrollment token and build the URL the
    /// user should open in their default browser to allow Web Push
    /// notifications. The token is single-use with a five-minute lifetime
    /// (enforced server-side) so it's safe to stash in the URL fragment.
    public func webPushEnrollmentURL() async throws -> URL {
        let ticket = try await collaboration.requestPushEnrollmentToken()
        guard var components = URLComponents(string: BackendConfig.pushEnrollURL) else {
            throw URLError(.badURL)
        }
        components.fragment = "token=\(ticket.token)&vapid=\(ticket.vapidPublicKey)"
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    // MARK: - Notebook Operations

    /// Spacing between consecutive `position` values assigned locally. The
    /// server stamps definitive values on echo; this is just enough slack
    /// so a drag-between-neighbors computes a non-degenerate midpoint.
    private static let notebookPositionStep: Double = 1000

    public func addNotebookEntry(_ entry: NotebookEntry, after otherEntry: NotebookEntry? = nil) {
        var e = entry
        if let otherEntry {
            e.timestamp = otherEntry.timestamp.addingTimeInterval(0.001)
        }
        if e.position == 0 {
            let maxPos = (try? store.maxNotebookEntryPosition()) ?? 0
            e.position = maxPos + Self.notebookPositionStep
        }
        try? store.save(e)
        notebookEntries.append(e)
        onNotebookChanged?(.added(e))
        collaboration.enqueueAdd(e)
    }

    public func updateNotebookEntry(_ entry: NotebookEntry) {
        try? store.save(entry)
        if let i = notebookEntries.firstIndex(where: { $0.id == entry.id }) {
            notebookEntries[i] = entry
        }
        onNotebookChanged?(.updated(entry))
        collaboration.enqueueUpdate(
            entryID: entry.id,
            title: entry.title,
            details: entry.details,
            processName: entry.processName
        )
    }

    public func deleteNotebookEntry(_ entry: NotebookEntry) {
        try? store.deleteNotebookEntry(id: entry.id)
        notebookEntries.removeAll { $0.id == entry.id }
        onNotebookChanged?(.removed(entry.id))
        collaboration.enqueueRemove(entryID: entry.id)
    }

    // MARK: - Address Notes

    public func createAddressNote(
        sessionID: UUID,
        address: UInt64,
        title: String? = nil
    ) -> AddressNote? {
        guard let node = node(forSessionID: sessionID) else { return nil }
        let anchor = node.anchor(for: address)
        let note = AddressNote(sessionID: sessionID, anchor: anchor, title: title)
        try? store.save(note)
        rebuildAddressAnnotations(sessionID: sessionID)
        onAddressNoteChanged?(.noteAdded(note))
        collaboration.enqueueAddressNoteUpsert(note)
        return note
    }

    public func updateAddressNote(_ note: AddressNote) {
        var updated = note
        updated.updatedAt = Date()
        try? store.save(updated)
        onAddressNoteChanged?(.noteUpdated(updated))
        collaboration.enqueueAddressNoteUpsert(updated)
    }

    public func deleteAddressNote(_ note: AddressNote) {
        try? store.deleteAddressNote(id: note.id)
        rebuildAddressAnnotations(sessionID: note.sessionID)
        onAddressNoteChanged?(.noteRemoved(note))
        collaboration.enqueueAddressNoteRemove(noteID: note.id)
    }

    public func appendUserMessage(noteID: UUID, body: String) -> AddressNoteMessage? {
        guard let note = try? store.fetchAddressNote(id: noteID) else { return nil }
        let existing = (try? store.fetchAddressNoteMessages(noteID: noteID)) ?? []
        let nextIndex = (existing.last?.index ?? -1) + 1
        let message = AddressNoteMessage(
            noteID: noteID,
            index: nextIndex,
            role: .user,
            bodyMarkdown: body
        )
        try? store.save(message)
        bumpNoteUpdatedAt(note)
        onAddressNoteChanged?(.messageAppended(message))
        collaboration.enqueueAddressNoteMessageAppend(message)
        return message
    }

    public func deleteAddressNoteMessage(_ message: AddressNoteMessage) {
        try? store.deleteAddressNoteMessage(id: message.id)
        if let note = try? store.fetchAddressNote(id: message.noteID) {
            bumpNoteUpdatedAt(note)
        }
        onAddressNoteChanged?(.messageRemoved(message))
        collaboration.enqueueAddressNoteMessageRemove(noteID: message.noteID, messageID: message.id)
    }

    public func editUserMessage(noteID: UUID, messageID: UUID, body: String) -> AddressNoteMessage? {
        guard var message = try? store.fetchAddressNoteMessage(id: messageID),
            message.noteID == noteID,
            message.role == .user
        else { return nil }
        message.bodyMarkdown = body
        try? store.save(message)
        if let note = try? store.fetchAddressNote(id: noteID) {
            bumpNoteUpdatedAt(note)
        }
        onAddressNoteChanged?(.messageEdited(message))
        collaboration.enqueueAddressNoteMessageEdit(noteID: noteID, messageID: messageID, bodyMarkdown: body)
        return message
    }

    public func addressNotes(sessionID: UUID, anchor: AddressAnchor? = nil) -> [AddressNote] {
        let all = (try? store.fetchAddressNotes(sessionID: sessionID)) ?? []
        guard let anchor else { return all }
        return all.filter { $0.anchor == anchor }
    }

    public func addressNoteMessages(noteID: UUID) -> [AddressNoteMessage] {
        (try? store.fetchAddressNoteMessages(noteID: noteID)) ?? []
    }

    private func bumpNoteUpdatedAt(_ note: AddressNote) {
        var updated = note
        updated.updatedAt = Date()
        try? store.save(updated)
    }

    public struct NoteReplyProgress: Equatable {
        public let noteID: UUID
        public var text: String
    }

    public func requestAIReply(
        noteID: UUID,
        providerID: String,
        modelID: String,
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async -> AddressNoteMessage? {
        guard let sessionID = (try? store.fetchAddressNote(id: noteID))?.sessionID else { return nil }
        activeNoteReplyTasks[sessionID]?.cancel()
        let task = Task<AddressNoteMessage?, Never> { @MainActor [weak self] in
            await self?.runNoteReply(noteID: noteID, providerID: providerID, modelID: modelID, onDelta: onDelta) ?? nil
        }
        activeNoteReplyTasks[sessionID] = task
        let reply = await task.value
        if activeNoteReplyTasks[sessionID] == task {
            activeNoteReplyTasks.removeValue(forKey: sessionID)
        }
        return reply
    }

    private func runNoteReply(
        noteID: UUID,
        providerID: String,
        modelID: String,
        onDelta: (@MainActor (String) -> Void)?
    ) async -> AddressNoteMessage? {
        guard let note = try? store.fetchAddressNote(id: noteID),
            let provider = llmRegistry.provider(id: providerID)
        else { return nil }

        let thread = (try? store.fetchAddressNoteMessages(noteID: noteID)) ?? []
        guard !thread.isEmpty else { return nil }

        noteReplyProgress[note.sessionID] = NoteReplyProgress(noteID: noteID, text: "")
        defer { noteReplyProgress.removeValue(forKey: note.sessionID) }
        let liveDelta: @MainActor (String) -> Void = { [weak self] delta in
            self?.noteReplyProgress[note.sessionID]?.text += delta
            onDelta?(delta)
        }

        let mission = getOrCreateAmbientMission(
            sessionID: note.sessionID,
            providerID: providerID,
            modelID: modelID
        )
        guard let mission else { return nil }

        let system = await buildAddressNoteSystemPrompt(note: note)
        var messages = thread.map { msg -> LLMMessage in
            let role: LLMRole = (msg.role == .assistant) ? .assistant : .user
            return LLMMessage(role: role, blocks: [.text(msg.bodyMarkdown)])
        }

        let toolCallID = "n\(thread.count)"
        let argsJSON: String = {
            let payload: [String: Any] = [
                "note_id": noteID.uuidString,
                "address_anchor": note.anchor.displayString,
                "thread_length": thread.count,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"
        }()

        var action = MissionAction(
            missionID: mission.id,
            turnID: nil,
            toolName: "address_note_reply",
            argsJSON: argsJSON,
            isObserve: true,
            sessionID: note.sessionID,
            toolCallID: toolCallID
        )
        action.status = .running
        action.decidedAt = Date()
        try? store.save(action)
        collaboration.enqueueMissionAction(action)

        let apiKey = (try? await llmCredentials.apiKey(providerID: providerID)) ?? nil
        if provider.descriptor.capabilities.supports(.apiKey), apiKey == nil {
            action.status = .failed
            action.error = "missing API key for provider \(providerID)"
            action.completedAt = Date()
            try? store.save(action)
            collaboration.enqueueMissionAction(action)
            return nil
        }

        let tools = noteTurnToolSpecs()
        let baseURL = LumaAppState.shared.providerBaseURL(providerID: providerID).flatMap(URL.init(string:))
        var responseText = ""
        var usage = LLMUsage.zero
        var iterationsRemaining = Self.noteTurnMaxIterations
        do {
            iterationLoop: while iterationsRemaining > 0 {
                iterationsRemaining -= 1
                if Task.isCancelled { throw CancellationError() }
                let request = LLMTurnRequest(
                    modelID: modelID,
                    systemBlocks: [LLMContentBlock(content: .text(system), cacheBoundary: true)],
                    messages: messages,
                    tools: tools,
                    maxOutputTokens: 1024,
                    thinkingBudget: 0,
                    temperature: 0.3,
                    mission: mission
                )

                let outcome = await streamNoteTurn(
                    provider: provider,
                    request: request,
                    apiKey: apiKey,
                    baseURL: baseURL,
                    onDelta: liveDelta
                )
                responseText += outcome.text
                usage.inputTokens += outcome.usage.inputTokens
                usage.outputTokens += outcome.usage.outputTokens
                usage.cacheReadTokens += outcome.usage.cacheReadTokens
                usage.cacheCreateTokens += outcome.usage.cacheCreateTokens

                if let error = outcome.error { throw error }

                let toolUses = outcome.blocks.filter {
                    if case .toolUse = $0.content { return true }
                    return false
                }
                if toolUses.isEmpty { break iterationLoop }

                messages.append(LLMMessage(role: .assistant, blocks: outcome.blocks))
                let resultBlocks = await runNoteToolUses(
                    toolUses,
                    sessionID: note.sessionID,
                    mission: mission
                )
                messages.append(LLMMessage(role: .user, blocks: resultBlocks))
            }
        } catch {
            action.status = .failed
            action.error = (error is CancellationError) ? "Reply cancelled by user." : error.localizedDescription
            action.completedAt = Date()
            try? store.save(action)
            collaboration.enqueueMissionAction(action)
            return nil
        }

        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            action.status = .failed
            action.error = "model returned empty response"
            action.completedAt = Date()
            try? store.save(action)
            collaboration.enqueueMissionAction(action)
            return nil
        }

        action.status = .succeeded
        action.resultJSON = trimmed
        action.resultSummary = String(trimmed.prefix(120))
        action.completedAt = Date()
        try? store.save(action)
        collaboration.enqueueMissionAction(action)

        var updatedMission = mission
        updatedMission.tokensUsedInput += usage.inputTokens
        updatedMission.tokensUsedOutput += usage.outputTokens
        updatedMission.cacheReadTokens += usage.cacheReadTokens
        updatedMission.cacheCreateTokens += usage.cacheCreateTokens
        updatedMission.updatedAt = Date()
        try? store.save(updatedMission)
        collaboration.enqueueMissionUpsert(updatedMission)

        let nextIndex = (thread.last?.index ?? -1) + 1
        let message = AddressNoteMessage(
            noteID: noteID,
            index: nextIndex,
            role: .assistant,
            bodyMarkdown: trimmed,
            providerID: providerID,
            modelID: modelID,
            actionID: action.id
        )
        try? store.save(message)
        bumpNoteUpdatedAt(note)
        onAddressNoteChanged?(.messageAppended(message))
        collaboration.enqueueAddressNoteMessageAppend(message)
        return message
    }

    private func getOrCreateAmbientMission(
        sessionID: UUID,
        providerID: String,
        modelID: String
    ) -> Mission? {
        var state = sessionUIStates[sessionID] ?? SessionUIState(sessionID: sessionID)
        if let existingID = state.ambientMissionID,
            let mission = try? store.fetchMission(id: existingID)
        {
            return mission
        }

        var mission = Mission(
            goalText: "Address notes for this session.",
            providerID: providerID,
            modelID: modelID,
            tokenBudgetInput: 0,
            tokenBudgetOutput: 0
        )
        mission.title = "Ambient — address notes"
        mission.status = .running
        try? store.save(mission)
        collaboration.enqueueMissionUpsert(mission)

        state.ambientMissionID = mission.id
        sessionUIStates[sessionID] = state
        try? store.save(state)
        return mission
    }

    public func ambientMissionID(sessionID: UUID) -> UUID? {
        sessionUIStates[sessionID]?.ambientMissionID
    }

    public func isAmbientMission(_ missionID: UUID) -> Bool {
        sessionUIStates.values.contains { $0.ambientMissionID == missionID }
    }

    private static let noteTurnMaxIterations = 6

    private func noteTurnToolSpecs() -> [LLMToolSpec] {
        missionExecutor.catalog.toolSpecs()
    }

    private struct NoteTurnOutcome {
        var blocks: [LLMContentBlock]
        var text: String
        var usage: LLMUsage
        var error: (any Swift.Error)?
    }

    private func streamNoteTurn(
        provider: any LLMProvider,
        request: LLMTurnRequest,
        apiKey: String?,
        baseURL: URL?,
        onDelta: (@MainActor (String) -> Void)?
    ) async -> NoteTurnOutcome {
        var blocks: [LLMContentBlock] = []
        var streamedText = ""
        var usage = LLMUsage.zero
        var capturedError: (any Swift.Error)?

        do {
            for try await event in provider.streamTurn(request, apiKey: apiKey, baseURL: baseURL) {
                switch event {
                case .textDelta(let delta):
                    streamedText += delta
                    onDelta?(delta)
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

        return NoteTurnOutcome(blocks: blocks, text: textForLoop, usage: usage, error: capturedError)
    }

    private func runNoteToolUses(
        _ blocks: [LLMContentBlock],
        sessionID: UUID,
        mission: Mission
    ) async -> [LLMContentBlock] {
        var results: [LLMContentBlock] = []
        for block in blocks {
            guard case .toolUse(let id, let name, let inputJSON) = block.content else { continue }
            let (json, isError) = await runNoteToolUse(
                name: name,
                inputJSON: inputJSON,
                toolCallID: id,
                sessionID: sessionID,
                mission: mission
            )
            results.append(LLMContentBlock(content: .toolResult(
                toolUseID: id,
                contentJSON: json,
                isError: isError,
                attachments: []
            )))
        }
        return results
    }

    private func runNoteToolUse(
        name: String,
        inputJSON: String,
        toolCallID: String,
        sessionID: UUID,
        mission: Mission
    ) async -> (json: String, isError: Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        let spec = missionExecutor.catalog.spec(named: name)

        if spec?.isObserve == true {
            let invocation = ActionInvocation(args: args, mission: mission, sessionID: sessionID, toolCallID: toolCallID)
            do {
                let result = try await missionExecutor.catalog.execute(name, invocation: invocation)
                return (result.resultJSON, result.isError)
            } catch {
                return (#"{"error": "\#(error.localizedDescription)"}"#, true)
            }
        }

        let action = MissionAction(
            missionID: mission.id,
            turnID: nil,
            toolName: name,
            argsJSON: inputJSON,
            isObserve: false,
            sessionID: sessionID,
            toolCallID: toolCallID
        )
        try? store.save(action)
        collaboration.enqueueMissionAction(action)

        let completed = await awaitActionTerminalStatus(actionID: action.id, missionID: mission.id)
        return noteToolResultPayload(for: completed)
    }

    private func awaitActionTerminalStatus(actionID: UUID, missionID: UUID) async -> MissionAction {
        if let cached = try? store.fetchMissionAction(id: actionID), isTerminal(cached.status) {
            return cached
        }
        let (stream, continuation) = AsyncStream.makeStream(of: MissionAction.self)
        let observation = store.observeMissionActions(missionID: missionID) { rows in
            if let action = rows.first(where: { $0.id == actionID }) {
                continuation.yield(action)
            }
        }
        let settled: MissionAction? = await withTaskCancellationHandler {
            var result: MissionAction?
            for await action in stream {
                if isTerminal(action.status) {
                    result = action
                    break
                }
            }
            continuation.finish()
            _ = observation
            return result
        } onCancel: {
            continuation.finish()
        }
        return settled ?? (try? store.fetchMissionAction(id: actionID)) ?? MissionAction(
            missionID: missionID,
            turnID: nil,
            toolName: "",
            argsJSON: "{}",
            isObserve: false,
            sessionID: nil
        )
    }

    private func isTerminal(_ status: MissionActionStatus) -> Bool {
        switch status {
        case .succeeded, .failed, .rejected: return true
        default: return false
        }
    }

    private func noteToolResultPayload(for action: MissionAction) -> (json: String, isError: Bool) {
        switch action.status {
        case .rejected:
            let reason = action.rejectionReason ?? "User declined to run this tool."
            return (#"{"error": "\#(reason)"}"#, true)
        case .failed:
            return (action.resultJSON ?? #"{"error": "\#(action.error ?? "failed")"}"#, true)
        case .succeeded:
            return (action.resultJSON ?? "{}", false)
        default:
            return (#"{"error": "no result"}"#, true)
        }
    }

    private func buildAddressNoteSystemPrompt(note: AddressNote) async -> String {
        var lines = [
            "You are an interactive reverse-engineering assistant pinned to one address. Be specific and concise. Lead with the conclusion; cite registers/strings/calls when relevant.",
            "You may call any tool. Observe (read-only) and auto-run tools execute immediately. Approval-gated tools queue in the global Action Queue popover and the user must approve them; your reply pauses until each one settles, so propose mutations only when they're clearly warranted, and always say in plain text what you're about to do before the call.",
            "Anchor: \(note.anchor.displayString)",
            "Session: \(note.sessionID.uuidString) — pass this as `session_id` to tools that require it.",
            "",
            MissionSystemPrompt.codeStyle,
        ]
        if let dis = disassembler(forSessionID: note.sessionID),
            let node = node(forSessionID: note.sessionID),
            let address = try? node.resolveSyncIfReady(note.anchor)
        {
            let matchingInsights = (insightsBySession[note.sessionID] ?? []).filter {
                $0.lastResolvedAddress == address
            }
            let named = matchingInsights.first(where: { hasUserTitle($0) }) ?? matchingInsights.first
            if let named {
                lines.append("Insight: \"\(displayTitle(for: named))\" — refer to this address by that name.")
            }
            let lines64 = await dis.disassemble(DisassemblyRequest(address: address, count: 32, appearance: .light))
            let disasm = lines64.map {
                String(format: "0x%llx", $0.address) + "  " + $0.asmText.plainText
            }.joined(separator: "\n")
            let pdc = await dis.decompile(at: address).output ?? ""
            lines.append("")
            lines.append("Disassembly window:")
            lines.append(disasm)
            lines.append("")
            lines.append("Pseudo-C:")
            lines.append(pdc)
        }
        return lines.joined(separator: "\n")
    }

    /// Move `entry` into the slot between `previous` and `next` (either may
    /// be nil to mean "no neighbor on that side"). Computes a position as
    /// the midpoint of the two neighbors' positions; if the slot is at an
    /// edge, extends beyond by a single step.
    public func reorderNotebookEntry(
        _ entry: NotebookEntry,
        between previous: NotebookEntry?,
        and next: NotebookEntry?
    ) {
        let position: Double
        switch (previous?.position, next?.position) {
        case let (p?, n?):
            position = (p + n) / 2
        case let (p?, nil):
            position = p + Self.notebookPositionStep
        case let (nil, n?):
            position = n - Self.notebookPositionStep
        case (nil, nil):
            position = Self.notebookPositionStep
        }

        var updated = entry
        updated.position = position
        try? store.save(updated)
        if let i = notebookEntries.firstIndex(where: { $0.id == entry.id }) {
            notebookEntries[i] = updated
        }
        onNotebookChanged?(.reordered)
        collaboration.enqueueReorder(entryID: entry.id, position: position)
    }

    public func bindCollaborationCallbacks() {
        collaboration.onAuthRejected = { [weak self] _ in
            await self?.gitHubAuth.signOut()
        }

        collaboration.onCustomInstrumentOpReceived = { [weak self] op in
            guard let self else { return }
            switch op {
            case .upsert(let u):
                guard var bundle = try? Self.validatedCustomInstrumentBundle(u.bundle) else { return }
                bundle.def.normalize()
                try? self.store.save(bundle.def)
                try? self.store.replaceCustomInstrumentFiles(defID: bundle.def.id, files: bundle.files)
                self.scheduleCustomInstrumentReload(defID: bundle.def.id)
            case .remove(let r):
                try? self.store.deleteCustomInstrumentDef(id: r.defID)
            }
        }

        collaboration.onMissionOpReceived = { [weak self] op in
            self?.applyRemoteMissionOp(op)
        }

        collaboration.onAddressNoteOpReceived = { [weak self] op in
            self?.applyRemoteAddressNoteOp(op)
        }

        collaboration.onMissionSnapshot = { [weak self] snapshot in
            self?.applyRemoteMissionSnapshot(snapshot)
        }

        collaboration.onCustomInstrumentSnapshot = { [weak self] bundles in
            guard let self else { return }
            let serverIDs = Set(bundles.map(\.def.id))
            let local = (try? self.store.fetchCustomInstrumentDefs()) ?? []
            for stale in local where !serverIDs.contains(stale.id) {
                try? self.store.deleteCustomInstrumentDef(id: stale.id)
            }
            let normalized = bundles.map { bundle -> CustomInstrumentBundle in
                var copy = bundle
                copy.def.normalize()
                return copy
            }
            for bundle in normalized {
                try? self.store.save(bundle.def)
                try? self.store.replaceCustomInstrumentFiles(defID: bundle.def.id, files: bundle.files)
            }
            for bundle in normalized {
                self.scheduleCustomInstrumentReload(defID: bundle.def.id)
            }
        }

        collaboration.onNotebookSnapshot = { [weak self] entries in
            guard let self else { return }
            // Snapshot is authoritative: replace local state with it. Any
            // locally-made mutations that aren't reflected here still live
            // in the outbox and will replay once status flips to .joined.
            let existingIDs = self.notebookEntries.map(\.id)
            for id in existingIDs {
                try? self.store.deleteNotebookEntry(id: id)
            }
            self.notebookEntries.removeAll()
            for entry in entries {
                try? self.store.save(entry)
                self.notebookEntries.append(entry)
            }
            self.onNotebookChanged?(.snapshot(entries))
        }

        collaboration.onEntryUpserted = { [weak self] entry in
            guard let self else { return }
            let existed = (try? self.store.fetchNotebookEntry(id: entry.id)) != nil
            try? self.store.save(entry)
            if let i = self.notebookEntries.firstIndex(where: { $0.id == entry.id }) {
                self.notebookEntries[i] = entry
            } else {
                self.notebookEntries.append(entry)
            }
            self.onNotebookChanged?(existed ? .updated(entry) : .added(entry))
        }

        collaboration.onEntryRemoved = { [weak self] id in
            try? self?.store.deleteNotebookEntry(id: id)
            self?.notebookEntries.removeAll { $0.id == id }
            self?.onNotebookChanged?(.removed(id))
        }

        collaboration.onEntryRepositioned = { [weak self] id, position in
            guard let self else { return }
            guard var existing = try? self.store.fetchNotebookEntry(id: id) else { return }
            existing.position = position
            try? self.store.save(existing)
            if let i = self.notebookEntries.firstIndex(where: { $0.id == id }) {
                self.notebookEntries[i] = existing
            }
            self.onNotebookChanged?(.reordered)
        }

        collaboration.onSessionsSnapshot = { [weak self] sessions in
            guard let self else { return }
            self.applySessionsSnapshot(sessions)
        }

        collaboration.onSessionAdded = { [weak self] session in
            self?.adoptRemoteSession(session)
        }

        collaboration.onSessionPhaseChanged = { [weak self] sessionID, phase, reason in
            self?.applyRemoteSessionPhase(sessionID: sessionID, phase: phase, reason: reason)
        }

        collaboration.onSessionArmingChanged = { [weak self] sessionID, armingState in
            self?.applyRemoteSessionArming(sessionID: sessionID, armingState: armingState)
        }

        collaboration.onSessionModulesUpdated = { [weak self] sessionID, delta in
            self?.applyRemoteSessionModules(sessionID: sessionID, delta: delta)
        }

        collaboration.onSessionThreadsUpdated = { [weak self] sessionID, delta in
            self?.applyRemoteSessionThreads(sessionID: sessionID, delta: delta)
        }

        collaboration.onSessionHostChanged = { [weak self] sessionID, host, deviceID, deviceName, pid, processName in
            self?.applyRemoteSessionHostChange(
                sessionID: sessionID,
                host: host,
                deviceID: deviceID,
                deviceName: deviceName,
                pid: pid,
                processName: processName
            )
        }

        collaboration.onSessionReplCellAdded = { [weak self] sessionID, cell in
            self?.applyRemoteSessionReplCell(sessionID: sessionID, cell: cell)
        }

        collaboration.onSessionReplEvalRequested = { [weak self] sessionID, code, language, cellID in
            self?.handleRemoteReplEvalRequest(sessionID: sessionID, code: code, language: language, cellID: cellID)
        }

        collaboration.onSessionInstrumentAdded = { [weak self] sessionID, instance in
            self?.applyRemoteSessionInstrumentAdded(sessionID: sessionID, instance: instance)
        }

        collaboration.onSessionInstrumentUpdated = { [weak self] sessionID, instance in
            self?.applyRemoteSessionInstrumentUpdated(sessionID: sessionID, instance: instance)
        }

        collaboration.onSessionInstrumentRemoved = { [weak self] sessionID, instanceID in
            self?.applyRemoteSessionInstrumentRemoved(sessionID: sessionID, instanceID: instanceID)
        }

        collaboration.onSessionInstrumentSetStateRequested = { [weak self] sessionID, instanceID, state in
            self?.handleRemoteInstrumentSetStateRequest(sessionID: sessionID, instanceID: instanceID, state: state)
        }

        collaboration.onSessionInstrumentRemoveRequested = { [weak self] sessionID, instanceID in
            self?.handleRemoteInstrumentRemoveRequest(sessionID: sessionID, instanceID: instanceID)
        }

        collaboration.onSessionInstrumentAddRequested = { [weak self] sessionID, kind, sourceIdentifier, configJSON in
            self?.handleRemoteInstrumentAddRequest(
                sessionID: sessionID,
                kind: kind,
                sourceIdentifier: sourceIdentifier,
                configJSON: configJSON
            )
        }

        collaboration.onSessionInstrumentUpdateConfigRequested = { [weak self] sessionID, instanceID, configJSON in
            self?.handleRemoteInstrumentUpdateConfigRequest(sessionID: sessionID, instanceID: instanceID, configJSON: configJSON)
        }

        collaboration.onSessionInsightAdded = { [weak self] sessionID, insight in
            self?.applyRemoteSessionInsightAdded(sessionID: sessionID, insight: insight)
        }

        collaboration.onSessionInsightUpdated = { [weak self] sessionID, insight in
            self?.applyRemoteSessionInsightUpdated(sessionID: sessionID, insight: insight)
        }

        collaboration.onSessionInsightRemoved = { [weak self] sessionID, insightID in
            self?.applyRemoteSessionInsightRemoved(sessionID: sessionID, insightID: insightID)
        }

        collaboration.onSessionProcessInfoUpdated = { [weak self] sessionID, info in
            self?.applyRemoteSessionProcessInfo(sessionID: sessionID, info: info)
        }

        collaboration.onSessionModuleAnalysisUpdated = { [weak self] sessionID, analysis in
            self?.applyRemoteSessionModuleAnalysis(sessionID: sessionID, analysis: analysis)
        }

        collaboration.onSessionModuleSymbolsUpdated = { [weak self] sessionID, entries in
            self?.applyRemoteSessionModuleSymbols(sessionID: sessionID, entries: entries)
        }

        collaboration.onSessionTraceUpserted = { [weak self] sessionID, trace in
            self?.applyRemoteSessionTraceUpserted(sessionID: sessionID, trace: trace)
        }

        collaboration.onSessionTraceRemoved = { [weak self] sessionID, traceID in
            self?.applyRemoteSessionTraceRemoved(sessionID: sessionID, traceID: traceID)
        }

        collaboration.onSessionTraceDataProgressed = { [weak self] sessionID, traceID, totalSize in
            self?.applyRemoteTraceDataProgressed(sessionID: sessionID, traceID: traceID, totalSize: totalSize)
        }

        collaboration.onSessionEventReceived = { [weak self] sessionID, event in
            self?.applyRemoteSessionEvent(sessionID: sessionID, event: event)
        }

        collaboration.onSessionWidgetUpdateReceived = { [weak self] sessionID, update in
            self?.applyWidgetUpdate(update, sessionID: sessionID, origin: .remote)
        }

        collaboration.onSessionWidgetActionRequested = { [weak self] sessionID, instanceID, widget, action, item in
            self?.handleRemoteWidgetActionRequest(
                sessionID: sessionID,
                instanceID: instanceID,
                widget: widget,
                action: action,
                item: item
            )
        }

        collaboration.onWidgetStatesSnapshot = { [weak self] snapshots in
            self?.applyWidgetStateSnapshots(snapshots)
        }

        collaboration.onReplEvalTimedOut = { [weak self] cellID in
            self?.markReplCellTimedOut(cellID: cellID)
        }

        collaboration.onSessionRemoved = { [weak self] sessionID in
            self?.applyRemoteSessionRemoval(sessionID: sessionID)
        }
    }

    private func markReplCellTimedOut(cellID: UUID) {
        guard let cell = try? store.fetchREPLCell(id: cellID),
            case .text(let text) = cell.result,
            text == "Running…"
        else { return }
        var updated = cell
        updated.result = .text("Timed out — host did not respond.")
        try? store.save(updated)
        onREPLCellAdded?(updated)
    }

    private func applyRemoteSessionEvent(sessionID: UUID, event: RuntimeEvent) {
        var stamped = event
        stamped.sessionID = sessionID
        _events.yield(stamped)
    }

    private func applyRemoteSessionTraceUpserted(sessionID: UUID, trace: ITrace) {
        var stored = trace
        stored.sessionID = sessionID
        try? store.save(stored)
        onSessionListChanged?(.traceUpdated(stored))
    }

    private func applyRemoteSessionTraceRemoved(sessionID: UUID, traceID: UUID) {
        try? store.deleteITrace(id: traceID)
        traces.delete(traceID: traceID)
        onSessionListChanged?(.traceRemoved(id: traceID, sessionID: sessionID))
    }

    private func applyRemoteTraceDataProgressed(sessionID: UUID, traceID: UUID, totalSize: Int) {
        let cachedSize = traces.size(traceID: traceID) ?? 0
        guard cachedSize < totalSize else { return }
        _traceCacheInvalidations.yield(TraceCacheInvalidation(traceID: traceID, knownTotalSize: totalSize))
    }

    private func applyRemoteSessionInsightAdded(sessionID: UUID, insight: AddressInsight) {
        var stored = insight
        stored.sessionID = sessionID
        persistInsight(stored)
        onSessionListChanged?(.insightAdded(stored))
    }

    private func applyRemoteSessionInsightUpdated(sessionID: UUID, insight: AddressInsight) {
        var stored = insight
        stored.sessionID = sessionID
        persistInsight(stored)
        applyInsightNameToR2(stored)
        emitInsightUpdated(stored)
    }

    private func applyRemoteSessionInsightRemoved(sessionID: UUID, insightID: UUID) {
        try? store.deleteInsight(id: insightID)
        for (sid, list) in insightsBySession {
            insightsBySession[sid] = list.filter { $0.id != insightID }
        }
        onSessionListChanged?(.insightRemoved(id: insightID, sessionID: sessionID))
    }

    private func applyRemoteSessionProcessInfo(sessionID: UUID, info: ProcessSession.ProcessInfo) {
        try? store.deleteMemoryPagesAnon(sessionID: sessionID, exceptIdentity: info.identity)
        updateSession(id: sessionID) { $0.processInfo = info }
    }

    private func applyRemoteSessionModuleAnalysis(sessionID: UUID, analysis: ModuleAnalysis) {
        var stored = analysis
        stored.sessionID = sessionID
        try? store.save(stored)
    }

    private func applyRemoteSessionModuleSymbols(sessionID: UUID, entries: [SessionOp.UpdateModuleSymbols.Entry]) {
        for entry in entries {
            try? store.upsertModuleSymbol(
                sessionID: sessionID,
                modulePath: entry.modulePath,
                offset: entry.offset,
                name: entry.name
            )
        }
    }

    private func applyRemoteSessionInstrumentAdded(sessionID: UUID, instance: InstrumentInstance) {
        var stored = instance
        stored.sessionID = sessionID
        try? store.save(stored)
        onSessionListChanged?(.instrumentAdded(stored))
    }

    private func applyRemoteSessionInstrumentUpdated(sessionID: UUID, instance: InstrumentInstance) {
        var stored = instance
        stored.sessionID = sessionID
        try? store.save(stored)
        onSessionListChanged?(.instrumentUpdated(stored))
    }

    private func applyRemoteSessionInstrumentRemoved(sessionID: UUID, instanceID: UUID) {
        try? store.deleteInstrument(id: instanceID)
        onSessionListChanged?(.instrumentRemoved(id: instanceID, sessionID: sessionID))
    }

    public func localUserHosts(_ sessionID: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
        return localUserHosts(session)
    }

    public func localUserHosts(_ session: ProcessSession) -> Bool {
        guard let host = session.host, let localID = localUserID else { return true }
        return host.id == localID
    }

    public func isHostingNode(_ sessionID: UUID) -> Bool {
        node(forSessionID: sessionID) != nil
    }

    public func isHostedRemotelyLive(_ sessionID: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
        guard session.host != nil, !isHostingNode(sessionID) else { return false }
        return session.phase == .attached || session.phase == .attaching
    }

    public var canHostNewSessions: Bool {
        !collaboration.isCollaborative || collaboration.isOwner
    }

    public func canTakeHosting(_ session: ProcessSession) -> Bool {
        guard collaboration.isCollaborative else { return true }
        guard case .joined = collaboration.status, collaboration.isOwner else { return false }
        if localUserHosts(session) { return true }
        return !isHostedRemotelyLive(session.id)
    }

    private func emitEngineError(subsystem: String, text: String) {
        emitEngineEvent(subsystem: subsystem, level: .error, text: text)
    }

    private func emitEngineWarning(subsystem: String, text: String) {
        emitEngineEvent(subsystem: subsystem, level: .warning, text: text)
    }

    private func emitEngineEvent(subsystem: String, level: ConsoleLevel, text: String) {
        _events.yield(RuntimeEvent(
            source: .engine(subsystem: subsystem),
            payload: .consoleMessage(ConsoleMessage(level: level, values: [.string(text)]))
        ))
    }

    private func broadcastInstrumentStatus(instanceID: UUID, sessionID: UUID) {
        guard let instance = try? store.fetchInstrument(id: instanceID) else { return }
        onSessionListChanged?(.instrumentUpdated(instance))
        if isHostingNode(sessionID) {
            broadcastInstrumentUpdate(instance)
        }
    }

    private func broadcastInstrumentUpdate(_ instance: InstrumentInstance) {
        guard isHostingNode(instance.sessionID) else { return }
        let status = node(forSessionID: instance.sessionID)?.instruments.first(where: { $0.id == instance.id })?.status
        collaboration.enqueueUpdateInstrument(sessionID: instance.sessionID, instance: instance, runtimeStatus: status)
    }

    private func handleRemoteReplEvalRequest(sessionID: UUID, code: String, language: REPLLanguage, cellID: UUID) {
        guard let node = processNodes.first(where: { $0.sessionID == sessionID }) else { return }
        Task { @MainActor in
            await node.evalInREPL(code, language: language, cellID: cellID)
        }
    }

    private func handleRemoteInstrumentSetStateRequest(
        sessionID: UUID,
        instanceID: UUID,
        state: InstrumentState
    ) {
        guard isHostingNode(sessionID),
            let instance = try? store.fetchInstrument(id: instanceID)
        else { return }
        Task { @MainActor in
            await setInstrumentState(instance, state: state)
        }
    }

    private func handleRemoteInstrumentRemoveRequest(sessionID: UUID, instanceID: UUID) {
        guard isHostingNode(sessionID),
            let instance = try? store.fetchInstrument(id: instanceID)
        else { return }
        Task { @MainActor in
            await removeInstrument(instance)
        }
    }

    private func handleRemoteInstrumentAddRequest(
        sessionID: UUID,
        kind: InstrumentKind,
        sourceIdentifier: String,
        configJSON: Data
    ) {
        guard isHostingNode(sessionID) else { return }
        Task { @MainActor in
            _ = await addInstrument(
                kind: kind,
                sourceIdentifier: sourceIdentifier,
                configJSON: configJSON,
                sessionID: sessionID
            )
        }
    }

    private func handleRemoteInstrumentUpdateConfigRequest(
        sessionID: UUID,
        instanceID: UUID,
        configJSON: Data
    ) {
        guard isHostingNode(sessionID),
            let instance = try? store.fetchInstrument(id: instanceID)
        else { return }
        Task { @MainActor in
            await applyInstrumentConfig(instance, configJSON: configJSON)
        }
    }

    private func applySessionsSnapshot(_ snapshot: [CollaborationSession.Session]) {
        let serverKnown = Set(snapshot.map(\.id))
        for cached in sessions where !localUserHosts(cached) && !serverKnown.contains(cached.id) {
            applyRemoteSessionRemoval(sessionID: cached.id)
        }
        for session in snapshot {
            adoptRemoteSession(session)
        }
        markOrphanedHostsDetached(serverKnown: serverKnown)
        announceMissingLocalSessions(serverKnown: serverKnown)
    }

    private func markOrphanedHostsDetached(serverKnown: Set<UUID>) {
        for cached in sessions
            where localUserHosts(cached)
            && !isHostingNode(cached.id)
            && (cached.phase == .attached || cached.phase == .attaching)
        {
            let sid = cached.id
            updateSession(id: sid) { $0.phase = .idle }
            if serverKnown.contains(sid) {
                collaboration.enqueueUpdateSessionPhase(sessionID: sid, phase: .detached)
            }
        }
    }

    private func announceMissingLocalSessions(serverKnown: Set<UUID>) {
        guard collaboration.isOwner, let localUser = collaboration.localUser else { return }
        for session in sessions where session.host == nil && !serverKnown.contains(session.id) {
            var promoted = session
            promoted.host = localUser
            saveSession(promoted)
            collaboration.enqueueAddSession(
                sessionID: session.id,
                deviceID: session.deviceID,
                deviceName: session.deviceName,
                pid: session.lastKnownPID,
                processName: session.processName,
                createdAt: ISO8601DateFormatter().string(from: session.createdAt)
            )
            announceLocalSessionChildren(sessionID: session.id)
        }
    }

    private func announceLocalSessionChildren(sessionID: UUID) {
        for cell in (try? store.fetchREPLCells(sessionID: sessionID)) ?? [] {
            collaboration.enqueueAddReplCell(sessionID: sessionID, cell: cell)
        }
        for instance in (try? store.fetchInstruments(sessionID: sessionID)) ?? [] {
            let status = node(forSessionID: sessionID)?.instruments.first(where: { $0.id == instance.id })?.status
            collaboration.enqueueAddInstrument(sessionID: sessionID, instance: instance, runtimeStatus: status)
        }
        for insight in (try? store.fetchInsights(sessionID: sessionID)) ?? [] {
            collaboration.enqueueAddInsight(sessionID: sessionID, insight: insight)
        }
        for trace in (try? store.fetchITraces(sessionID: sessionID)) ?? [] {
            collaboration.enqueueUpsertTrace(sessionID: sessionID, trace: trace)
            Task { @MainActor [weak self] in
                await self?.uploadTraceDelta(trace, collabSessionID: sessionID)
            }
        }
    }

    private func adoptRemoteSession(_ session: CollaborationSession.Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            var record = sessions[idx]
            record.host = session.host
            record.phase = session.phase.toProcessSessionPhase
            record.armingState = session.armingState
            record.processName = session.processName
            record.deviceID = session.deviceID
            record.deviceName = session.deviceName
            record.lastKnownPID = session.pid
            if !session.modules.isEmpty {
                record.lastKnownModules = session.modules
            }
            if !session.threads.isEmpty {
                record.lastKnownThreads = session.threads
            }
            if let info = session.processInfo {
                record.processInfo = info
                try? store.deleteMemoryPagesAnon(sessionID: session.id, exceptIdentity: info.identity)
            }
            saveSession(record)
            for analysis in session.moduleAnalyses {
                var stored = analysis
                stored.sessionID = session.id
                try? store.save(stored)
            }
            for entry in session.moduleSymbols {
                try? store.upsertModuleSymbol(
                    sessionID: session.id,
                    modulePath: entry.modulePath,
                    offset: entry.offset,
                    name: entry.name
                )
            }
        } else {
            var record = ProcessSession(
                id: session.id,
                kind: .attach,
                host: session.host,
                deviceID: session.deviceID,
                deviceName: session.deviceName,
                processName: session.processName,
                lastKnownPID: session.pid,
                armingState: session.armingState
            )
            record.phase = session.phase.toProcessSessionPhase
            record.lastKnownModules = session.modules
            record.lastKnownThreads = session.threads
            try? store.save(record)
            sessions.insert(record, at: 0)
            onSessionListChanged?(.sessionAdded(record))
        }

        for cell in session.replCells {
            var stored = cell
            stored.sessionID = session.id
            try? store.save(stored)
            onREPLCellAdded?(stored)
        }

        for inst in session.instruments {
            var stored = inst
            stored.sessionID = session.id
            try? store.save(stored)
            onSessionListChanged?(.instrumentAdded(stored))
        }

        for insight in session.insights {
            var stored = insight
            stored.sessionID = session.id
            try? store.save(stored)
            onSessionListChanged?(.insightAdded(stored))
        }

        for trace in session.traces {
            var stored = trace
            stored.sessionID = session.id
            try? store.save(stored)
            onSessionListChanged?(.traceUpdated(stored))
        }
    }

    private func applyRemoteSessionPhase(
        sessionID: UUID,
        phase: CollaborationSession.Session.Phase,
        reason: String?
    ) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var updated = sessions[idx]
        updated.phase = phase.toProcessSessionPhase
        saveSession(updated)
    }

    private func applyRemoteSessionArming(
        sessionID: UUID,
        armingState: ProcessSession.ArmingState
    ) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var updated = sessions[idx]
        updated.armingState = armingState
        saveSession(updated)
    }

    private func applyRemoteSessionModules(sessionID: UUID, delta: ModuleDelta) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var updated = sessions[idx]
        updated.lastKnownModules = delta.applied(to: updated.lastKnownModules)
        saveSession(updated)
    }

    private func applyRemoteSessionThreads(sessionID: UUID, delta: ThreadDelta) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var updated = sessions[idx]
        updated.lastKnownThreads = delta.applied(to: updated.lastKnownThreads)
        saveSession(updated)
    }

    private func applyRemoteSessionHostChange(
        sessionID: UUID,
        host: CollaborationSession.UserInfo,
        deviceID: String,
        deviceName: String,
        pid: UInt,
        processName: String
    ) {
        let wasMyHost = sessions.first(where: { $0.id == sessionID })?.host?.id == collaboration.localUser?.id
        let isMyHost = host.id == collaboration.localUser?.id

        if wasMyHost && !isMyHost, let node = node(forSessionID: sessionID) {
            removeNode(node)
        }

        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var updated = sessions[idx]
        updated.host = host
        updated.deviceID = deviceID
        updated.deviceName = deviceName
        updated.processName = processName
        updated.lastKnownPID = pid
        updated.lastKnownMainModule = nil
        updated.lastKnownModules = nil
        updated.lastKnownThreads = nil
        saveSession(updated)
    }

    private func applyRemoteSessionReplCell(sessionID: UUID, cell: REPLCell) {
        var stored = cell
        stored.sessionID = sessionID
        try? store.save(stored)
        onREPLCellAdded?(stored)
    }

    private func applyRemoteSessionRemoval(sessionID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        if let node = processNodes.first(where: { $0.sessionID == sessionID }) {
            removeNode(node)
        }
        try? store.deleteSession(id: sessionID)
        sessions.removeAll { $0.id == sessionID }
        onSessionListChanged?(.sessionRemoved(sessionID))
    }

    public func start() async {
        if let eventStore {
            let restored = await eventStore.loadAll()
            if !restored.isEmpty {
                eventLog.restore(restored)
            }
        }
        if let loaded = try? store.fetchSessions() {
            for var session in loaded where session.phase != .idle {
                session.phase = .idle
                try? store.save(session)
            }
        }
        #if canImport(Network) || canImport(CSoup)
        purgeExternalMCPMissions()
        #endif
        notebookEntries = (try? store.fetchNotebookEntries()) ?? []
        sessions = (try? store.fetchSessions()) ?? []
        for session in sessions {
            rebuildAddressAnnotations(sessionID: session.id)
        }
        projectUIState = (try? store.fetchProjectUIState()) ?? ProjectUIState()
        sessionUIStates = (try? store.fetchAllSessionUIStates()) ?? [:]
        customInstrumentDefUIStates = (try? store.fetchAllCustomInstrumentDefUIStates()) ?? [:]

        sessionsObservation = store.observeSessions { [weak self] sessions in
            Task { @MainActor in
                self?.sessions = sessions
            }
        }
        notebookObservation = store.observeNotebookEntries { [weak self] entries in
            Task { @MainActor in self?.notebookEntries = entries }
        }
        instrumentsObservation = store.observeAllInstruments { [weak self] grouped in
            Task { @MainActor in
                self?.instrumentsBySession = grouped
                self?.hydrateWidgetStatesFromStore(grouped)
            }
        }
        insightsObservation = store.observeAllInsights { [weak self] grouped in
            Task { @MainActor in self?.insightsBySession = grouped }
        }
        tracesObservation = store.observeAllITraces { [weak self] grouped in
            Task { @MainActor in self?.tracesBySession = grouped }
        }
        packagesObservation = store.observeInstalledPackages { [weak self] packages in
            Task { @MainActor in
                self?.installedPackages = packages
                self?.onInstalledPackagesChanged?(packages)
            }
        }

        await loadRemoteDevices()
        watchDevicesForGating()
        if let labID = CollaborationJoinQueue.shared.consumeNext() {
            startCollaboration(joiningLab: labID)
        }
    }

    public func shutdown() async {
        guard !hasShutDown else { return }
        hasShutDown = true

        eventLogTask?.cancel()
        eventLogTask = nil
        eventLog.flushNow()
        await eventStoreFlushTail.value
        deviceChangeWatcher?.cancel()
        deviceChangeWatcher = nil
        for task in deviceEventTasks.values { task.cancel() }
        deviceEventTasks.removeAll()

        #if canImport(Network) || canImport(CSoup)
        for server in activeMCPServersByMissionID.values { server.stop() }
        activeMCPServersByMissionID.removeAll()
        externalMCPServer?.stop()
        externalMCPServer = nil
        externalMCPURL = nil
        externalMCPMissionID = nil
        #endif

        sessionsObservation = nil
        notebookObservation = nil
        instrumentsObservation = nil
        insightsObservation = nil
        tracesObservation = nil
        missionsObservation = nil
        packagesObservation = nil

        for node in processNodes { node.stop() }
        processNodes.removeAll()

        for service in drainServices.values { await service.shutdown() }
        drainServices.removeAll()

        await collaboration.stop()
    }

    @ObservationIgnored private var hasShutDown = false

    public func clearEventLog() {
        eventLog.clear()
        if let eventStore {
            Task { await eventStore.clear() }
        }
    }

    private func watchDevicesForGating() {
        deviceChangeWatcher?.cancel()
        deviceChangeWatcher = Task { @MainActor [weak self] in
            guard let self else { return }
            for await snapshot in await self.deviceManager.snapshots() {
                await self.systemParameters.retain(deviceIDs: Set(snapshot.map(\.id)))
                for device in snapshot {
                    await self.evaluateGating(forDeviceID: device.id)
                }
            }
        }
    }

    private func loadRemoteDevices() async {
        for config in (try? store.fetchRemoteDevices()) ?? [] {
            do {
                _ = try await deviceManager.addRemoteDevice(
                    address: config.address,
                    certificate: config.certificate,
                    origin: config.origin,
                    token: config.token,
                    keepaliveInterval: config.keepaliveInterval
                )
            } catch {
                emitEngineError(subsystem: "devices", text: "Failed to add remote device \(config.address): \(userFacingMessage(error))")
            }
        }
    }

    // MARK: - Package Management

    public func installPackage(
        name: String,
        versionSpec: String? = nil,
        globalAlias: String? = nil
    ) async throws -> InstalledPackage {
        let paths = try compilerWorkspacePaths()
        let installed = try await compilerWorkspace.installPackage(
            name: name,
            versionSpec: versionSpec,
            globalAlias: globalAlias,
            paths: paths
        )
        await propagatePackage(installed)
        return installed
    }

    public func rebuildEditorFSSnapshotIfNeeded() async {
        guard editorFSSnapshotDirty else { return }
        do {
            let paths = try compilerWorkspacePaths()
            _ = try await compilerWorkspace.ensureReady(paths: paths)
            let snapshot = try buildEditorFSSnapshot(paths: paths)
            editorFSSnapshotVersion += 1
            editorFSSnapshot = snapshot.withVersion(editorFSSnapshotVersion)
            editorFSSnapshotDirty = false
        } catch {
            emitEngineError(subsystem: "editor", text: "Failed to rebuild editor FS snapshot: \(userFacingMessage(error))")
        }
    }

    private func buildEditorFSSnapshot(paths: CompilerWorkspacePaths) throws -> EditorFSSnapshot {
        let workspaceRootURI = "file:///workspace/"

        if let cached = cachedNodeModulesSnapshotFiles {
            return EditorFSSnapshot(version: 0, files: cached)
        }
        let files = try Self.scanNodeModulesSnapshotFiles(paths: paths, workspaceRootURI: workspaceRootURI)
        cachedNodeModulesSnapshotFiles = files
        return EditorFSSnapshot(version: 0, files: files)
    }

    private static func scanNodeModulesSnapshotFiles(
        paths: CompilerWorkspacePaths,
        workspaceRootURI: String
    ) throws -> [EditorFSSnapshotFile] {
        let fm = FileManager.default
        let root = paths.root
        let nodeModules = paths.nodeModules

        guard fm.fileExists(atPath: nodeModules.path) else { return [] }

        func toWorkspaceURI(_ fileURL: URL) -> String? {
            guard fileURL.path.hasPrefix(root.path) else { return nil }
            var rel = String(fileURL.path.dropFirst(root.path.count))
            if rel.hasPrefix("/") {
                rel.removeFirst()
            }
            return workspaceRootURI + rel.replacingOccurrences(of: " ", with: "%20")
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        let enumerator = fm.enumerator(
            at: nodeModules,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        var out: [EditorFSSnapshotFile] = []
        out.reserveCapacity(2048)
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let name = values.name ?? url.lastPathComponent
            guard name == "package.json" || name.hasSuffix(".d.ts") else { continue }
            guard let uri = toWorkspaceURI(url) else { continue }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { continue }
            out.append(.init(path: uri, text: text))
        }
        return out
    }

    public func upgradePackage(_ package: InstalledPackage) async throws -> InstalledPackage {
        try await installPackage(
            name: package.name,
            versionSpec: nil,
            globalAlias: package.globalAlias
        )
    }

    public func removePackage(_ package: InstalledPackage) async throws {
        let paths = try compilerWorkspacePaths()
        try await compilerWorkspace.removePackage(package, paths: paths)
        cachedNodeModulesSnapshotFiles = nil
        editorFSSnapshotDirty = true
        await recompileAttachedInstruments()
    }

    public func loadAllPackages(on node: ProcessNode) async {
        do {
            let paths = try compilerWorkspacePaths()
            let bundles = try await compilerWorkspace.currentPackageBundlesForAgent(paths: paths)
            guard !bundles.isEmpty else { return }

            try await node.loadPackages(bundles)

            for entry in bundles {
                node.loadedPackageNames.insert(entry["name"] as! String)
            }
        } catch {
            emitEngineError(subsystem: "packages", text: "Failed to load packages: \(userFacingMessage(error))")
        }
    }

    public func loadPackage(_ package: InstalledPackage, on node: ProcessNode) async {
        if node.loadedPackageNames.contains(package.name) { return }

        do {
            let paths = try compilerWorkspacePaths()
            let bundles = try await compilerWorkspace.currentPackageBundlesForAgent(paths: paths)

            guard let entry = bundles.first(where: { ($0["name"] as? String) == package.name }) else {
                return
            }

            try await node.loadPackages([entry])
            node.loadedPackageNames.insert(package.name)
        } catch {
            var message = "Failed to load package \(package.name): \(userFacingMessage(error))"
            if let compile = error as? CompileFailure, !compile.diagnostics.isEmpty {
                message += "\n\n" + compile.diagnostics.map(\.description).joined(separator: "\n")
            }
            emitEngineError(subsystem: "packages", text: message)
        }
    }

    private func propagatePackage(_ package: InstalledPackage) async {
        cachedNodeModulesSnapshotFiles = nil
        editorFSSnapshotDirty = true
        for node in processNodes {
            await loadPackage(package, on: node)
        }
        await recompileAttachedInstruments()
    }

    private func recompileAttachedInstruments() async {
        for node in processNodes {
            let attached = node.instruments.filter { $0.attachment == .attached }
            guard !attached.isEmpty else { continue }
            let instances = (try? store.fetchInstruments(sessionID: node.sessionID)) ?? []
            for ref in attached {
                guard let instance = instances.first(where: { $0.id == ref.id }) else { continue }
                try? await node.disposeInstrumentOnAgent(instanceID: instance.id)
                node.markInstrumentDetached(id: instance.id)
                await loadInstrumentOnNode(
                    instanceID: instance.id,
                    kind: instance.kind,
                    sourceIdentifier: instance.sourceIdentifier,
                    configJSON: instance.configJSON,
                    node: node,
                    sessionID: node.sessionID
                )
            }
        }
    }

    // MARK: - Descriptor Registry

    public func descriptor(withID id: String) -> InstrumentDescriptor? {
        descriptorsByID[id]
    }

    public func registerDescriptor(_ descriptor: InstrumentDescriptor) {
        if let idx = descriptors.firstIndex(where: { $0.id == descriptor.id }) {
            descriptors[idx] = descriptor
        } else {
            descriptors.append(descriptor)
        }
        descriptorsByID[descriptor.id] = descriptor
    }

    public func reloadHookPacks() {
        hookPacks.reload()
        descriptors.removeAll { $0.kind == .hookPack }
        for key in descriptorsByID.keys where key.hasPrefix("hook-pack:") {
            descriptorsByID.removeValue(forKey: key)
        }
        for desc in hookPacks.descriptors() {
            registerDescriptor(desc)
        }
    }

    public func descriptor(for instance: InstrumentInstance) -> InstrumentDescriptor {
        switch instance.kind {
        case .tracer:
            return descriptorsByID["tracer"] ?? Self.missingDescriptor(for: instance)
        case .hookPack:
            return descriptorsByID["hook-pack:\(instance.sourceIdentifier)"] ?? Self.missingDescriptor(for: instance)
        case .codeShare:
            return descriptorsByID["codeshare:\(instance.sourceIdentifier)"]
                ?? makeCodeShareDescriptor(for: instance)
                ?? Self.missingDescriptor(for: instance)
        case .custom:
            return descriptorsByID["custom:\(instance.sourceIdentifier)"] ?? Self.missingDescriptor(for: instance)
        }
    }

    private static func missingDescriptor(for instance: InstrumentInstance) -> InstrumentDescriptor {
        InstrumentDescriptor(
            id: "missing:\(instance.id.uuidString)",
            kind: instance.kind,
            sourceIdentifier: instance.sourceIdentifier,
            displayName: "Missing instrument",
            icon: .symbolic("puzzle"),
            makeInitialConfigJSON: { Data("{}".utf8) }
        )
    }

    private func refreshCustomInstrumentDescriptors() {
        descriptors.removeAll { $0.kind == .custom }
        for key in descriptorsByID.keys where key.hasPrefix("custom:") {
            descriptorsByID.removeValue(forKey: key)
        }
        for desc in customInstruments.descriptors() {
            registerDescriptor(desc)
        }
        onSessionListChanged?(.descriptorsChanged)
    }

    private func makeCodeShareDescriptor(for instance: InstrumentInstance) -> InstrumentDescriptor? {
        guard
            let cfg = try? JSONDecoder().decode(CodeShareConfig.self, from: instance.configJSON)
        else {
            return nil
        }

        return InstrumentDescriptor(
            id: "codeshare:\(instance.sourceIdentifier)",
            kind: .codeShare,
            sourceIdentifier: instance.sourceIdentifier,
            displayName: cfg.name,
            icon: .symbolic("cloud"),
            makeInitialConfigJSON: { try! JSONEncoder().encode(cfg) }
        )
    }

    public static let tracerDescriptor = InstrumentDescriptor(
        id: "tracer",
        kind: .tracer,
        sourceIdentifier: "builtin.tracer",
        displayName: "Tracer",
        icon: .symbolic("branch"),
        makeInitialConfigJSON: {
            try! JSONEncoder().encode(TracerConfig())
        },
        summarizeEvent: { event in
            String(describing: event.payload)
        }
    )

    // MARK: - Session Orchestration

    public func prepareSpawnSession(
        device: Device,
        config: SpawnConfig,
        reusing existing: ProcessSession? = nil
    ) -> ProcessSession {
        var session = existing ?? ProcessSession(kind: .spawn(config), deviceID: device.id, deviceName: device.name, processName: config.defaultDisplayName, lastKnownPID: 0)
        session.kind = .spawn(config)
        session.deviceID = device.id
        session.deviceName = device.name
        session.processName = config.defaultDisplayName
        session.phase = .attaching
        surfaceSession(session, isNew: existing == nil)
        return session
    }

    public func prepareAttachSession(
        device: Device,
        process: ProcessDetails,
        reusing existing: ProcessSession? = nil
    ) -> ProcessSession {
        var session = existing ?? ProcessSession(kind: .attach, deviceID: device.id, deviceName: device.name, processName: process.name, lastKnownPID: process.pid)
        session.deviceID = device.id
        session.deviceName = device.name
        session.processName = process.name
        session.lastKnownPID = process.pid
        session.phase = .attaching
        session.adoptIcon(from: process)
        surfaceSession(session, isNew: existing == nil)
        return session
    }

    @discardableResult
    public func spawnAndAttach(
        device: Device,
        session: ProcessSession
    ) async throws -> ProcessSession {
        guard case .spawn(let config) = session.kind else {
            fatalError("spawnAndAttach requires a spawn session")
        }

        var s = session
        s.phase = .attaching
        s.detachReason = .applicationRequested
        s.lastError = nil
        saveSession(s)

        ensureDeviceEventsHooked(for: device)

        do {
            let pid = try await device.spawn(
                config.programString,
                argv: config.argvParam,
                envp: nil,
                env: config.envParam,
                cwd: config.cwdParam,
                stdio: config.stdio
            )

            let procs = try await device.enumerateProcesses(pids: [pid], scope: .full)
            guard let process = procs.first else {
                throw EngineError.spawnedProcessNotFound(pid: pid)
            }

            s.deviceName = device.name
            saveSession(s)

            try await performAttach(
                device: device,
                process: process,
                session: s
            )

            s = (try? store.fetchSession(id: s.id)) ?? s
            if config.autoResume {
                try await device.resume(pid)
                s.phase = .attached
            } else {
                s.phase = .awaitingInitialResume
            }
            saveSession(s)
            return s
        } catch {
            s.lastError = error.localizedDescription
            s.phase = .idle
            saveSession(s)
            throw error
        }
    }

    @discardableResult
    public func attach(
        device: Device,
        process: ProcessDetails,
        session: ProcessSession
    ) async throws -> ProcessSession {
        try await performAttach(
            device: device,
            process: process,
            session: session
        )
        return (try? store.fetchSession(id: session.id)) ?? session
    }

    private func performAttach(
        device: Device,
        process: ProcessDetails,
        session: ProcessSession
    ) async throws {
        var s = session
        s.lastKnownPID = process.pid
        s.detachReason = .applicationRequested
        s.lastError = nil
        s.phase = .attaching
        s.adoptIcon(from: process)
        saveSession(s)

        do {
            ensureDeviceEventsHooked(for: device)

            let fridaSession = try await device.attach(to: process.pid)

            updateSession(id: s.id) { $0.lastAttachedAt = Date() }

            let script = try await fridaSession.createScript(
                LumaAgent.coreSource,
                name: "luma",
                runtime: .auto
            )

            let instruments = (try? store.fetchInstruments(sessionID: s.id)) ?? []
            let instrumentRefs = instruments.map {
                ProcessNode.InstrumentRef(
                    id: $0.id, kind: $0.kind,
                    sourceIdentifier: $0.sourceIdentifier,
                    configJSON: $0.configJSON,
                    state: $0.state
                )
            }

            let node = ProcessNode(
                sessionID: s.id,
                device: device,
                process: process,
                session: fridaSession,
                script: script,
                instruments: instrumentRefs,
                drainService: drainService(for: device),
                traceStore: traces
            )
            node.onResolveBlockNames = { [weak self] addresses in
                guard let self else { return Array(repeating: "", count: addresses.count) }
                return await self.symbolDisplay(sessionID: s.id, addresses: addresses).map { $0.primary }
            }

            let existingCells = (try? store.fetchREPLCells(sessionID: s.id)) ?? []
            if !existingCells.isEmpty {
                let cell = REPLCell(
                    sessionID: s.id,
                    code: "New process attached",
                    result: .text(""),
                    isSessionBoundary: true
                )
                try? store.save(cell)
                onREPLCellAdded?(cell)
            }

            updateSession(id: s.id) {
                $0.lastKnownMainModule = nil
                $0.lastKnownModules = nil
                $0.lastKnownThreads = nil
            }

            subscribeToNodeStreams(node)

            processNodes.append(node)

            announceLocalSession(node)

            await node.waitForScriptEventsSubscription()
            await Task.yield()

            try await script.load()

            if let info = await node.fetchProcessInfo() {
                let mainModule = node.mainModule
                invalidateAddressFacts(sessionID: s.id, identity: info.identity)
                try? store.deleteMemoryPagesAnon(sessionID: s.id, exceptIdentity: info.identity)
                let storedInfo = ProcessSession.ProcessInfo(
                    platform: info.platform,
                    arch: info.arch,
                    pointerSize: info.pointerSize,
                    identity: info.identity
                )
                updateSession(id: s.id) {
                    $0.processInfo = storedInfo
                    $0.lastKnownMainModule = mainModule
                }
                seedReplSeekToMainModule(sessionID: s.id)
                collaboration.enqueueUpdateProcessInfo(sessionID: s.id, info: storedInfo)
            }

            await loadAllPackages(on: node)

            for ref in node.instruments where ref.state == .enabled {
                await loadInstrumentOnNode(
                    instanceID: ref.id,
                    kind: ref.kind,
                    sourceIdentifier: ref.sourceIdentifier,
                    configJSON: ref.configJSON,
                    node: node,
                    sessionID: s.id
                )
            }

            updateSession(id: s.id) { $0.phase = .attached }
            if let sid = collabSessionID(forNode: node) {
                collaboration.enqueueUpdateSessionPhase(sessionID: sid, phase: .attached)
            }
        } catch {
            emitEngineError(subsystem: "attach", text: "Failed to attach to \(s.processName): \(userFacingMessage(error))")
            updateSession(id: s.id) {
                $0.lastError = error.localizedDescription
                $0.phase = .idle
            }
            throw error
        }
    }

    private func announceLocalSession(_ node: ProcessNode) {
        guard collaboration.isCollaborative,
              collaboration.isOwner,
              let localUser = collaboration.localUser
        else { return }
        let sessionID = node.sessionID
        guard var session = try? store.fetchSession(id: sessionID) else { return }
        if session.host?.id == localUser.id { return }
        session.host = localUser
        saveSession(session)
        collaboration.enqueueAddSession(
            sessionID: sessionID,
            deviceID: node.deviceID,
            deviceName: node.deviceName,
            pid: node.pid,
            processName: node.processName
        )
    }

    public func resumeSpawnedProcess(node: ProcessNode) async {
        guard let session = try? store.fetchSession(id: node.sessionID) else { return }

        do {
            try await node.resume()
            updateSession(id: session.id) { $0.phase = .attached }
            if let sid = collabSessionID(forNode: node) {
                collaboration.enqueueUpdateSessionPhase(sessionID: sid, phase: .attached)
            }
        } catch {
            updateSession(id: session.id) {
                $0.lastError = error.localizedDescription
            }
        }
    }

    public func removeNode(_ node: ProcessNode) {
        if let idx = processNodes.firstIndex(where: { $0.id == node.id }) {
            let sid = node.sessionID
            processNodes.remove(at: idx)
            node.stop()
            retireDrainService(deviceID: node.deviceID)
            updateSession(id: sid) { $0.phase = .idle }
            rebuildAddressAnnotations(sessionID: sid)
        }
    }

    private func drainService(for device: Device) -> SystemDrainService {
        if let existing = drainServices[device.id] {
            return existing
        }
        let service = SystemDrainService(device: device, agentSource: LumaAgent.drainSource)
        drainServices[device.id] = service
        return service
    }

    private func retireDrainService(deviceID: String) {
        guard !processNodes.contains(where: { $0.deviceID == deviceID }) else { return }
        guard let service = drainServices.removeValue(forKey: deviceID) else { return }
        Task { await service.shutdown() }
    }

    // MARK: - Spawn Gating

    public func armSession(id: UUID, matchPattern: String) async {
        guard var session = try? store.fetchSession(id: id) else { return }
        session.armingState = .armed(matchPattern: matchPattern, armedAt: Date())
        session.lastArmPattern = matchPattern
        clearGatingErrorIfPresent(&session)
        saveSession(session)
        broadcastArmingChangeIfHosting(session)
        gatingIntendedDevices.insert(session.deviceID)
        await evaluateGating(forDeviceID: session.deviceID)
    }

    public func disarmSession(id: UUID) async {
        guard var session = try? store.fetchSession(id: id) else { return }
        if case .armed(let pattern, _) = session.armingState {
            session.lastArmPattern = pattern
        }
        session.armingState = .unarmed
        clearGatingErrorIfPresent(&session)
        saveSession(session)
        broadcastArmingChangeIfHosting(session)
        await evaluateGating(forDeviceID: session.deviceID)
    }

    private func clearGatingErrorIfPresent(_ session: inout ProcessSession) {
        if session.lastError?.hasPrefix("Spawn gating couldn't be enabled") == true {
            session.lastError = nil
        }
    }

    @discardableResult
    public func armNewSession(
        device: Device,
        config: SpawnConfig,
        matchPattern: String
    ) async -> ProcessSession {
        var session = ProcessSession(
            kind: .spawn(config),
            deviceID: device.id,
            deviceName: device.name,
            processName: config.defaultDisplayName,
            lastKnownPID: 0,
            armingState: .armed(matchPattern: matchPattern, armedAt: Date())
        )
        session.lastArmPattern = matchPattern
        createSession(session)
        announceArmedSessionIfCollaborative(session)
        gatingIntendedDevices.insert(device.id)
        await evaluateGating(forDeviceID: device.id)
        return session
    }

    private func broadcastArmingChangeIfHosting(_ session: ProcessSession) {
        guard collaboration.isCollaborative,
              isHostingNode(session.id),
              let collabID = collabSessionID(forSessionID: session.id)
        else { return }
        collaboration.enqueueUpdateSessionArming(sessionID: collabID, armingState: session.armingState)
    }

    private func announceArmedSessionIfCollaborative(_ session: ProcessSession) {
        guard collaboration.isCollaborative,
              collaboration.isOwner,
              let localUser = collaboration.localUser
        else { return }
        var stored = session
        stored.host = localUser
        saveSession(stored)
        collaboration.enqueueAddSession(
            sessionID: stored.id,
            deviceID: stored.deviceID,
            deviceName: stored.deviceName,
            pid: stored.lastKnownPID,
            processName: stored.processName
        )
        collaboration.enqueueUpdateSessionPhase(
            sessionID: stored.id,
            phase: .detached
        )
        collaboration.enqueueUpdateSessionArming(
            sessionID: stored.id,
            armingState: stored.armingState
        )
    }

    public func resumeGating(forSessionID sessionID: UUID) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        gatingIntendedDevices.insert(session.deviceID)
        await evaluateGating(forDeviceID: session.deviceID)
    }

    public func isGatingActive(forDeviceID deviceID: String) -> Bool {
        gatingEnabledDevices.contains(deviceID)
    }

    public func defaultArmPattern(for session: ProcessSession) -> String {
        if case .armed(let pattern, _) = session.armingState {
            return pattern
        }
        if let last = session.lastArmPattern, !last.isEmpty {
            return last
        }
        let literal: String
        switch session.kind {
        case .spawn(let config): literal = config.programString
        case .attach: literal = session.processName
        }
        return "^" + NSRegularExpression.escapedPattern(for: literal) + "$"
    }

    private func evaluateGating(forDeviceID deviceID: String) async {
        let hasArmedSession = sessions.contains { session in
            guard session.deviceID == deviceID else { return false }
            if case .armed = session.armingState { return true }
            return false
        }
        let shouldGate = hasArmedSession && gatingIntendedDevices.contains(deviceID)
        let isGating = gatingEnabledDevices.contains(deviceID)
        guard shouldGate != isGating else { return }
        let devices = await deviceManager.currentDevices()
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            gatingEnabledDevices.remove(deviceID)
            return
        }
        do {
            if shouldGate {
                try await device.enableSpawnGating()
                gatingEnabledDevices.insert(deviceID)
                ensureDeviceEventsHooked(for: device)
                clearGatingErrorOnArmedSessions(forDeviceID: deviceID)
            } else {
                try await device.disableSpawnGating()
                gatingEnabledDevices.remove(deviceID)
            }
            notifyGatingChange(forDeviceID: deviceID)
        } catch {
            let reason = userFacingMessage(error)
            if shouldGate {
                notify(.error,
                       "Couldn't enable spawn gating on \(device.name)",
                       message: reason)
                recordGatingErrorOnArmedSessions(forDeviceID: deviceID, reason: reason)
            } else {
                emitEngineWarning(subsystem: "spawn-gating", text: "Failed to disable spawn gating on \(deviceID): \(reason)")
            }
        }
    }

    private func notifyGatingChange(forDeviceID deviceID: String) {
        for session in sessions where session.deviceID == deviceID {
            guard case .armed = session.armingState else { continue }
            onSessionListChanged?(.sessionUpdated(session))
        }
    }

    private func recordGatingErrorOnArmedSessions(forDeviceID deviceID: String, reason: String) {
        let summary = "Spawn gating couldn't be enabled: \(reason)"
        for session in sessions where session.deviceID == deviceID {
            if case .armed = session.armingState {
                updateSession(id: session.id) { $0.lastError = summary }
            }
        }
    }

    private func clearGatingErrorOnArmedSessions(forDeviceID deviceID: String) {
        for session in sessions where session.deviceID == deviceID {
            guard session.lastError?.hasPrefix("Spawn gating couldn't be enabled") == true else { continue }
            updateSession(id: session.id) { $0.lastError = nil }
        }
    }

    private func notify(
        _ severity: UserNotification.Severity,
        _ title: String,
        message: String? = nil
    ) {
        onUserNotification?(UserNotification(severity: severity, title: title, message: message))
    }

    private func userFacingMessage(_ error: any Swift.Error) -> String {
        if let compile = error as? CompileFailure {
            return userFacingMessage(compile.underlying)
        }
        if let fridaError = error as? Frida.Error {
            return fridaError.description
        }
        return error.localizedDescription
    }

    public func anchor(sessionID: UUID, address: UInt64) -> AddressAnchor {
        if let node = node(forSessionID: sessionID) {
            return node.anchor(for: address)
        }
        if let modules = session(id: sessionID)?.lastKnownModules,
            let m = modules.first(where: { address >= $0.base && address < ($0.base + $0.size) })
        {
            return .moduleOffset(name: m.name, offset: address - m.base)
        }
        return .absolute(address)
    }

    public func node(forSessionID sessionID: UUID) -> ProcessNode? {
        processNodes.first { $0.id == sessionID || $0.sessionID == sessionID }
    }

    public func instrument(id: UUID, sessionID: UUID) -> InstrumentInstance? {
        try? store.fetchInstrument(id: id)
    }

    public func session(id: UUID) -> ProcessSession? {
        sessions.first { $0.id == id } ?? (try? store.fetchSession(id: id))
    }

    public func session(forNode node: ProcessNode) -> ProcessSession? {
        session(id: node.sessionID)
    }

    public func processNode(forEvent event: RuntimeEvent) -> ProcessNode? {
        guard let sessionID = event.sessionID else { return nil }
        return node(forSessionID: sessionID)
    }

    public func instrument(forEvent event: RuntimeEvent) -> InstrumentInstance? {
        guard case .instrument(let id, _) = event.source,
              let sessionID = event.sessionID
        else { return nil }
        return instrument(id: id, sessionID: sessionID)
    }

    public var localUserID: String? {
        collaboration.localUser?.id ?? gitHubAuth.currentUser?.id
    }

    public func disassembler(forSessionID sessionID: UUID) -> Disassembler? {
        if let existing = disassemblers[sessionID] { return existing }
        guard let info = session(id: sessionID)?.processInfo else { return nil }
        let env = SessionDisassemblyEnvironment(engine: self, sessionID: sessionID)
        let reader = memoryReader(forSessionID: sessionID, env: env)
        let d = Disassembler(
            sessionID: sessionID,
            processInfo: info,
            store: store,
            modulesProvider: { [weak self] in self?.modulesSnapshot(forSessionID: sessionID) ?? [] },
            introspector: env,
            reader: reader
        )
        d.onAnalysisSaved = { [weak self] analysis in
            guard let self else { return }
            self.collaboration.enqueueUpdateModuleAnalysis(sessionID: sessionID, analysis: analysis)
            Task { @MainActor [weak self] in
                await self?.linkInsightsForFreshAnalysis(sessionID: sessionID, analysis: analysis)
            }
        }
        d.insightDisplayTitle = { [weak self] insight in
            self?.displayTitle(for: insight) ?? insight.anchor.displayString
        }
        d.onAnalysisStateChanged = { [weak self] path, status in
            self?.moduleAnalysisStatuses[sessionID, default: [:]][path] = status
        }
        disassemblers[sessionID] = d
        return d
    }

    public func moduleAnalysisStatus(sessionID: UUID, modulePath: String) -> ModuleAnalysisStatus {
        moduleAnalysisStatuses[sessionID]?[modulePath] ?? .notAnalyzed
    }

    public func analyzeModule(sessionID: UUID, module: ProcessModule) {
        guard let disassembler = disassembler(forSessionID: sessionID) else { return }
        Task { @MainActor in
            await disassembler.analyze(module: module)
        }
    }

    private func radare2REPLValue(forCommand command: String, sessionID: UUID) async -> REPLResult.Value {
        guard let disassembler = disassembler(forSessionID: sessionID) else {
            return .text("r2 is unavailable until the process is attached.")
        }
        if let arguments = hexdumpArguments(command) {
            let value = await hexdumpValue(forCommand: command, arguments: arguments, disassembler: disassembler)
            await captureREPLSeek(disassembler: disassembler, sessionID: sessionID)
            return value
        }
        let result = await disassembler.runCommand(command)
        await captureREPLSeek(disassembler: disassembler, sessionID: sessionID)
        return replValue(forR2Result: result)
    }

    private func hexdumpArguments(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let token = trimmed.prefix(while: { !$0.isWhitespace })
        guard token == "px" || token == "x" else { return nil }
        return trimmed.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
    }

    private func hexdumpValue(forCommand command: String, arguments: String, disassembler: Disassembler) async -> REPLResult.Value {
        let bytes = await disassembler.runCommand("pxj \(arguments)")
        guard let data = decodeR2ByteArray(bytes.output) else {
            return replValue(forR2Result: await disassembler.runCommand(command))
        }
        let atClause = arguments.range(of: "@").map { String(arguments[$0.lowerBound...]) } ?? ""
        let address = await disassembler.runCommand("?v $$ \(atClause)".trimmingCharacters(in: .whitespaces))
        let base = decodeR2Address(address.output)
        return .binary(data, meta: REPLCell.Result.BinaryMeta(typedArray: nil, baseAddress: base))
    }

    private func decodeR2ByteArray(_ output: String?) -> Data? {
        guard let output, let data = output.data(using: .utf8),
            let values = try? JSONSerialization.jsonObject(with: data) as? [Int]
        else { return nil }
        return Data(values.map { UInt8($0 & 0xff) })
    }

    private func decodeR2Address(_ output: String?) -> UInt64? {
        guard let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if trimmed.hasPrefix("0x") { return UInt64(trimmed.dropFirst(2), radix: 16) }
        return UInt64(trimmed)
    }

    private func captureREPLSeek(disassembler: Disassembler, sessionID: UUID) async {
        guard let address = await disassembler.currentSeek() else { return }
        setREPLSeekAnchor(sessionID: sessionID, anchor(sessionID: sessionID, address: address))
    }

    private static let maxRadare2Completions = 64

    private func radare2REPLCompletions(forCode code: String, cursor: Int, sessionID: UUID) async -> [REPLCompletion] {
        guard let disassembler = disassembler(forSessionID: sessionID) else { return [] }

        let head = String(code.prefix(cursor))
        let token = trailingToken(head)
        guard !token.isEmpty else { return [] }

        let atCommandPosition = head.dropLast(token.count).allSatisfy(\.isWhitespace)
        if atCommandPosition {
            return await commandCompletions(prefix: token, disassembler: disassembler)
        }
        return await argumentCompletions(command: leadingCommand(head), prefix: token, disassembler: disassembler)
    }

    private func leadingCommand(_ head: String) -> String {
        String(head.prefix(while: { !$0.isWhitespace }))
    }

    private func argumentCompletions(command: String, prefix: String, disassembler: Disassembler) async -> [REPLCompletion] {
        switch command {
        case "e":
            return await evalCompletions(prefix: prefix, disassembler: disassembler)
        case "fs":
            return await flagspaceCompletions(prefix: prefix, disassembler: disassembler)
        default:
            return await flagCompletions(prefix: prefix, disassembler: disassembler)
        }
    }

    private func evalCompletions(prefix: String, disassembler: Disassembler) async -> [REPLCompletion] {
        let result = await disassembler.runCommand("e?j")
        guard let data = result.output?.data(using: .utf8),
            let variables = try? JSONDecoder().decode([R2EvalVariable].self, from: data)
        else { return [] }
        return variables
            .filter { $0.name.hasPrefix(prefix) }
            .prefix(Self.maxRadare2Completions)
            .map { REPLCompletion(insertText: $0.name, displayText: $0.name, detailText: $0.detail) }
    }

    private func flagspaceCompletions(prefix: String, disassembler: Disassembler) async -> [REPLCompletion] {
        let result = await disassembler.runCommand("fsq")
        return (result.output ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
            .prefix(Self.maxRadare2Completions)
            .map(REPLCompletion.init)
    }

    private func commandCompletions(prefix: String, disassembler: Disassembler) async -> [REPLCompletion] {
        let result = await disassembler.runCommand("\(prefix)?")
        var seen: Set<String> = []
        var entries: [(name: String, signature: String, description: String)] = []
        for rawLine in (result.output ?? "").split(separator: "\n") {
            let line = StyledText.parseAnsi(String(rawLine)).plainText
            guard line.hasPrefix("|") else { continue }
            let entry = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let first = entry.split(separator: " ").first else { continue }
            let name = String(first.prefix(while: isCompletionTokenCharacter))
            guard name.hasPrefix(prefix), seen.insert(name).inserted else { continue }
            let (signature, description) = splitHelp(entry)
            entries.append((name, signature, description))
        }

        return entries.prefix(Self.maxRadare2Completions).map { entry in
            REPLCompletion(
                insertText: entry.name,
                displayText: entry.signature,
                detailText: entry.description.isEmpty ? nil : entry.description
            )
        }
    }

    private func splitHelp(_ entry: String) -> (signature: String, description: String) {
        guard let separator = entry.range(of: "\\s{2,}", options: .regularExpression) else {
            return (entry, "")
        }
        return (String(entry[..<separator.lowerBound]), String(entry[separator.upperBound...]))
    }

    private func flagCompletions(prefix: String, disassembler: Disassembler) async -> [REPLCompletion] {
        let result = await disassembler.runCommand("fq~\(prefix)")
        let names = (result.output ?? "").split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        let prefixMatches = names.filter { $0.hasPrefix(prefix) }
        let chosen = prefixMatches.isEmpty ? names : prefixMatches
        return Array(chosen.prefix(Self.maxRadare2Completions)).map(REPLCompletion.init)
    }

    private struct R2EvalVariable: Decodable {
        let name: String
        let description: String?

        var detail: String? {
            description.flatMap { $0.isEmpty ? nil : $0 }
        }

        enum CodingKeys: String, CodingKey {
            case name
            case description = "desc"
        }
    }

    private func trailingToken(_ text: String) -> String {
        String(text.reversed().prefix(while: isCompletionTokenCharacter).reversed())
    }

    private func isCompletionTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "_" || character == "$"
    }

    private func replValue(forR2Result result: R2CommandResult) -> REPLResult.Value {
        let output = result.output ?? ""
        if !result.hasErrors, let structured = JSInspectValue.fromJSONText(output) {
            return .js(structured)
        }
        let trimmed = String(output.reversed().drop(while: \.isNewline).reversed())
        return .styled(StyledText.parseAnsi(combine(trimmed, errors: result.errors)))
    }

    private func combine(_ output: String, errors: [R2LogEntry]) -> String {
        let messages = errors.map(\.message).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !messages.isEmpty else { return output }
        return output.isEmpty ? messages : output + "\n" + messages
    }

    private func restoreReplSeek(sessionID: UUID) {
        guard let seekAnchor = replSeekAnchor(forSessionID: sessionID) else { return }
        guard seekRestoredSessions.insert(sessionID).inserted else { return }
        guard let disassembler = disassembler(forSessionID: sessionID) else { return }

        Task(priority: .utility) { @MainActor in
            if let address = await self.resolve(sessionID: sessionID, anchor: seekAnchor) {
                await disassembler.seek(to: address)
            }
        }
    }

    private func seedReplSeekToMainModule(sessionID: UUID) {
        guard replSeekAnchor(forSessionID: sessionID) == nil else { return }
        guard seekRestoredSessions.insert(sessionID).inserted else { return }
        guard let base = session(id: sessionID)?.lastKnownMainModule?.base else { return }
        guard let disassembler = disassembler(forSessionID: sessionID) else { return }

        Task(priority: .utility) { @MainActor in
            await disassembler.seek(to: base)
        }
    }

    private func linkInsightsForFreshAnalysis(sessionID: UUID, analysis: ModuleAnalysis) async {
        guard let module = modulesSnapshot(forSessionID: sessionID).first(where: { $0.path == analysis.modulePath }) else { return }
        let functionStarts = Set(analysis.functions.map { module.base &+ $0.offset })
        let insights = (try? store.fetchInsights(sessionID: sessionID)) ?? []
        let newlyDiscoveredStarts = insights.filter { insight in
            guard let addr = insight.lastResolvedAddress, functionStarts.contains(addr) else { return false }
            return !insights.contains { other in other.parentInsightID == insight.id }
        }
        for parent in newlyDiscoveredStarts {
            guard let begin = parent.lastResolvedAddress,
                let end = await disassemblers[sessionID]?.findFunctionEnd(containing: begin),
                end > begin
            else { continue }
            var changed: [AddressInsight] = []
            for sibling in insights where sibling.id != parent.id && sibling.parentInsightID == nil {
                guard let addr = sibling.lastResolvedAddress, addr > begin, addr < end else { continue }
                var updated = sibling
                updated.parentInsightID = parent.id
                persistInsight(updated)
                changed.append(updated)
            }
            for c in changed {
                collaboration.enqueueUpdateInsight(sessionID: sessionID, insight: c)
                emitInsightUpdated(c)
            }
        }
    }

    public func memoryReader(forSessionID sessionID: UUID) -> MemoryReader {
        let env = SessionDisassemblyEnvironment(engine: self, sessionID: sessionID)
        return memoryReader(forSessionID: sessionID, env: env)
    }

    private func memoryReader(forSessionID sessionID: UUID, env: SessionDisassemblyEnvironment) -> CachingMemoryReader {
        if let existing = memoryReaders[sessionID] {
            existing.live = env
            return existing
        }
        let reader = CachingMemoryReader(sessionID: sessionID, store: store, keying: env, live: env)
        reader.publish = { [weak self] page in
            self?.collaboration.publishMemoryPage(sessionID: sessionID, page)
        }
        reader.fetchRemote = { [weak self] region in
            await self?.collaboration.fetchMemoryPage(sessionID: sessionID, region: region)
        }
        memoryReaders[sessionID] = reader
        return reader
    }

    public func recordInsightResolution(_ insight: AddressInsight, resolved: UInt64) {
        var updated = insight
        updated.lastResolvedAddress = resolved
        persistInsight(updated)
        collaboration.enqueueUpdateInsight(sessionID: updated.sessionID, insight: updated)
    }

    public func renameInsight(_ insight: AddressInsight, to newTitle: String) {
        var updated = insight
        updated.userTitle = newTitle
        persistInsight(updated)
        collaboration.enqueueUpdateInsight(sessionID: updated.sessionID, insight: updated)
        applyInsightNameToR2(updated)
        emitInsightUpdated(updated)
    }

    private func persistInsight(_ insight: AddressInsight) {
        try? store.save(insight)
        upsertInsightCache(insight)
    }

    private func upsertInsightCache(_ insight: AddressInsight) {
        var list = insightsBySession[insight.sessionID] ?? []
        if let idx = list.firstIndex(where: { $0.id == insight.id }) {
            list[idx] = insight
        } else {
            list.append(insight)
        }
        insightsBySession[insight.sessionID] = list
    }

    private func emitInsightUpdated(_ insight: AddressInsight) {
        onSessionListChanged?(.insightUpdated(insight))
        for dependent in computedNameDependents(of: insight) {
            onSessionListChanged?(.insightUpdated(dependent))
        }
    }

    private func computedNameDependents(of insight: AddressInsight) -> [AddressInsight] {
        let siblings = insightsBySession[insight.sessionID] ?? []
        var result: [AddressInsight] = []
        var frontier: Set<UUID> = [insight.id]
        while !frontier.isEmpty {
            let parents = frontier
            frontier.removeAll()
            for candidate in siblings where candidate.userTitle?.isEmpty ?? true {
                guard let parentID = candidate.parentInsightID, parents.contains(parentID) else { continue }
                result.append(candidate)
                frontier.insert(candidate.id)
            }
        }
        return result
    }

    public func displayTitle(for insight: AddressInsight) -> String {
        if let title = insight.userTitle, !title.isEmpty { return title }
        if let parentID = insight.parentInsightID,
            let parent = (insightsBySession[insight.sessionID] ?? []).first(where: { $0.id == parentID }),
            let parentAddr = parent.lastResolvedAddress,
            let myAddr = insight.lastResolvedAddress
        {
            return "\(displayTitle(for: parent))+0x\(String(myAddr &- parentAddr, radix: 16))"
        }
        if case .moduleOffset(_, let offset) = insight.anchor, isFunctionStart(insight) {
            return "sub_\(String(offset, radix: 16))"
        }
        return insight.anchor.displayString
    }

    private func isFunctionStart(_ insight: AddressInsight) -> Bool {
        guard let address = insight.lastResolvedAddress else { return false }
        let modules = modulesSnapshot(forSessionID: insight.sessionID)
        guard let module = modules.first(where: { address >= $0.base && address < ($0.base &+ $0.size) }) else { return false }
        let offset = address &- module.base
        guard let analysis = try? store.fetchModuleAnalysis(sessionID: insight.sessionID, modulePath: module.path) else { return false }
        return analysis.functions.contains(where: { $0.offset == offset })
    }

    public func symbolDisplay(sessionID: UUID, addresses: [UInt64]) async -> [SymbolDisplay] {
        var liveByAddress: [UInt64: SymbolicateResult] = [:]
        if let node = node(forSessionID: sessionID),
            let live = try? await node.symbolicate(addresses: addresses)
        {
            for (idx, result) in live.enumerated() where idx < addresses.count {
                if let result { liveByAddress[addresses[idx]] = result }
            }
            persistSymbolicateResults(sessionID: sessionID, byAddress: liveByAddress)
        }
        return addresses.map { address in
            renderSymbolDisplay(sessionID: sessionID, address: address, live: liveByAddress[address])
        }
    }

    private func persistSymbolicateResults(sessionID: UUID, byAddress: [UInt64: SymbolicateResult]) {
        let modules = modulesSnapshot(forSessionID: sessionID)
        var entries: [SessionOp.UpdateModuleSymbols.Entry] = []
        for (address, result) in byAddress {
            guard let module = modules.first(where: { $0.name == result.module || $0.path == result.module }) else { continue }
            let entryAddress = address &- (result.offset ?? 0)
            guard entryAddress >= module.base, entryAddress < (module.base &+ module.size) else { continue }
            let entryOffset = entryAddress &- module.base
            try? store.upsertModuleSymbol(sessionID: sessionID, modulePath: module.path, offset: entryOffset, name: result.name)
            entries.append(.init(modulePath: module.path, offset: entryOffset, name: result.name))
        }
        if !entries.isEmpty {
            collaboration.enqueueUpdateModuleSymbols(sessionID: sessionID, entries: entries)
        }
    }

    public func symbolicNameOverlay(sessionID: UUID, address: UInt64) -> (title: String, offset: UInt64)? {
        let insights = insightsBySession[sessionID] ?? []
        if let exact = insights.first(where: { $0.lastResolvedAddress == address && hasUserTitle($0) }) {
            return (exact.userTitle!, 0)
        }
        guard let function = enclosingFunction(sessionID: sessionID, address: address) else { return nil }
        guard let named = insights.first(where: { $0.lastResolvedAddress == function.entryAddress && hasUserTitle($0) }) else { return nil }
        return (named.userTitle!, address &- function.entryAddress)
    }

    public func enclosingFunction(sessionID: UUID, address: UInt64) -> (entryAddress: UInt64, name: String?)? {
        guard let module = enclosingModule(at: address, sessionID: sessionID) else { return nil }
        let offset = address &- module.base
        guard let result = try? store.enclosingFunction(sessionID: sessionID, modulePath: module.path, offset: offset) else {
            return nil
        }
        return (module.base &+ result.functionOffset, result.name)
    }

    private func renderSymbolDisplay(sessionID: UUID, address: UInt64, live: SymbolicateResult?) -> SymbolDisplay {
        if let overlay = symbolicNameOverlay(sessionID: sessionID, address: address) {
            let suffix = overlay.offset == 0 ? "" : "+0x\(String(overlay.offset, radix: 16))"
            return SymbolDisplay(
                primary: overlay.title + suffix,
                source: live?.source,
                raw: live,
                overlay: SymbolDisplay.Overlay(title: overlay.title, offset: overlay.offset)
            )
        }
        if let live {
            return SymbolDisplay(primary: live.qualifiedName, source: live.source, raw: live)
        }
        if let derived = derivedSymbolDisplay(sessionID: sessionID, address: address) {
            return derived
        }
        return SymbolDisplay(primary: anchor(sessionID: sessionID, address: address).displayString)
    }

    private func derivedSymbolDisplay(sessionID: UUID, address: UInt64) -> SymbolDisplay? {
        guard let module = enclosingModule(at: address, sessionID: sessionID) else { return nil }
        let offset = address &- module.base
        if let symbol = try? store.enclosingModuleSymbol(sessionID: sessionID, modulePath: module.path, offset: offset) {
            let delta = offset &- symbol.offset
            let suffix = delta == 0 ? "" : "+0x\(String(delta, radix: 16))"
            return SymbolDisplay(primary: "\(module.name)!\(symbol.name)\(suffix)")
        }
        if let function = enclosingFunction(sessionID: sessionID, address: address) {
            let delta = address &- function.entryAddress
            let suffix = delta == 0 ? "" : "+0x\(String(delta, radix: 16))"
            let name = function.name ?? "sub_\(String(function.entryAddress &- module.base, radix: 16))"
            return SymbolDisplay(primary: "\(module.name)!\(name)\(suffix)")
        }
        return nil
    }

    private func hasUserTitle(_ insight: AddressInsight) -> Bool {
        guard let title = insight.userTitle else { return false }
        return !title.isEmpty
    }

    private func applyInsightNameToR2(_ insight: AddressInsight) {
        guard let address = insight.lastResolvedAddress,
            let disassembler = disassemblers[insight.sessionID]
        else { return }
        let title = displayTitle(for: insight)
        Task { @MainActor in
            await disassembler.applyInsightName(at: address, title: title)
        }
    }

    public func invalidateInsightRange(sessionID: UUID, address: UInt64, byteCount: Int) async {
        let env = SessionDisassemblyEnvironment(engine: self, sessionID: sessionID)
        let end = address &+ UInt64(byteCount)
        var cursor = MemoryPage.base(of: address)
        while cursor < end {
            switch await env.attribution(pageBase: cursor) {
            case .module(let module):
                if let uuid = await env.moduleUUID(forPath: module.path) {
                    try? store.deleteMemoryPage(sessionID: sessionID, moduleUUID: uuid, offset: cursor &- module.base)
                }
            case .anonymous:
                if let identity = env.processIdentity {
                    try? store.deleteMemoryPage(sessionID: sessionID, processIdentity: identity, address: cursor)
                }
            case .ephemeral:
                break
            }
            cursor = cursor &+ MemoryPage.size
        }
    }

    public func invalidateModule(sessionID: UUID, modulePath: String) {
        guard let analysis = try? store.fetchModuleAnalysis(sessionID: sessionID, modulePath: modulePath) else { return }
        if let uuid = analysis.moduleUUID {
            try? store.deleteMemoryPagesModule(sessionID: sessionID, moduleUUID: uuid)
        }
        try? store.deleteModuleAnalysis(sessionID: sessionID, modulePath: modulePath)
        disassemblers[sessionID]?.forgetModule(path: modulePath)
    }

    public func modulesSnapshot(forSessionID sessionID: UUID) -> [ProcessModule] {
        if let node = node(forSessionID: sessionID) { return node.modules }
        return session(id: sessionID)?.lastKnownModules ?? []
    }

    public func enclosingModule(at address: UInt64, sessionID: UUID) -> ProcessModule? {
        modulesSnapshot(forSessionID: sessionID).first { address >= $0.base && address < ($0.base &+ $0.size) }
    }

    public func resolve(sessionID: UUID, anchor: AddressAnchor, hint: UInt64? = nil) async -> UInt64? {
        if let node = node(forSessionID: sessionID), let resolved = try? await node.resolve(anchor) {
            return resolved
        }
        switch anchor {
        case .absolute(let a):
            return a
        case .moduleOffset(let name, let offset):
            if let base = modulesSnapshot(forSessionID: sessionID).first(where: { $0.name == name })?.base {
                return base &+ offset
            }
            return hint
        case .moduleExport, .objcMethod, .swiftFunc, .debugSymbol, .javaMethod:
            return hint
        }
    }

    public func updateSession(id: UUID, _ mutate: (inout ProcessSession) -> Void) {
        guard var s = try? store.fetchSession(id: id) else { return }
        mutate(&s)
        saveSession(s)
    }

    private func surfaceSession(_ session: ProcessSession, isNew: Bool) {
        if isNew {
            createSession(session)
        } else {
            saveSession(session)
        }
    }

    func createSession(_ session: ProcessSession) {
        try? store.save(session)
        sessions.insert(session, at: 0)
        onSessionListChanged?(.sessionAdded(session))
    }

    public func deleteSession(id: UUID) {
        let removedDeviceID = sessions.first(where: { $0.id == id })?.deviceID
        if let node = node(forSessionID: id) {
            removeNode(node)
        }
        try? store.deleteSession(id: id)
        sessions.removeAll { $0.id == id }
        onSessionListChanged?(.sessionRemoved(id))
        if let deviceID = removedDeviceID {
            Task { @MainActor [weak self] in
                await self?.evaluateGating(forDeviceID: deviceID)
            }
        }
    }

    public func deleteInsight(id: UUID, sessionID: UUID) {
        if localUserHosts(sessionID) {
            try? store.deleteInsight(id: id)
            onSessionListChanged?(.insightRemoved(id: id, sessionID: sessionID))
        }
        if collaboration.isCollaborative {
            collaboration.enqueueRemoveInsight(sessionID: sessionID, insightID: id)
        }
    }

    public func deleteITrace(id: UUID, sessionID: UUID) {
        if localUserHosts(sessionID) {
            try? store.deleteITrace(id: id)
            traces.delete(traceID: id)
            lastUploadedTraceSize.removeValue(forKey: id)
            onSessionListChanged?(.traceRemoved(id: id, sessionID: sessionID))
        }
        if collaboration.isCollaborative {
            collaboration.enqueueRemoveTrace(sessionID: sessionID, traceID: id)
        }
    }

    public func loadTraceDataPrefix(
        traceID: UUID,
        sessionID: UUID,
        length: Int
    ) async throws -> Data {
        if let node = node(forSessionID: sessionID),
            let live = node.livePendingTraceData(traceID: traceID)
        {
            return live.prefix(length)
        }
        if traces.exists(traceID: traceID) {
            let cached = try traces.load(traceID: traceID)
            if cached.count >= length {
                return cached.prefix(length)
            }
        }
        if let sid = collabSessionID(forSessionID: sessionID) {
            let (data, _) = try await collaboration.fetchTraceData(
                sessionID: sid,
                traceID: traceID,
                offset: 0,
                length: length
            )
            return data
        }
        throw LumaCoreError.invalidOperation("Trace data unavailable")
    }

    public func loadTraceData(
        traceID: UUID,
        sessionID: UUID,
        expectedSize: Int? = nil,
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async throws -> Data {
        if let node = node(forSessionID: sessionID),
            let live = node.livePendingTraceData(traceID: traceID)
        {
            return live
        }

        let collabID = collabSessionID(forSessionID: sessionID)
        var data: Data
        var cursor: Int

        if traces.exists(traceID: traceID) {
            let cached = try traces.load(traceID: traceID)
            if expectedSize == nil || cached.count == expectedSize {
                return cached
            }
            if let want = expectedSize, want < cached.count {
                data = Data()
                cursor = 0
            } else {
                data = cached
                cursor = cached.count
            }
        } else {
            data = Data()
            cursor = 0
        }

        guard let sid = collabID else {
            return try traces.load(traceID: traceID)
        }

        while expectedSize.map({ cursor < $0 }) ?? true {
            let remaining = expectedSize.map { $0 - cursor }
            let length = remaining.map { min($0, Self.traceDataPageSize) } ?? Self.traceDataPageSize
            let (chunk, totalSize) = try await collaboration.fetchTraceData(
                sessionID: sid,
                traceID: traceID,
                offset: cursor,
                length: length
            )
            if chunk.isEmpty { break }
            data.append(chunk)
            cursor += chunk.count
            onProgress?(cursor, expectedSize ?? totalSize)
            if expectedSize == nil, cursor >= totalSize { break }
        }

        try? traces.write(data, for: traceID)
        return data
    }

    private func effectiveLastUploadedSize(traceID: UUID, collabSessionID: UUID) async -> Int {
        if let cached = lastUploadedTraceSize[traceID] {
            return cached
        }
        let serverSize: Int
        do {
            let (_, total) = try await collaboration.fetchTraceData(
                sessionID: collabSessionID,
                traceID: traceID,
                offset: 0,
                length: 0
            )
            serverSize = total
        } catch {
            serverSize = 0
        }
        lastUploadedTraceSize[traceID] = serverSize
        return serverSize
    }

    private func uploadTraceDelta(_ trace: ITrace, collabSessionID: UUID) async {
        let traceID = trace.id
        let knownUploaded = await effectiveLastUploadedSize(traceID: traceID, collabSessionID: collabSessionID)
        let startOffset = (trace.dataSize < knownUploaded) ? 0 : knownUploaded
        guard trace.dataSize > startOffset else { return }

        let data: Data
        do {
            data = try await loadTraceData(traceID: traceID, sessionID: trace.sessionID)
        } catch {
            return
        }

        let endIndex = min(data.count, trace.dataSize)
        guard endIndex > startOffset else { return }

        var cursor = startOffset
        while cursor < endIndex {
            let chunkEnd = min(cursor + Self.traceDataPageSize, endIndex)
            let chunk = data.subdata(in: cursor..<chunkEnd)
            collaboration.uploadTraceData(
                sessionID: collabSessionID,
                traceID: traceID,
                offset: cursor,
                chunk: chunk
            )
            cursor = chunkEnd
        }
        lastUploadedTraceSize[traceID] = endIndex
    }

    private func saveSession(_ session: ProcessSession) {
        try? store.save(session)
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        }
        onSessionListChanged?(.sessionUpdated(session))
    }

    public func populateSessionList() {
        for session in sessions {
            onSessionListChanged?(.sessionAdded(session))
            for inst in (try? store.fetchInstruments(sessionID: session.id)) ?? [] {
                onSessionListChanged?(.instrumentAdded(inst))
            }
            for insight in ((try? store.fetchInsights(sessionID: session.id)) ?? []).sorted(by: { $0.createdAt < $1.createdAt }) {
                onSessionListChanged?(.insightAdded(insight))
            }
            for trace in ((try? store.fetchITraces(sessionID: session.id)) ?? []).sorted(by: { $0.startedAt < $1.startedAt }) {
                onSessionListChanged?(.traceUpdated(trace))
            }
        }
    }

    public func sessionID(for node: ProcessNode) -> UUID {
        node.sessionID
    }

    // MARK: - Reestablish Session

    public enum ReestablishResult {
        case attached
        case needsUserInput(reason: String, session: ProcessSession)
    }

    public func reHost(sessionID: UUID) async -> ReestablishResult {
        guard collaboration.isOwner, let localUser = collaboration.localUser else {
            return .needsUserInput(
                reason: "Only owners can host a session in this lab.",
                session: ProcessSession(kind: .attach, deviceID: "", deviceName: "", processName: "", lastKnownPID: 0)
            )
        }
        guard var session = sessions.first(where: { $0.id == sessionID }) else {
            return .needsUserInput(
                reason: "Session not found.",
                session: ProcessSession(kind: .attach, deviceID: "", deviceName: "", processName: "", lastKnownPID: 0)
            )
        }

        let devices = await deviceManager.currentDevices()
        guard let device = devices.first(where: { $0.id == session.deviceID }) else {
            return .needsUserInput(
                reason: "Device \"\(session.deviceName)\" isn't available on this machine. Pick a device and target to host \"\(session.processName)\".",
                session: session
            )
        }

        do {
            let processes = try await device.enumerateProcesses(scope: Scope.full)
            let matches = processes.filter { $0.name == session.processName }
            guard let chosen = matches.first(where: { $0.pid == session.lastKnownPID }) ?? matches.first else {
                return .needsUserInput(
                    reason: "No running process named \"\(session.processName)\" on \(session.deviceName). Choose a target.",
                    session: session
                )
            }
            let claimed = await claimHostingAndAttach(session: &session, device: device, process: chosen, localUser: localUser)
            guard claimed else {
                return .needsUserInput(
                    reason: "Another owner is currently hosting this session. Try again once it's free.",
                    session: session
                )
            }
            return .attached
        } catch {
            return .needsUserInput(
                reason: "Couldn't enumerate processes on \(session.deviceName): \(error.localizedDescription)",
                session: session
            )
        }
    }

    public func claimHosting(
        sessionID: UUID,
        device: Device,
        process: ProcessDetails
    ) async {
        guard collaboration.isOwner, let localUser = collaboration.localUser else { return }
        guard var session = sessions.first(where: { $0.id == sessionID }) else { return }
        await claimHostingAndAttach(session: &session, device: device, process: process, localUser: localUser)
    }

    @discardableResult
    private func claimHostingAndAttach(
        session: inout ProcessSession,
        device: Device,
        process: ProcessDetails,
        localUser: CollaborationSession.UserInfo
    ) async -> Bool {
        do {
            try await collaboration.requestClaimHost(
                sessionID: session.id,
                deviceID: device.id,
                deviceName: device.name,
                pid: process.pid,
                processName: process.name
            )
        } catch {
            emitEngineError(
                subsystem: "collaboration",
                text: "Couldn't take over hosting \(session.processName): \(error.localizedDescription)"
            )
            return false
        }

        if let existingNode = node(forSessionID: session.id) {
            removeNode(existingNode)
        }
        session.host = localUser
        session.deviceID = device.id
        session.deviceName = device.name
        session.processName = process.name
        session.lastKnownPID = process.pid
        session.lastKnownMainModule = nil
        session.lastKnownModules = nil
        session.lastKnownThreads = nil
        session.phase = .attaching
        saveSession(session)

        _ = try? await attach(device: device, process: process, session: session)
        return true
    }

    public func reestablishSession(id sessionID: UUID) async -> ReestablishResult {
        guard var s = try? store.fetchSession(id: sessionID) else {
            return .needsUserInput(
                reason: "Session not found.",
                session: ProcessSession(kind: .attach, deviceID: "", deviceName: "", processName: "", lastKnownPID: 0)
            )
        }

        s.phase = .attaching
        s.detachReason = .applicationRequested
        s.lastError = nil
        saveSession(s)

        let devices = await deviceManager.currentDevices()

        guard let device = devices.first(where: { $0.id == s.deviceID }) else {
            s.phase = .idle
            saveSession(s)
            return .needsUserInput(
                reason: "The saved device \"\(s.deviceName)\" is not available. Choose a device and target to re-establish this session.",
                session: s
            )
        }

        if case .spawn(_) = s.kind {
            _ = try? await spawnAndAttach(device: device, session: s)
            return .attached
        }

        do {
            let processes = try await device.enumerateProcesses(scope: Scope.full)
            let matches = processes.filter { $0.name == s.processName }

            guard !matches.isEmpty else {
                s.phase = .idle
                saveSession(s)
                return .needsUserInput(
                    reason: "No running process named \"\(s.processName)\" was found. Choose a new target to re-establish this session.",
                    session: s
                )
            }

            let chosen: ProcessDetails
            if let exact = matches.first(where: { $0.pid == s.lastKnownPID }) {
                chosen = exact
            } else if matches.count == 1 {
                chosen = matches[0]
            } else {
                s.phase = .idle
                saveSession(s)
                return .needsUserInput(
                    reason: "Multiple processes named \"\(s.processName)\" are running. Choose which one to attach to.",
                    session: s
                )
            }

            s.deviceName = device.name
            saveSession(s)

            try await performAttach(device: device, process: chosen, session: s)
            return .attached
        } catch {
            s.lastError = error.localizedDescription
            s.phase = .idle
            saveSession(s)
            return .needsUserInput(
                reason: "Quick re-establish failed for \"\(s.processName)\". Choose a new target.",
                session: s
            )
        }
    }

    // MARK: - Instrument Lifecycle

    @discardableResult
    public func addInstrument(
        kind: InstrumentKind,
        sourceIdentifier: String,
        configJSON: Data,
        sessionID: UUID
    ) async -> InstrumentInstance? {
        if isHostedRemotelyLive(sessionID) {
            collaboration.sendInstrumentAdd(
                sessionID: sessionID,
                kind: kind,
                sourceIdentifier: sourceIdentifier,
                configJSON: configJSON
            )
            return nil
        }
        let instance = InstrumentInstance(
            sessionID: sessionID,
            kind: kind,
            sourceIdentifier: sourceIdentifier,
            configJSON: configJSON
        )
        try? store.save(instance)
        onSessionListChanged?(.instrumentAdded(instance))

        if let node = node(forSessionID: sessionID) {
            node.addInstrument(ProcessNode.InstrumentRef(
                id: instance.id, kind: instance.kind,
                sourceIdentifier: instance.sourceIdentifier,
                configJSON: instance.configJSON,
                state: instance.state
            ))

            await loadInstrumentOnNode(
                instanceID: instance.id,
                kind: instance.kind,
                sourceIdentifier: instance.sourceIdentifier,
                configJSON: instance.configJSON,
                node: node,
                sessionID: sessionID
            )

            if let sid = collabSessionID(forNode: node) {
                collaboration.enqueueAddInstrument(sessionID: sid, instance: instance)
            }
        }

        return instance
    }

    public func removeInstrument(_ instance: InstrumentInstance) async {
        if isHostedRemotelyLive(instance.sessionID) {
            collaboration.sendInstrumentRemove(sessionID: instance.sessionID, instanceID: instance.id)
            return
        }
        var sid: UUID? = nil
        if let node = node(forSessionID: instance.sessionID) {
            sid = collabSessionID(forNode: node)
            if node.instruments.first(where: { $0.id == instance.id })?.attachment == .attached {
                try? await node.disposeInstrumentOnAgent(instanceID: instance.id)
            }
            node.removeInstrument(id: instance.id)
        }
        try? store.deleteInstrument(id: instance.id)
        try? store.deleteWidgetStates(instanceID: instance.id)
        widgetStates.removeValue(forKey: instance.id)
        onSessionListChanged?(.instrumentRemoved(id: instance.id, sessionID: instance.sessionID))
        rebuildAddressAnnotations(sessionID: instance.sessionID)
        if let sid {
            collaboration.enqueueRemoveInstrument(sessionID: sid, instanceID: instance.id)
        }
    }

    public func setInstrumentState(_ instance: InstrumentInstance, state: InstrumentState) async {
        if isHostedRemotelyLive(instance.sessionID) {
            collaboration.sendInstrumentSetState(
                sessionID: instance.sessionID,
                instanceID: instance.id,
                state: state
            )
            return
        }
        var inst = instance
        inst.state = state
        try? store.save(inst)
        onSessionListChanged?(.instrumentUpdated(inst))
        broadcastInstrumentUpdate(inst)

        guard let node = node(forSessionID: inst.sessionID) else { return }

        switch state {
        case .enabled:
            guard node.instruments.first(where: { $0.id == inst.id })?.attachment != .attached else { return }

            await loadInstrumentOnNode(
                instanceID: inst.id,
                kind: inst.kind,
                sourceIdentifier: inst.sourceIdentifier,
                configJSON: inst.configJSON,
                node: node,
                sessionID: inst.sessionID
            )
        case .disabled:
            if node.instruments.first(where: { $0.id == inst.id })?.attachment == .attached {
                try? await node.disposeInstrumentOnAgent(instanceID: inst.id)
                node.markInstrumentDetached(id: inst.id)
            }
        }
    }

    public func applyInstrumentConfig(_ instance: InstrumentInstance, configJSON: Data) async {
        if isHostedRemotelyLive(instance.sessionID) {
            collaboration.sendInstrumentUpdateConfig(
                sessionID: instance.sessionID,
                instanceID: instance.id,
                configJSON: configJSON
            )
            return
        }
        var inst = instance
        inst.configJSON = configJSON
        try? store.save(inst)
        onSessionListChanged?(.instrumentUpdated(inst))
        broadcastInstrumentUpdate(inst)

        guard let node = node(forSessionID: inst.sessionID) else { return }

        node.updateInstrumentConfig(id: inst.id, configJSON: configJSON)

        guard node.instruments.first(where: { $0.id == inst.id })?.attachment == .attached else { return }

        let configObject: JSONObject
        switch inst.kind {
        case .tracer:
            let config = (try? TracerConfig.decode(from: configJSON)) ?? TracerConfig()
            do {
                let paths = try compilerWorkspacePaths()
                configObject = try await compileTracerConfig(config, paths: paths)
                node.replaceComponentStatuses(instrumentID: inst.id, [:])
                broadcastInstrumentStatus(instanceID: inst.id, sessionID: node.sessionID)
            } catch let failures as TracerHookCompileFailures {
                applyHookCompileFailures(failures, on: node, instrumentID: inst.id)
                return
            } catch {
                node.setInstrumentStatus(id: inst.id, .from(error: error, kind: .configInvalid))
                broadcastInstrumentStatus(instanceID: inst.id, sessionID: node.sessionID)
                return
            }

        case .hookPack:
            let config = (try? HookPackConfig.decode(from: configJSON))
                ?? HookPackConfig(packId: inst.sourceIdentifier, features: [:])
            guard let pack = hookPacks.pack(withId: inst.sourceIdentifier) else { return }
            configObject = config.toAgentJSON(features: pack.manifest.features)

        case .codeShare:
            configObject = (try? JSONSerialization.jsonObject(with: configJSON, options: []) as? JSONObject) ?? [:]

        case .custom:
            let cfg = (try? CustomInstrumentConfig.decode(from: configJSON))
                ?? CustomInstrumentConfig(defID: UUID(uuidString: inst.sourceIdentifier) ?? UUID())
            guard let def = customInstrumentDef(for: cfg) else { return }
            configObject = cfg.toAgentJSON(def: def)
        }

        do {
            try await node.pushInstrumentConfig(instanceID: inst.id, config: configObject)
            node.clearInstrumentStatus(id: inst.id)
            broadcastInstrumentStatus(instanceID: inst.id, sessionID: node.sessionID)
        } catch {
            node.setInstrumentStatus(id: inst.id, .from(error: error, kind: .configInvalid))
            broadcastInstrumentStatus(instanceID: inst.id, sessionID: node.sessionID)
        }

        if inst.kind == .tracer {
            rebuildAddressAnnotations(sessionID: inst.sessionID)
        }
    }

    private func loadInstrumentOnNode(
        instanceID: UUID,
        kind: InstrumentKind,
        sourceIdentifier: String,
        configJSON: Data,
        node: ProcessNode,
        sessionID: UUID
    ) async {
        do {
            switch kind {
            case .tracer:
                try await loadTracerInstrument(
                    instanceID: instanceID,
                    config: (try? TracerConfig.decode(from: configJSON)) ?? TracerConfig(),
                    sessionID: sessionID,
                    paths: try compilerWorkspacePaths()
                )

            case .hookPack:
                guard let pack = hookPacks.pack(withId: sourceIdentifier) else { return }
                if await skipIfIncompatible(instanceID: instanceID, compatibility: pack.manifest.compatibility, on: node) {
                    return
                }
                try await loadHookPackInstrument(
                    instanceID: instanceID,
                    pack: pack,
                    configJSON: configJSON,
                    on: node
                )

            case .codeShare:
                let cfg = try JSONDecoder().decode(CodeShareConfig.self, from: configJSON)
                try await loadCodeShareInstrument(
                    instanceID: instanceID,
                    config: cfg,
                    configJSON: configJSON,
                    on: node
                )

            case .custom:
                let cfg = (try? CustomInstrumentConfig.decode(from: configJSON))
                    ?? CustomInstrumentConfig(defID: UUID(uuidString: sourceIdentifier) ?? UUID())
                guard let bundle = customInstrumentBundle(for: cfg) else { return }
                if await skipIfIncompatible(instanceID: instanceID, compatibility: bundle.def.compatibility, on: node) {
                    return
                }
                try await loadCustomInstrument(
                    instanceID: instanceID,
                    bundle: bundle,
                    config: cfg,
                    on: node
                )
            }

            node.markInstrumentAttached(id: instanceID)
            node.replaceComponentStatuses(instrumentID: instanceID, [:])
            broadcastInstrumentStatus(instanceID: instanceID, sessionID: node.sessionID)
        } catch let failures as TracerHookCompileFailures {
            applyHookCompileFailures(failures, on: node, instrumentID: instanceID)
        } catch {
            node.setInstrumentStatus(id: instanceID, .from(error: error, kind: .load))
            broadcastInstrumentStatus(instanceID: instanceID, sessionID: node.sessionID)
        }
    }

    private func applyHookCompileFailures(
        _ failures: TracerHookCompileFailures,
        on node: ProcessNode,
        instrumentID: UUID
    ) {
        let statuses = failures.hookErrors.mapValues { InstrumentStatus.from(error: $0, kind: .configInvalid) }
        node.clearInstrumentStatus(id: instrumentID)
        node.replaceComponentStatuses(instrumentID: instrumentID, statuses)
        broadcastInstrumentStatus(instanceID: instrumentID, sessionID: node.sessionID)
    }

    private func skipIfIncompatible(
        instanceID: UUID,
        compatibility: InstrumentCompatibility,
        on node: ProcessNode
    ) async -> Bool {
        guard !compatibility.isUniversal else {
            node.clearInstrumentStatus(id: instanceID)
            return false
        }
        guard let params = await systemParameters.parameters(for: node.device) else {
            node.clearInstrumentStatus(id: instanceID)
            return false
        }
        guard let reason = compatibility.incompatibilityReason(for: params) else {
            node.clearInstrumentStatus(id: instanceID)
            return false
        }
        node.setInstrumentStatus(id: instanceID, .incompatible(reason: reason))
        broadcastInstrumentStatus(instanceID: instanceID, sessionID: node.sessionID)
        return true
    }

    // MARK: - Tracer Hook

    public func addTracerHook(
        sessionID: UUID,
        address: UInt64,
        kind: TracerHookKind,
        code: String? = nil,
        preferredAnchor: AddressAnchor? = nil,
        preferredDisplayName: String? = nil
    ) async -> (instrumentID: UUID, hookID: UUID)? {
        guard (try? store.fetchSession(id: sessionID)) != nil else { return nil }

        let anchor: AddressAnchor
        if let preferredAnchor {
            anchor = preferredAnchor
        } else if let node = node(forSessionID: sessionID) {
            anchor = node.anchor(for: address)
        } else {
            anchor = .absolute(address)
        }

        let displayName = preferredDisplayName?.isEmpty == false
            ? preferredDisplayName!
            : anchor.symbolName
        let hookCode = code ?? defaultTracerCode(kind: kind, anchor: anchor, displayName: displayName)
        let newHook = TracerConfig.Hook(
            id: UUID(),
            displayName: displayName,
            addressAnchor: anchor,
            kind: kind,
            code: hookCode
        )

        if let existing = tracerInstance(forSessionID: sessionID) {
            var config = (try? TracerConfig.decode(from: existing.configJSON)) ?? TracerConfig()
            if let existingID = await existingHookID(in: config, anchor: anchor, sessionID: sessionID) {
                return (instrumentID: existing.id, hookID: existingID)
            }
            config.hooks.append(newHook)
            await applyInstrumentConfig(existing, configJSON: config.encode())
            return (instrumentID: existing.id, hookID: newHook.id)
        }

        var initialConfig = TracerConfig()
        initialConfig.hooks.append(newHook)
        guard let added = await addInstrument(
            kind: .tracer,
            sourceIdentifier: "builtin.tracer",
            configJSON: initialConfig.encode(),
            sessionID: sessionID
        ) else { return nil }
        return (instrumentID: added.id, hookID: newHook.id)
    }

    private func existingHookID(in config: TracerConfig, anchor: AddressAnchor, sessionID: UUID) async -> UUID? {
        if let exact = config.hooks.first(where: { $0.addressAnchor == anchor }) {
            return exact.id
        }
        guard let node = node(forSessionID: sessionID),
            let target = try? await node.resolve(anchor)
        else { return nil }
        for hook in config.hooks where hook.addressAnchor != anchor {
            if let resolved = try? await node.resolve(hook.addressAnchor), resolved == target {
                return hook.id
            }
        }
        return nil
    }

    // MARK: - Address Actions

    public func registerAddressActionProvider(_ provider: @escaping AddressActionProvider) {
        addressActionProviders.append(provider)
    }

    public func registerThreadActionProvider(_ provider: @escaping ThreadActionProvider) {
        threadActionProviders.append(provider)
    }

    public func threadActions(sessionID: UUID, thread: ProcessThread) -> [ThreadAction] {
        threadActionProviders.flatMap { $0(sessionID, thread) }
    }

    public func addressActions(
        sessionID: UUID,
        address: UInt64,
        context: AddressContext = AddressContext(),
        facts: AddressFacts
    ) -> [AddressAction] {
        addressActionProviders.flatMap { $0(sessionID, address, context, facts) }
    }

    private func tracerAddressActions(
        sessionID: UUID,
        address: UInt64,
        context: AddressContext,
        facts: AddressFacts
    ) -> [AddressAction] {
        if let tracerID = tracerInstanceIDBySession[sessionID],
            let hookID = addressAnnotations[sessionID]?[address]?.tracerHookID
        {
            return [
                AddressAction(
                    title: "Go to Hook",
                    systemImage: "arrow.turn.down.right",
                    perform: {
                        .instrumentComponent(sessionID: sessionID, instrumentID: tracerID, componentID: hookID)
                    }
                )
            ]
        }

        guard facts.mapping == .executable else {
            return []
        }

        var actions: [AddressAction] = []
        if facts.isFunctionStart {
            actions.append(tracerHookAction(sessionID: sessionID, address: address, kind: .function, title: "Add Function Hook\u{2026}", anchor: context.anchorHint))
        }
        actions.append(tracerHookAction(sessionID: sessionID, address: address, kind: .instruction, title: "Add Instruction Hook\u{2026}", anchor: context.anchorHint))
        return actions
    }

    private func tracerHookAction(
        sessionID: UUID,
        address: UInt64,
        kind: TracerHookKind,
        title: String,
        anchor: AddressAnchor?
    ) -> AddressAction {
        AddressAction(
            title: title,
            systemImage: kind == .function ? "f.cursive" : "i.square",
            perform: { [weak self] in
                guard let self,
                    let result = await self.addTracerHook(
                        sessionID: sessionID,
                        address: address,
                        kind: kind,
                        preferredAnchor: anchor
                    )
                else { return nil }
                return .instrumentComponent(
                    sessionID: sessionID,
                    instrumentID: result.instrumentID,
                    componentID: result.hookID
                )
            }
        )
    }

    // MARK: - Address Facts

    private struct ProtectionRegion {
        let range: Range<UInt64>
        let executable: Bool
    }

    private static let protectionPageMask: UInt64 = 0xfff

    public func addressFacts(
        sessionID: UUID,
        address: UInt64,
        context: AddressContext = AddressContext()
    ) async -> AddressFacts {
        switch context.kind {
        case .function:
            return AddressFacts(mapping: .executable, isFunctionStart: true)
        case .data:
            return AddressFacts(mapping: .data)
        case .code:
            guard node(forSessionID: sessionID) != nil else {
                return AddressFacts(mapping: .executable)
            }
            return AddressFacts(mapping: .executable, isFunctionStart: await resolveFunctionStart(sessionID: sessionID, address: address))
        case .unspecified:
            break
        }

        guard node(forSessionID: sessionID) != nil else {
            return AddressFacts(mapping: .unmapped)
        }
        let mapping = await resolveMapping(sessionID: sessionID, address: address)
        guard mapping == .executable else {
            return AddressFacts(mapping: mapping)
        }
        let isFunctionStart = await resolveFunctionStart(sessionID: sessionID, address: address)
        return AddressFacts(mapping: .executable, isFunctionStart: isFunctionStart)
    }

    private func resolveMapping(sessionID: UUID, address: UInt64) async -> AddressFacts.Mapping {
        if let cached = cachedMapping(sessionID: sessionID, address: address) {
            return cached
        }
        let pageBase = address & ~Self.protectionPageMask
        if let inFlight = mappingProbesBySession[sessionID]?[pageBase] {
            return await inFlight.value
        }
        let probe = Task { [weak self] () -> AddressFacts.Mapping in
            await self?.fetchMapping(sessionID: sessionID, address: address, pageBase: pageBase) ?? .unmapped
        }
        mappingProbesBySession[sessionID, default: [:]][pageBase] = probe
        let mapping = await probe.value
        mappingProbesBySession[sessionID]?[pageBase] = nil
        return mapping
    }

    private func cachedMapping(sessionID: UUID, address: UInt64) -> AddressFacts.Mapping? {
        if let region = protectionRegionsBySession[sessionID]?.first(where: { $0.range.contains(address) }) {
            return region.executable ? .executable : .data
        }
        let pageBase = address & ~Self.protectionPageMask
        if unmappedPagesBySession[sessionID]?.contains(pageBase) == true {
            return .unmapped
        }
        return nil
    }

    private func fetchMapping(sessionID: UUID, address: UInt64, pageBase: UInt64) async -> AddressFacts.Mapping {
        if let cached = cachedMapping(sessionID: sessionID, address: address) {
            return cached
        }
        guard let node = node(forSessionID: sessionID) else {
            return .unmapped
        }
        guard let range = try? await node.findRangeByAddress(address) else {
            unmappedPagesBySession[sessionID, default: []].insert(pageBase)
            return .unmapped
        }
        let executable = range.protection.contains("x")
        protectionRegionsBySession[sessionID, default: []].append(
            ProtectionRegion(range: range.base..<(range.base &+ range.size), executable: executable))
        return executable ? .executable : .data
    }

    private func invalidateAddressFacts(sessionID: UUID, identity: String) {
        guard factsIdentityBySession[sessionID] != identity else { return }
        factsIdentityBySession[sessionID] = identity
        protectionRegionsBySession[sessionID] = nil
        unmappedPagesBySession[sessionID] = nil
        functionStartsBySession[sessionID] = nil
        mappingProbesBySession[sessionID] = nil
    }

    private func resolveFunctionStart(sessionID: UUID, address: UInt64) async -> Bool {
        if let cached = functionStartsBySession[sessionID]?[address] {
            return cached
        }
        guard let disassembler = disassembler(forSessionID: sessionID) else { return false }
        let isFunctionStart = await disassembler.findFunctionStart(containing: address) == address
        functionStartsBySession[sessionID, default: [:]][address] = isFunctionStart
        return isFunctionStart
    }

    private func threadTraceActions(sessionID: UUID, thread: ProcessThread) -> [ThreadAction] {
        guard node(forSessionID: sessionID) != nil else { return [] }
        let threadID = thread.id
        let threadName = thread.name
        return [
            ThreadAction(
                title: "Trace Thread\u{2026}",
                systemImage: "waveform",
                perform: { [weak self] in
                    guard let self else { return nil }
                    guard let trace = await self.startThreadTrace(
                        sessionID: sessionID,
                        threadID: threadID,
                        threadName: threadName
                    ) else { return nil }
                    return .itrace(sessionID: sessionID, traceID: trace.id)
                }
            )
        ]
    }

    @discardableResult
    public func startThreadTrace(
        sessionID: UUID,
        threadID: UInt,
        threadName: String?
    ) async -> ITrace? {
        guard let node = node(forSessionID: sessionID) else { return nil }

        let threadTrace = TracerConfig.ThreadTrace(threadID: threadID, threadName: threadName)
        let trace = ITrace(
            id: threadTrace.id,
            sessionID: sessionID,
            origin: .thread(threadID: threadID, threadName: threadName),
            displayName: threadName.map { "Thread trace: \($0)" } ?? "Thread trace: tid \(threadID)",
            startedAt: Date()
        )
        try? store.save(trace)
        onSessionListChanged?(.traceUpdated(trace))

        await addThreadTraceToTracer(sessionID: sessionID, threadTrace: threadTrace)

        if let sid = collabSessionID(forNode: node) {
            collaboration.enqueueUpsertTrace(sessionID: sid, trace: trace)
        }

        return trace
    }

    private func addThreadTraceToTracer(sessionID: UUID, threadTrace: TracerConfig.ThreadTrace) async {
        if let existing = tracerInstance(forSessionID: sessionID) {
            var config = (try? TracerConfig.decode(from: existing.configJSON)) ?? TracerConfig()
            config.threadTraces.append(threadTrace)
            await applyInstrumentConfig(existing, configJSON: config.encode())
            return
        }

        var initialConfig = TracerConfig()
        initialConfig.threadTraces.append(threadTrace)
        _ = await addInstrument(
            kind: .tracer,
            sourceIdentifier: "builtin.tracer",
            configJSON: initialConfig.encode(),
            sessionID: sessionID
        )
    }

    public func stopThreadTrace(traceID: UUID, sessionID: UUID) async {
        guard let existing = tracerInstance(forSessionID: sessionID) else { return }
        var config = (try? TracerConfig.decode(from: existing.configJSON)) ?? TracerConfig()
        guard config.threadTraces.contains(where: { $0.id == traceID }) else { return }
        config.threadTraces.removeAll { $0.id == traceID }
        await applyInstrumentConfig(existing, configJSON: config.encode())
    }

    public func decodeTrace(traceID: UUID, sessionID: UUID) async -> DecodedITrace? {
        let sessionTraces = tracesBySession[sessionID] ?? []
        guard let trace = sessionTraces.first(where: { $0.id == traceID }) else { return nil }
        do {
            let data = try await loadTraceData(traceID: traceID, sessionID: sessionID, expectedSize: trace.dataSize)
            return try ITraceDecoder.decode(traceData: data, metadataJSON: trace.metadataJSON)
        } catch {
            return nil
        }
    }

    // MARK: - Address Annotations

    public func rebuildAddressAnnotations(sessionID: UUID) {
        let node = node(forSessionID: sessionID)
        let resolve = anchorResolver(sessionID: sessionID, node: node)

        var map: [UInt64: AddressAnnotation] = [:]

        if let tracer = tracerInstance(forSessionID: sessionID),
            let config = try? TracerConfig.decode(from: tracer.configJSON)
        {
            tracerInstanceIDBySession[sessionID] = tracer.id
            for hook in config.hooks where hook.state == .enabled {
                guard let addr = resolve(hook.addressAnchor) else { continue }
                var ann = map[addr] ?? AddressAnnotation()
                ann.decorations.append(InstrumentAddressDecoration(help: "Has instruction hook"))
                ann.tracerHookID = hook.id
                map[addr] = ann
            }
        } else {
            tracerInstanceIDBySession[sessionID] = nil
        }

        for note in (try? store.fetchAddressNotes(sessionID: sessionID)) ?? [] {
            guard let addr = resolve(note.anchor) else { continue }
            var ann = map[addr] ?? AddressAnnotation()
            ann.noteCount += 1
            map[addr] = ann
        }

        addressAnnotations[sessionID] = map
    }

    public func resolveSync(sessionID: UUID, anchor: AddressAnchor) -> UInt64? {
        anchorResolver(sessionID: sessionID, node: node(forSessionID: sessionID))(anchor)
    }

    private func anchorResolver(sessionID: UUID, node: ProcessNode?) -> (AddressAnchor) -> UInt64? {
        let modules = modulesSnapshot(forSessionID: sessionID)
        return { anchor in
            if let node, let addr = try? node.resolveSyncIfReady(anchor) {
                return addr
            }
            switch anchor {
            case .absolute(let a):
                return a
            case .moduleOffset(let name, let offset):
                return modules.first(where: { $0.name == name }).map { $0.base &+ offset }
            case .moduleExport, .objcMethod, .swiftFunc, .debugSymbol, .javaMethod:
                return nil
            }
        }
    }

    private func tracerInstance(forSessionID sessionID: UUID) -> InstrumentInstance? {
        let instruments = (try? store.fetchInstruments(sessionID: sessionID)) ?? []
        return instruments.first(where: { $0.kind == .tracer })
    }

    public func tracerHooks(forSessionID sessionID: UUID) -> [TracerConfig.Hook]? {
        guard let instance = tracerInstance(forSessionID: sessionID),
            let config = try? TracerConfig.decode(from: instance.configJSON)
        else { return nil }
        return config.hooks
    }

    public func tracerHook(sessionID: UUID, hookID: UUID) -> TracerConfig.Hook? {
        tracerHooks(forSessionID: sessionID)?.first(where: { $0.id == hookID })
    }

    @discardableResult
    public func updateTracerHook(
        sessionID: UUID,
        hookID: UUID,
        _ mutate: (inout TracerConfig.Hook) -> Void
    ) async -> TracerConfig.Hook? {
        guard let instance = tracerInstance(forSessionID: sessionID) else { return nil }
        var config = (try? TracerConfig.decode(from: instance.configJSON)) ?? TracerConfig()
        guard let idx = config.hooks.firstIndex(where: { $0.id == hookID }) else { return nil }
        mutate(&config.hooks[idx])
        let updated = config.hooks[idx]
        await applyInstrumentConfig(instance, configJSON: config.encode())
        return updated
    }

    @discardableResult
    public func removeTracerHook(sessionID: UUID, hookID: UUID) async -> Bool {
        guard let instance = tracerInstance(forSessionID: sessionID) else { return false }
        var config = (try? TracerConfig.decode(from: instance.configJSON)) ?? TracerConfig()
        let originalCount = config.hooks.count
        config.hooks.removeAll(where: { $0.id == hookID })
        guard config.hooks.count != originalCount else { return false }
        await applyInstrumentConfig(instance, configJSON: config.encode())
        return true
    }

    // MARK: - Tracer Compilation

    public func compileTracerConfig(
        _ config: TracerConfig,
        paths: CompilerWorkspacePaths
    ) async throws -> JSONObject {
        _ = try await compilerWorkspace.ensureReady(paths: paths)

        let outcomes: [(Int, TracerConfig.Hook, Result<String, Swift.Error>)] =
            await withTaskGroup(of: (Int, TracerConfig.Hook, Result<String, Swift.Error>).self) { group in
                for (index, hook) in config.hooks.enumerated() {
                    group.addTask {
                        do {
                            let js = try await self.compileTracerHook(
                                id: hook.id,
                                displayName: hook.displayName,
                                tsSource: hook.code,
                                paths: paths
                            )
                            return (index, hook, .success(js))
                        } catch {
                            return (index, hook, .failure(error))
                        }
                    }
                }
                var out: [(Int, TracerConfig.Hook, Result<String, Swift.Error>)] = []
                out.reserveCapacity(config.hooks.count)
                for await item in group { out.append(item) }
                return out
            }

        var hookErrors: [UUID: any Swift.Error] = [:]
        var results: [(Int, String, TracerConfig.Hook)] = []
        for (index, hook, outcome) in outcomes {
            switch outcome {
            case .success(let js): results.append((index, js, hook))
            case .failure(let error): hookErrors[hook.id] = error
            }
        }

        guard hookErrors.isEmpty else {
            throw TracerHookCompileFailures(hookErrors: hookErrors)
        }

        var hooksJSON: [JSONObject] = []
        hooksJSON.reserveCapacity(results.count)

        for (_, js, hook) in results.sorted(by: { $0.0 < $1.0 }) {
            var dict: JSONObject = [
                "id": hook.id.uuidString,
                "displayName": hook.displayName,
                "addressAnchor": hook.addressAnchor.toJSON(),
                "state": hook.state.rawValue,
                "code": js,
            ]
            if let arming = hook.itraceArming {
                dict["itraceArming"] = [
                    "maxInvocations": arming.maxInvocations,
                    "maxBytesPerInvocation": arming.maxBytesPerInvocation,
                ] as [String: Any]
            }
            hooksJSON.append(dict)
        }

        return ["hooks": hooksJSON, "threadTraces": config.threadTraces.map(threadTraceJSON)]
    }

    private func threadTraceJSON(_ trace: TracerConfig.ThreadTrace) -> JSONObject {
        [
            "id": trace.id.uuidString,
            "threadId": Int(trace.threadID),
            "threadName": trace.threadName ?? NSNull(),
        ]
    }

    private func compileTracerHook(
        id: UUID,
        displayName: String,
        tsSource: String,
        paths: CompilerWorkspacePaths
    ) async throws -> String {
        let fm = FileManager.default

        let dirRelPath = "TracerHooks"
        let dirURL = paths.root.appendingPathComponent(dirRelPath, isDirectory: true)

        if !fm.fileExists(atPath: dirURL.path) {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        let typingsRelPath = "\(dirRelPath)/luma-tracer-typings.ts"
        let moduleRelPath = "\(dirRelPath)/\(id.uuidString).ts"
        let entryRelPath = "\(dirRelPath)/\(id.uuidString).entry.ts"

        let typingsURL = paths.root.appendingPathComponent(typingsRelPath)
        let moduleURL = paths.root.appendingPathComponent(moduleRelPath)
        let entryURL = paths.root.appendingPathComponent(entryRelPath)

        try TracerTypings.handlerDeclarations.write(to: typingsURL, atomically: true, encoding: .utf8)
        try tsSource.write(to: moduleURL, atomically: true, encoding: .utf8)

        let entrySource = """
            import "./luma-tracer-typings.ts";
            import "./\(id.uuidString).ts";
            export {};
            """
        try entrySource.write(to: entryURL, atomically: true, encoding: .utf8)

        let hookID = id.uuidString
        let userPath = "TracerHooks/\(hookID).ts"
        let entryPath = "TracerHooks/\(hookID).entry.ts"
        let bundle = try await compilerWorkspace.withCompilerDiagnostics(
            label: "tracer hook \(hookID)",
            pathDisplay: { path in
                if path.hasSuffix(userPath) || path.hasSuffix(entryPath) {
                    return displayName
                }
                return path
            }
        ) { compiler in
            try await compiler.build(
                entrypoint: entryRelPath,
                projectRoot: paths.root.path,
                sourceMaps: .omitted,
                compression: .terser)
        }

        let modules = try ESMBundleParser.parse(bundle)
        return modules.modules[modules.order[0]]!
    }

    // MARK: - Instrument Loading

    public func loadTracerInstrument(
        instanceID: UUID,
        config: TracerConfig,
        sessionID: UUID,
        paths: CompilerWorkspacePaths
    ) async throws {
        guard let node = node(forSessionID: sessionID) else { return }

        var compiled = try await compileTracerConfig(config, paths: paths)

        var counters: [String: Int] = [:]
        let traces = (try? store.fetchITraces(sessionID: sessionID)) ?? []
        for trace in traces {
            if case .functionCall(let hookID, let callIndex) = trace.origin {
                let key = hookID.uuidString
                counters[key] = max(counters[key] ?? 0, callIndex + 1)
            }
        }
        if !counters.isEmpty {
            compiled["callCounters"] = counters
        }

        try await node.loadInstrumentOnAgent(
            instanceID: instanceID,
            moduleName: "/builtin/tracer.js",
            source: LumaAgent.tracerSource,
            config: compiled
        )
    }

    public func loadHookPackInstrument(
        instanceID: UUID,
        pack: HookPack,
        configJSON: Data,
        on node: ProcessNode
    ) async throws {
        let config = try InstrumentConfigCodec.decode(HookPackConfig.self, from: configJSON)
        let paths = try compilerWorkspacePaths()
        let sourceSlug = "HookPacks/\(pack.id)"
        let files = try Self.readHookPackFiles(folderURL: pack.folderURL, manifest: pack.manifest)
        let compiledSource = try await compileTypeScriptInstrument(
            sourceSlug: sourceSlug,
            files: files,
            entrypoint: pack.manifest.entrypoint,
            paths: paths,
            diagnosticLabel: "hook pack \(pack.id)"
        )

        let digest = SHA256.hash(data: Data(compiledSource.utf8))
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        let moduleName = "/\(sourceSlug)/\(hashHex).js"

        let restored = hydrateRestoredState(instanceID: instanceID, widgets: pack.manifest.widgets, on: node)

        try await node.loadInstrumentOnAgent(
            instanceID: instanceID,
            moduleName: moduleName,
            source: compiledSource,
            config: config.toAgentJSON(features: pack.manifest.features),
            restored: restored
        )
    }

    public func loadCustomInstrument(
        instanceID: UUID,
        bundle: CustomInstrumentBundle,
        config: CustomInstrumentConfig,
        on node: ProcessNode
    ) async throws {
        let def = bundle.def
        let paths = try compilerWorkspacePaths()
        let sourceSlug = "Custom/\(def.id.uuidString)"
        let files = bundle.files.map { (path: $0.path, content: Data($0.content.utf8)) }
        let compiledSource = try await compileTypeScriptInstrument(
            sourceSlug: sourceSlug,
            files: files,
            entrypoint: def.entrypoint,
            paths: paths,
            diagnosticLabel: "custom instrument \(def.id.uuidString)"
        )

        let digest = SHA256.hash(data: Data(compiledSource.utf8))
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        let moduleName = "/\(sourceSlug)/\(hashHex).js"

        let restored = hydrateRestoredState(instanceID: instanceID, widgets: def.widgets, on: node)

        try await node.loadInstrumentOnAgent(
            instanceID: instanceID,
            moduleName: moduleName,
            source: compiledSource,
            config: config.toAgentJSON(def: def),
            restored: restored
        )
    }

    private func hydrateRestoredState(
        instanceID: UUID,
        widgets: [InstrumentWidget],
        on node: ProcessNode
    ) -> [String: Any] {
        let persistentWidgets = widgets.filter { $0.persistence == .session }
        guard !persistentWidgets.isEmpty else { return [:] }
        let states = (try? store.fetchWidgetStates(instanceID: instanceID)) ?? [:]
        let persistentIDs = Set(persistentWidgets.map(\.id))
        widgetStates[instanceID] = states.filter { persistentIDs.contains($0.key) }
        for widget in persistentWidgets {
            let state = states[widget.id] ?? WidgetState()
            _widgetUpdates.yield(WidgetUpdate(
                instanceID: instanceID,
                widget: widget.id,
                kind: .snapshot(state)
            ))
        }

        var restored: [String: Any] = [:]
        for widget in persistentWidgets {
            let state = states[widget.id] ?? WidgetState()
            switch widget.kind {
            case .counter:
                if let counter = state.counter {
                    var obj: [String: Any] = ["value": counter.value]
                    if let unit = counter.unit { obj["unit"] = unit }
                    if let delta = counter.delta { obj["delta"] = delta }
                    restored[widget.id] = ["counter": obj]
                } else {
                    restored[widget.id] = ["counter": NSNull()]
                }
            case .histogram:
                let buckets = state.histogram.map { ["label": $0.label, "count": $0.count] }
                restored[widget.id] = ["buckets": buckets]
            case .graph:
                let points = state.graphSeries.flatMap { (seriesID, pts) -> [[String: Any]] in
                    pts.map { ["series": seriesID, "x": $0.x, "y": $0.y] }
                }
                restored[widget.id] = ["points": points]
            case .list:
                let items = state.listItems.map { item -> [String: Any] in
                    var obj: [String: Any] = ["id": item.id, "title": item.title]
                    if let s = item.subtitle { obj["subtitle"] = s }
                    if let a = item.accessory { obj["accessory"] = a }
                    return obj
                }
                restored[widget.id] = ["items": items]
            case .table:
                let rows = state.tableRows.map { row -> [String: Any] in
                    ["id": row.id, "cells": row.cells]
                }
                restored[widget.id] = ["rows": rows]
            case .hex:
                if let hex = state.hex {
                    restored[widget.id] = [
                        "hex": [
                            "bytes": hex.bytes.base64EncodedString(),
                            "base_address": hex.baseAddress,
                        ],
                    ]
                } else {
                    restored[widget.id] = ["hex": NSNull()]
                }
            case .console:
                restored[widget.id] = ["entries": state.consoleEntries.map { $0.toWireJSON() }]
            }
        }
        return restored
    }

    public func widgetState(instanceID: UUID, widget: String) -> WidgetState {
        widgetStates[instanceID]?[widget] ?? WidgetState()
    }

    private func hydrateWidgetStatesFromStore(_ grouped: [UUID: [InstrumentInstance]]) {
        for instances in grouped.values {
            for instance in instances {
                guard widgetStates[instance.id] == nil else { continue }
                let widgets = widgets(forInstance: instance)
                let persistent = widgets.filter { $0.persistence == .session }
                guard !persistent.isEmpty else { continue }
                let states = (try? store.fetchWidgetStates(instanceID: instance.id)) ?? [:]
                let persistentIDs = Set(persistent.map(\.id))
                let filtered = states.filter { persistentIDs.contains($0.key) }
                widgetStates[instance.id] = filtered
                for widget in persistent {
                    let state = filtered[widget.id] ?? WidgetState()
                    _widgetUpdates.yield(WidgetUpdate(
                        instanceID: instance.id,
                        widget: widget.id,
                        kind: .snapshot(state)
                    ))
                }
            }
        }
    }

    private func widgets(forInstance instance: InstrumentInstance) -> [InstrumentWidget] {
        switch instance.kind {
        case .custom:
            guard let defID = UUID(uuidString: instance.sourceIdentifier),
                let def = customInstruments.def(withId: defID)
            else { return [] }
            return def.widgets
        case .hookPack:
            return hookPacks.pack(withId: instance.sourceIdentifier)?.manifest.widgets ?? []
        default:
            return []
        }
    }

    private func compileTypeScriptInstrument(
        sourceSlug: String,
        files: [(path: String, content: Data)],
        entrypoint: String,
        paths: CompilerWorkspacePaths,
        diagnosticLabel: String
    ) async throws -> String {
        _ = try await compilerWorkspace.ensureReady(paths: paths)

        let fm = FileManager.default
        let dirRelPath = "InstrumentSources/\(sourceSlug)"
        let dirURL = paths.root.appendingPathComponent(dirRelPath, isDirectory: true)
        if fm.fileExists(atPath: dirURL.path) {
            try fm.removeItem(at: dirURL)
        }
        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)

        for file in files {
            let path = try CustomInstrumentFile.validateRelativePath(file.path)
            let fileURL = dirURL.appendingPathComponent(path)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: fileURL)
        }

        let entryRelPath = "\(dirRelPath)/\(try CustomInstrumentFile.validateRelativePath(entrypoint))"

        let sourcePrefix = "\(dirRelPath)/"
        let bundle = try await compilerWorkspace.withCompilerDiagnostics(
            label: diagnosticLabel,
            pathDisplay: { path in
                guard let range = path.range(of: sourcePrefix) else { return path }
                return String(path[range.upperBound...])
            }
        ) { compiler in
            try await compiler.build(
                entrypoint: entryRelPath,
                projectRoot: paths.root.path,
                sourceMaps: .omitted,
                compression: .terser)
        }

        let modules = try ESMBundleParser.parse(bundle)
        return modules.modules[modules.order[0]]!
    }

    private static func readHookPackFiles(
        folderURL: URL,
        manifest: HookPackManifest
    ) throws -> [(path: String, content: Data)] {
        let fm = FileManager.default
        let iconPath: String? = if case .file(let p) = manifest.icon { p } else { nil }
        let basePath = folderURL.standardizedFileURL.path
        let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var result: [(path: String, content: Data)] = []
        while let url = enumerator?.nextObject() as? URL {
            let isDir = (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let absolute = url.standardizedFileURL.path
            let relativePath = String(absolute.dropFirst(basePath.count + 1))
            if relativePath == "manifest.json" { continue }
            if relativePath == iconPath { continue }
            let data = try Data(contentsOf: url)
            result.append((path: try CustomInstrumentFile.validateRelativePath(relativePath), content: data))
        }
        return result
    }

    private static func validatedCustomInstrumentBundle(_ bundle: CustomInstrumentBundle) throws -> CustomInstrumentBundle {
        let files = try bundle.files.map { file in
            CustomInstrumentFile(
                defID: file.defID,
                path: try CustomInstrumentFile.validateRelativePath(file.path),
                content: file.content
            )
        }
        var def = bundle.def
        def.entrypoint = try validatedEntrypoint(def.entrypoint, files: files)
        return CustomInstrumentBundle(def: def, files: files)
    }

    private static func validatedEntrypoint(_ entrypoint: String, files: [CustomInstrumentFile]) throws -> String {
        let path = try CustomInstrumentFile.validateRelativePath(entrypoint)
        guard files.contains(where: { $0.path == path }) else {
            throw LumaCoreError.invalidArgument("Entrypoint '\(path)' does not exist in this custom instrument.")
        }
        return path
    }

    private func customInstrumentDef(for config: CustomInstrumentConfig) -> CustomInstrumentDef? {
        if let cached = customInstruments.def(withId: config.defID) {
            return cached
        }
        return try? store.fetchCustomInstrumentDef(id: config.defID)
    }

    private func customInstrumentBundle(for config: CustomInstrumentConfig) -> CustomInstrumentBundle? {
        if let cached = customInstruments.bundle(forDefID: config.defID) {
            return cached
        }
        guard let def = try? store.fetchCustomInstrumentDef(id: config.defID),
            let files = try? store.fetchCustomInstrumentFiles(defID: config.defID)
        else { return nil }
        return CustomInstrumentBundle(def: def, files: files)
    }

    // MARK: - Custom Instrument Library API

    @discardableResult
    public func createCustomInstrument(
        name: String = "Custom Instrument",
        icon: InstrumentIcon = .symbolic(InstrumentIconCatalog.default.id)
    ) -> CustomInstrumentDef {
        let now = Date()
        let def = CustomInstrumentDef(
            name: uniquedCustomInstrumentName(name),
            icon: icon,
            entrypoint: CustomInstrumentDef.defaultEntrypointFilename,
            features: [],
            createdAt: now,
            updatedAt: now
        )
        let files = CustomInstrumentDef.defaultEntrypointFiles(defID: def.id)
        try? store.save(def)
        try? store.replaceCustomInstrumentFiles(defID: def.id, files: files)
        registerDescriptor(customInstruments.descriptor(for: def))
        broadcastCustomInstrumentUpsert(defID: def.id)
        onSessionListChanged?(.customInstrumentDefsChanged)
        return def
    }

    public func updateCustomInstrument(_ def: CustomInstrumentDef) {
        var updated = def
        updated.normalize()
        updated.updatedAt = Date()
        try? store.save(updated)
        registerDescriptor(customInstruments.descriptor(for: updated))
        broadcastCustomInstrumentUpsert(defID: updated.id)
        onSessionListChanged?(.customInstrumentDefsChanged)
        scheduleCustomInstrumentReload(defID: updated.id)
    }

    @discardableResult
    public func writeCustomInstrumentFile(defID: UUID, path: String, content: String) throws -> String {
        let validatedPath = try CustomInstrumentFile.validateRelativePath(path)
        let file = CustomInstrumentFile(defID: defID, path: validatedPath, content: content)
        _ = try requireCustomInstrumentDef(defID: defID)
        try store.save(file)
        try store.save(touchUpdatedAt(defID: defID))
        broadcastCustomInstrumentUpsert(defID: defID)
        scheduleCustomInstrumentReload(defID: defID)
        return validatedPath
    }

    public func deleteCustomInstrumentFile(defID: UUID, path: String) throws {
        let validatedPath = try CustomInstrumentFile.validateRelativePath(path)
        let def = try requireCustomInstrumentDef(defID: defID)
        guard def.entrypoint != validatedPath else {
            throw LumaCoreError.invalidOperation("Cannot delete the entrypoint file.")
        }
        try store.deleteCustomInstrumentFile(defID: defID, path: validatedPath)
        try store.save(touchUpdatedAt(defID: defID))
        broadcastCustomInstrumentUpsert(defID: defID)
        scheduleCustomInstrumentReload(defID: defID)
    }

    @discardableResult
    public func renameCustomInstrumentFile(defID: UUID, from: String, to: String) throws -> String {
        let fromPath = try CustomInstrumentFile.validateRelativePath(from)
        let toPath = try CustomInstrumentFile.validateRelativePath(to)
        guard try store.fetchCustomInstrumentFile(defID: defID, path: fromPath) != nil else {
            throw LumaCoreError.invalidArgument("No file '\(fromPath)' in this custom instrument.")
        }
        try store.renameCustomInstrumentFile(defID: defID, from: fromPath, to: toPath)
        var def = try touchUpdatedAt(defID: defID)
        if def.entrypoint == fromPath {
            def.entrypoint = toPath
        }
        try store.save(def)
        broadcastCustomInstrumentUpsert(defID: defID)
        scheduleCustomInstrumentReload(defID: defID)
        return toPath
    }

    @discardableResult
    public func setCustomInstrumentEntrypoint(defID: UUID, path: String) throws -> String {
        let validatedPath = try CustomInstrumentFile.validateRelativePath(path)
        guard try store.fetchCustomInstrumentFile(defID: defID, path: validatedPath) != nil else {
            throw LumaCoreError.invalidArgument("No file '\(validatedPath)' in this custom instrument.")
        }
        var def = try touchUpdatedAt(defID: defID)
        def.entrypoint = validatedPath
        try store.save(def)
        broadcastCustomInstrumentUpsert(defID: defID)
        scheduleCustomInstrumentReload(defID: defID)
        return validatedPath
    }

    private func scheduleCustomInstrumentReload(defID: UUID) {
        if runningCustomInstrumentReloads.contains(defID) {
            pendingCustomInstrumentReloads.insert(defID)
            return
        }
        runningCustomInstrumentReloads.insert(defID)
        Task { [weak self] in
            await self?.drainCustomInstrumentReloads(defID: defID)
        }
    }

    private func drainCustomInstrumentReloads(defID: UUID) async {
        repeat {
            pendingCustomInstrumentReloads.remove(defID)
            await reloadCustomInstrumentInstances(defID: defID)
        } while pendingCustomInstrumentReloads.contains(defID)
        runningCustomInstrumentReloads.remove(defID)
        let waiters = customInstrumentReloadWaiters.removeValue(forKey: defID) ?? []
        for cont in waiters { cont.resume() }
    }

    public func awaitCustomInstrumentReload(defID: UUID) async {
        guard runningCustomInstrumentReloads.contains(defID) else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            customInstrumentReloadWaiters[defID, default: []].append(cont)
        }
    }

    private func requireCustomInstrumentDef(defID: UUID) throws -> CustomInstrumentDef {
        if let cached = customInstruments.def(withId: defID) {
            return cached
        }
        if let stored = try store.fetchCustomInstrumentDef(id: defID) {
            return stored
        }
        throw LumaCoreError.invalidArgument("No custom instrument with id \(defID).")
    }

    private func touchUpdatedAt(defID: UUID) throws -> CustomInstrumentDef {
        var def = try requireCustomInstrumentDef(defID: defID)
        def.updatedAt = Date()
        return def
    }

    @discardableResult
    public func forkHookPackToCustomInstrument(folderURL: URL) throws -> CustomInstrumentDef {
        let manifestURL = folderURL.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(HookPackManifest.self, from: manifestData)

        let icon: InstrumentIcon
        switch manifest.icon {
        case nil:
            icon = .symbolic(InstrumentIconCatalog.default.id)
        case .symbolic(let id):
            icon = .symbolic(id)
        case .file(let path):
            let iconURL = folderURL.appendingPathComponent(try CustomInstrumentFile.validateRelativePath(path))
            icon = .pixels(try Data(contentsOf: iconURL))
        }

        let packFiles = try Self.readHookPackFiles(folderURL: folderURL, manifest: manifest)

        let now = Date()
        let defID = UUID()
        let files = try packFiles.map { pf in
            CustomInstrumentFile(
                defID: defID,
                path: try CustomInstrumentFile.validateRelativePath(pf.path),
                content: String(decoding: pf.content, as: UTF8.self)
            )
        }

        var def = CustomInstrumentDef(
            id: defID,
            name: uniquedCustomInstrumentName(manifest.name),
            icon: icon,
            compatibility: manifest.compatibility,
            entrypoint: try Self.validatedEntrypoint(manifest.entrypoint, files: files),
            features: manifest.features,
            widgets: manifest.widgets,
            createdAt: now,
            updatedAt: now
        )
        def.normalize()

        try store.save(def)
        try store.replaceCustomInstrumentFiles(defID: defID, files: files)
        registerDescriptor(customInstruments.descriptor(for: def))
        broadcastCustomInstrumentUpsert(defID: defID)
        onSessionListChanged?(.customInstrumentDefsChanged)
        return def
    }

    public func buildHookPackBundle(for def: CustomInstrumentDef) throws -> HookPackBundle {
        let iconAttachment: HookPackBundle.IconAttachment?
        let manifestIcon: HookPackManifest.Icon?
        switch def.icon {
        case .symbolic(let id):
            manifestIcon = .symbolic(id)
            iconAttachment = nil
        case .pixels(let data):
            let iconName = "icon.png"
            manifestIcon = .file(iconName)
            iconAttachment = HookPackBundle.IconAttachment(filename: iconName, data: data)
        }

        let defFiles = try customInstruments.files(forDefID: def.id).map { file in
            CustomInstrumentFile(
                defID: file.defID,
                path: try CustomInstrumentFile.validateRelativePath(file.path),
                content: file.content
            )
        }
        let entrypoint = try Self.validatedEntrypoint(def.entrypoint, files: defFiles)

        let manifest = HookPackManifest(
            name: def.name,
            icon: manifestIcon,
            compatibility: def.compatibility,
            entrypoint: entrypoint,
            features: def.features,
            widgets: def.widgets
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)

        let bundleFiles = defFiles.map { HookPackBundle.File(path: $0.path, content: Data($0.content.utf8)) }

        return HookPackBundle(
            manifestData: manifestData,
            files: bundleFiles,
            icon: iconAttachment
        )
    }

    public func exportCustomInstrumentAsHookPack(_ def: CustomInstrumentDef, to folderURL: URL) throws {
        let bundle = try buildHookPackBundle(for: def)
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try bundle.manifestData.write(to: folderURL.appendingPathComponent("manifest.json"))
        for file in bundle.files {
            let fileURL = folderURL.appendingPathComponent(file.path)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: fileURL)
        }
        if let icon = bundle.icon {
            try icon.data.write(to: folderURL.appendingPathComponent(icon.filename))
        }
    }

    public func clearWidget(instance: InstrumentInstance, widget: String) {
        applyWidgetUpdate(
            WidgetUpdate(instanceID: instance.id, widget: widget, kind: .clear),
            sessionID: instance.sessionID,
            origin: .local
        )
    }

    private enum WidgetUpdateOrigin {
        case local
        case remote
    }

    private func handleRemoteWidgetActionRequest(
        sessionID: UUID,
        instanceID: UUID,
        widget: String,
        action: String,
        item: String?
    ) {
        guard let instance = instrumentsBySession[sessionID]?.first(where: { $0.id == instanceID }) else { return }
        Task { @MainActor [weak self] in
            await self?.invokeWidgetAction(instance: instance, widget: widget, action: action, item: item)
        }
    }

    private func applyWidgetStateSnapshots(_ snapshots: [WidgetStateSnapshot]) {
        for snapshot in snapshots {
            widgetStates[snapshot.instanceID, default: [:]][snapshot.widget] = snapshot.state
            _widgetUpdates.yield(WidgetUpdate(
                instanceID: snapshot.instanceID,
                widget: snapshot.widget,
                kind: .snapshot(snapshot.state)
            ))
        }
    }

    private func applyWidgetUpdate(_ update: WidgetUpdate, sessionID: UUID, origin: WidgetUpdateOrigin) {
        let widgetDef = widget(forInstanceID: update.instanceID, widgetID: update.widget)
        var states = widgetStates[update.instanceID, default: [:]]
        var state = states[update.widget, default: WidgetState()]
        state.apply(update.kind)
        if let widgetDef { state.cap(to: widgetDef.kind) }
        states[update.widget] = state
        widgetStates[update.instanceID] = states
        _widgetUpdates.yield(update)

        if widgetDef?.persistence == .session {
            try? store.saveWidgetState(
                instanceID: update.instanceID,
                widgetID: update.widget,
                sessionID: sessionID,
                state: state
            )
        }

        if origin == .local, let collabSID = collabSessionID(forSessionID: sessionID) {
            collaboration.sendWidgetUpdate(sessionID: collabSID, update: update)
        }
    }

    public func submitConsoleInput(
        instance: InstrumentInstance,
        widget: String,
        text: String
    ) async {
        let entry = WidgetConsoleEntry(kind: .input, text: text)
        await dispatchConsoleInput(instance: instance, widget: widget, entry: entry)
    }

    public struct ConsoleResponse: Sendable {
        public let inputEntryID: String
        public let replies: [WidgetConsoleEntry]
    }

    /// Submits a console input and awaits replies tagged with `replyTo ==
    /// inputEntry.id`. Returns as soon as the agent signals
    /// `consoleReplyDone(inputEntryID)`, or when `timeout` elapses.
    /// Intended for MCP-style request/response flows.
    public func submitConsoleInputAndAwait(
        instance: InstrumentInstance,
        widget: String,
        text: String,
        timeout: Duration = .seconds(30)
    ) async -> ConsoleResponse {
        let entry = WidgetConsoleEntry(kind: .input, text: text)
        let inputID = entry.id
        let instanceID = instance.id
        let updates = widgetUpdates
        await dispatchConsoleInput(instance: instance, widget: widget, entry: entry)

        let buffer = ConsoleReplyBuffer()
        let collector = Task { @MainActor in
            for await update in updates {
                if Task.isCancelled { return }
                guard update.instanceID == instanceID, update.widget == widget else { continue }
                switch update.kind {
                case .consoleAppend(let candidate) where candidate.replyTo == inputID:
                    await buffer.append(candidate)
                case .consoleReplyDone(let id) where id == inputID:
                    return
                default:
                    continue
                }
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            collector.cancel()
        }
        _ = await collector.value
        deadline.cancel()
        return ConsoleResponse(inputEntryID: inputID, replies: await buffer.snapshot())
    }

    private func dispatchConsoleInput(
        instance: InstrumentInstance,
        widget: String,
        entry: WidgetConsoleEntry
    ) async {
        let update = WidgetUpdate(instanceID: instance.id, widget: widget, kind: .consoleAppend(entry))
        applyWidgetUpdate(update, sessionID: instance.sessionID, origin: .local)

        guard let node = node(forSessionID: instance.sessionID),
            node.instruments.first(where: { $0.id == instance.id })?.attachment == .attached
        else { return }
        do {
            try await node.submitConsoleInput(instanceID: instance.id, widget: widget, entryID: entry.id, text: entry.text)
        } catch {
            emitEngineError(subsystem: "instruments", text: "Failed to submit console input on \(widget): \(userFacingMessage(error))")
        }
    }

    public func invokeWidgetAction(
        instance: InstrumentInstance,
        widget: String,
        action: String,
        item: String? = nil
    ) async {
        if isHostedRemotelyLive(instance.sessionID) {
            collaboration.sendWidgetAction(
                sessionID: instance.sessionID,
                instanceID: instance.id,
                widget: widget,
                action: action,
                item: item
            )
            return
        }
        guard let node = node(forSessionID: instance.sessionID),
            node.instruments.first(where: { $0.id == instance.id })?.attachment == .attached
        else { return }
        do {
            try await node.invokeWidgetAction(instanceID: instance.id, widget: widget, action: action, item: item)
        } catch {
            emitEngineError(subsystem: "instruments", text: "Failed to invoke widget action \(widget).\(action): \(userFacingMessage(error))")
        }
    }

public func deleteCustomInstrument(_ defID: UUID) async {
        let key = defID.uuidString
        let doomedInstances = instrumentsBySession.values
            .flatMap { $0 }
            .filter { $0.kind == .custom && $0.sourceIdentifier == key }
        for instance in doomedInstances {
            await removeInstrument(instance)
        }
        try? store.deleteCustomInstrumentDef(id: defID)
        broadcastCustomInstrumentRemove(defID: defID)
        onSessionListChanged?(.customInstrumentDefsChanged)
    }

    private func uniquedCustomInstrumentName(_ proposed: String) -> String {
        let existing = Set(customInstruments.defs.map(\.name))
        if !existing.contains(proposed) { return proposed }
        var n = 2
        while existing.contains("\(proposed) \(n)") { n += 1 }
        return "\(proposed) \(n)"
    }

    private func reloadCustomInstrumentInstances(defID: UUID) async {
        guard let def = try? store.fetchCustomInstrumentDef(id: defID),
            let storeFiles = try? store.fetchCustomInstrumentFiles(defID: defID)
        else { return }
        let bundle = CustomInstrumentBundle(def: def, files: storeFiles)
        let key = defID.uuidString
        for (sessionID, instances) in instrumentsBySession {
            for inst in instances where inst.kind == .custom && inst.sourceIdentifier == key && inst.state == .enabled {
                guard let node = node(forSessionID: sessionID) else { continue }
                let wasAttached = node.instruments.first(where: { $0.id == inst.id })?.attachment == .attached
                let originalCfg = (try? CustomInstrumentConfig.decode(from: inst.configJSON))
                    ?? CustomInstrumentConfig(defID: defID)
                let cfg = originalCfg.normalized(against: def)
                let liveInstance = persistNormalizedConfigIfChanged(
                    instance: inst,
                    originalConfig: originalCfg,
                    normalizedConfig: cfg
                )
                if wasAttached {
                    do {
                        try await node.disposeInstrumentOnAgent(instanceID: liveInstance.id)
                    } catch {
                        emitEngineError(
                            subsystem: "instruments",
                            text: "Failed to dispose custom instance \(liveInstance.id): \(userFacingMessage(error))"
                        )
                    }
                    node.markInstrumentDetached(id: liveInstance.id)
                }
                if await skipIfIncompatible(instanceID: liveInstance.id, compatibility: def.compatibility, on: node) {
                    onSessionListChanged?(.instrumentUpdated(liveInstance))
                    continue
                }
                do {
                    try await loadCustomInstrument(
                        instanceID: liveInstance.id,
                        bundle: bundle,
                        config: cfg,
                        on: node
                    )
                    node.markInstrumentAttached(id: liveInstance.id)
                    broadcastInstrumentStatus(instanceID: liveInstance.id, sessionID: node.sessionID)
                } catch {
                    node.setInstrumentStatus(id: liveInstance.id, .from(error: error, kind: .reload))
                    broadcastInstrumentStatus(instanceID: liveInstance.id, sessionID: node.sessionID)
                }
                onSessionListChanged?(.instrumentUpdated(liveInstance))
            }
        }
    }

    private func persistNormalizedConfigIfChanged(
        instance: InstrumentInstance,
        originalConfig: CustomInstrumentConfig,
        normalizedConfig: CustomInstrumentConfig
    ) -> InstrumentInstance {
        guard normalizedConfig != originalConfig else { return instance }
        var updated = instance
        updated.configJSON = normalizedConfig.encode()
        try? store.save(updated)
        node(forSessionID: updated.sessionID)?.updateInstrumentConfig(id: updated.id, configJSON: updated.configJSON)
        onSessionListChanged?(.instrumentUpdated(updated))
        broadcastInstrumentUpdate(updated)
        return updated
    }

    private func broadcastCustomInstrumentUpsert(defID: UUID) {
        guard let def = try? store.fetchCustomInstrumentDef(id: defID),
            let files = try? store.fetchCustomInstrumentFiles(defID: defID)
        else { return }
        let bundle = CustomInstrumentBundle(def: def, files: files)
        let op = CustomInstrumentOp.upsert(.init(bundle: bundle))
        try? store.saveCustomInstrumentOutboxOp(op)
        collaboration.sendCustomInstrumentOpIfJoined(op)
    }

    private func broadcastCustomInstrumentRemove(defID: UUID) {
        let op = CustomInstrumentOp.remove(.init(defID: defID))
        try? store.saveCustomInstrumentOutboxOp(op)
        collaboration.sendCustomInstrumentOpIfJoined(op)
    }

    public func loadCodeShareInstrument(
        instanceID: UUID,
        config: CodeShareConfig,
        configJSON: Data,
        on node: ProcessNode
    ) async throws {
        let configObject: Any
        if configJSON.isEmpty {
            configObject = [:]
        } else {
            configObject = try JSONSerialization.jsonObject(with: configJSON, options: [])
        }

        let data = Data(config.source.utf8)
        let digest = SHA256.hash(data: data)
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        let moduleName = "/codeshare/\(config.project?.slug ?? config.name)/\(hashHex).js"

        try await node.loadInstrumentOnAgent(
            instanceID: instanceID,
            moduleName: moduleName,
            source: LumaAgent.codeShareSource,
            config: configObject
        )
    }

    // MARK: - Insight Management

    public func getOrCreateInsight(
        sessionID: UUID,
        pointer: UInt64,
        kind: AddressInsight.Kind,
        preferredAnchor: AddressAnchor? = nil
    ) throws -> AddressInsight {
        let anchor = preferredAnchor ?? anchor(sessionID: sessionID, address: pointer)

        let existing = (try? store.fetchInsights(sessionID: sessionID)) ?? []
        if let match = existing.first(where: { $0.kind == kind && $0.anchor == anchor }) {
            return match
        }
        if let match = existing.first(where: { $0.kind == kind && $0.lastResolvedAddress == pointer }) {
            return match
        }

        var insight = AddressInsight(
            sessionID: sessionID,
            kind: kind,
            anchor: anchor
        )
        insight.lastResolvedAddress = pointer
        try store.save(insight)
        upsertInsightCache(insight)
        onSessionListChanged?(.insightAdded(insight))
        if let node = node(forSessionID: sessionID), let sid = collabSessionID(forNode: node) {
            collaboration.enqueueAddInsight(sessionID: sid, insight: insight)
        }
        Task { @MainActor [weak self] in
            await self?.resolveInsightHierarchy(insightID: insight.id, sessionID: sessionID, address: pointer)
        }
        return insight
    }

    private func resolveInsightHierarchy(insightID: UUID, sessionID: UUID, address: UInt64) async {
        guard let dis = disassembler(forSessionID: sessionID),
            let begin = await dis.findFunctionStart(containing: address)
        else { return }
        let siblings = (try? store.fetchInsights(sessionID: sessionID)) ?? []
        guard let self = (try? store.fetchInsights(sessionID: sessionID))?.first(where: { $0.id == insightID }) else { return }

        if begin != address {
            if let parent = siblings.first(where: { $0.lastResolvedAddress == begin }), self.parentInsightID != parent.id {
                var updated = self
                updated.parentInsightID = parent.id
                persistInsight(updated)
                collaboration.enqueueUpdateInsight(sessionID: sessionID, insight: updated)
                emitInsightUpdated(updated)
            }
            return
        }

        guard let end = await dis.findFunctionEnd(containing: address), end > begin else { return }
        for sibling in siblings where sibling.id != insightID && sibling.parentInsightID == nil {
            guard let addr = sibling.lastResolvedAddress, addr > begin, addr < end else { continue }
            var updated = sibling
            updated.parentInsightID = insightID
            persistInsight(updated)
            collaboration.enqueueUpdateInsight(sessionID: sessionID, insight: updated)
            emitInsightUpdated(updated)
        }
    }

    // MARK: - Tracer Event Parsing

    public static func parseTracerEvent(from value: JSInspectValue) -> (
        id: UUID,
        timestamp: Double,
        threadId: Int,
        depth: Int,
        caller: JSInspectValue,
        backtrace: [JSInspectValue]?,
        message: JSInspectValue
    )? {
        guard case .array(_, let elements) = value,
            elements.count == 7
        else { return nil }

        guard case .string(let rawId) = elements[0],
            let id = UUID(uuidString: rawId)
        else { return nil }

        guard case .number(let timestamp) = elements[1] else { return nil }

        guard case .number(let threadIdNum) = elements[2],
            threadIdNum.isFinite,
            threadIdNum.rounded(.towardZero) == threadIdNum
        else { return nil }

        guard case .number(let depthNum) = elements[3],
            depthNum.isFinite,
            depthNum.rounded(.towardZero) == depthNum
        else { return nil }

        let caller = elements[4]
        guard case .nativePointer = caller else { return nil }

        guard case .array(_, let btElements) = elements[5] else { return nil }

        var ptrs: [JSInspectValue] = []
        ptrs.reserveCapacity(btElements.count)
        for e in btElements {
            guard case .nativePointer = e else { return nil }
            ptrs.append(e)
        }

        guard case .array(_, _) = elements[6] else { return nil }

        return (
            id: id,
            timestamp: timestamp,
            threadId: Int(threadIdNum),
            depth: Int(depthNum),
            caller: caller,
            backtrace: ptrs.isEmpty ? nil : ptrs,
            message: elements[6]
        )
    }

    // MARK: - Compiler Workspace Paths

    public func compilerWorkspacePaths() throws -> CompilerWorkspacePaths {
        let packagesState = try store.fetchPackagesState()
        let fm = FileManager.default

        let root = dataDirectory
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(packagesState.id.uuidString, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)

        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }

        return CompilerWorkspacePaths(root: root)
    }

    // MARK: - Private Helpers

    private func collabSessionID(forNode node: ProcessNode) -> UUID? {
        guard let session = sessions.first(where: { $0.id == node.sessionID }),
              let host = session.host,
              host.id == collaboration.localUser?.id
        else { return nil }
        return session.id
    }

    private func collabSessionID(forSessionID sessionID: UUID) -> UUID? {
        guard collaboration.isCollaborative,
              sessions.contains(where: { $0.id == sessionID })
        else { return nil }
        return sessionID
    }

    private func routeTracerError(_ event: RuntimeEvent, node: ProcessNode) -> Bool {
        guard case .instrument(let instrumentID, _) = event.source,
            tracerInstanceIDBySession[node.sessionID] == instrumentID,
            case .jsValue(let value) = event.payload,
            case .object(_, let properties) = value,
            jsStringProperty(properties, "type") == "tracer-error",
            let hookIDString = jsStringProperty(properties, "id"),
            let hookID = UUID(uuidString: hookIDString)
        else { return false }

        let message = jsStringProperty(properties, "message") ?? "Unable to install hook."
        var statuses = node.instruments.first(where: { $0.id == instrumentID })?.componentStatuses ?? [:]
        statuses[hookID] = .loadFailed(message: message, stack: nil)
        node.replaceComponentStatuses(instrumentID: instrumentID, statuses)
        broadcastInstrumentStatus(instanceID: instrumentID, sessionID: node.sessionID)
        return true
    }

    private func jsStringProperty(_ properties: [JSInspectValue.Property], _ name: String) -> String? {
        for property in properties {
            if case .string(let key) = property.key, key == name, case .string(let value) = property.value {
                return value
            }
        }
        return nil
    }

    private func subscribeToNodeStreams(_ node: ProcessNode) {
        let sessionID = node.sessionID

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await reason in node.detachEvents {
                guard let self else { return }
                self.updateSession(id: sessionID) {
                    $0.detachReason = reason
                    $0.phase = .idle
                }
                if let sid = self.collabSessionID(forNode: node) {
                    self.collaboration.enqueueUpdateSessionPhase(
                        sessionID: sid,
                        phase: .detached,
                        reason: String(describing: reason)
                    )
                }
                self.removeNode(node)
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await var event in node.events {
                event.sessionID = sessionID
                if self?.routeTracerError(event, node: node) == true {
                    continue
                }
                self?._events.yield(event)
                if let sid = self?.collabSessionID(forNode: node) {
                    switch event.source {
                    case .instrument, .console, .script:
                        self?.collaboration.sendEvent(sessionID: sid, event: event)
                    case .repl, .processOutput, .spawnGating, .engine:
                        break
                    }
                }
            }
        }

        node.evaluateRadare2 = { [weak self] command in
            guard let self else { return .text("Session unavailable.") }
            return await self.radare2REPLValue(forCommand: command, sessionID: sessionID)
        }

        node.completeRadare2 = { [weak self] code, cursor in
            guard let self else { return [] }
            return await self.radare2REPLCompletions(forCode: code, cursor: cursor, sessionID: sessionID)
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await result in node.replResults {
                let resultValue: REPLCell.Result
                switch result.value {
                case .js(let v): resultValue = .js(v)
                case .text(let t): resultValue = .text(t)
                case .styled(let s): resultValue = .styled(s)
                case .binary(let d, let m): resultValue = .binary(d, meta: m)
                }
                let cell = REPLCell(
                    id: result.id,
                    sessionID: sessionID,
                    code: result.code,
                    language: result.language,
                    result: resultValue,
                    timestamp: result.timestamp
                )
                try? self?.store.save(cell)
                self?.onREPLCellAdded?(cell)
                if let sid = self?.collabSessionID(forNode: node) {
                    self?.collaboration.enqueueAddReplCell(sessionID: sid, cell: cell)
                }
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await trace in node.traceUpdates {
                var stored = trace
                stored.sessionID = sessionID
                try? self?.store.save(stored)
                self?.onSessionListChanged?(.traceUpdated(stored))
                if let sid = self?.collabSessionID(forNode: node) {
                    self?.collaboration.enqueueUpsertTrace(sessionID: sid, trace: stored)
                    await self?.uploadTraceDelta(stored, collabSessionID: sid)
                }
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await delta in node.moduleDeltas {
                self?.updateSession(id: sessionID) { session in
                    session.lastKnownModules = delta.applied(to: session.lastKnownModules)
                }
                self?.rebuildAddressAnnotations(sessionID: sessionID)
                self?.restoreReplSeek(sessionID: sessionID)
                if let sid = self?.collabSessionID(forNode: node) {
                    self?.collaboration.enqueueUpdateSessionModules(sessionID: sid, delta: delta)
                }
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await delta in node.threadDeltas {
                self?.updateSession(id: sessionID) { session in
                    session.lastKnownThreads = delta.applied(to: session.lastKnownThreads)
                }
                if let sid = self?.collabSessionID(forNode: node) {
                    self?.collaboration.enqueueUpdateSessionThreads(sessionID: sid, delta: delta)
                }
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await update in node.widgetUpdates {
                self?.applyWidgetUpdate(update, sessionID: sessionID, origin: .local)
            }
        }
    }

    private func widget(forInstanceID instanceID: UUID, widgetID: String) -> InstrumentWidget? {
        guard let instance = instrumentsBySession.values.flatMap({ $0 }).first(where: { $0.id == instanceID }) else {
            return nil
        }
        switch instance.kind {
        case .custom:
            guard let defID = UUID(uuidString: instance.sourceIdentifier),
                let def = customInstruments.def(withId: defID)
            else { return nil }
            return def.widgets.first { $0.id == widgetID }
        case .hookPack:
            return hookPacks.pack(withId: instance.sourceIdentifier)?.manifest.widgets.first { $0.id == widgetID }
        default:
            return nil
        }
    }


    private func ensureDeviceEventsHooked(for device: Device) {
        guard deviceEventTasks[device.id] == nil else { return }

        deviceEventTasks[device.id] = Task { [weak self] in
            guard let self else { return }

            for await devEvent in device.events {
                switch devEvent {
                case .output(let data, let fd, let pid):
                    self.handleDeviceOutput(device: device, data: data, fd: fd, pid: pid)

                case .spawnAdded(let details):
                    await self.handleSpawnAdded(device: device, details: details)

                case .lost:
                    self.deviceEventTasks[device.id]?.cancel()
                    self.deviceEventTasks[device.id] = nil
                    self.gatingEnabledDevices.remove(device.id)
                    return

                default:
                    break
                }
            }
        }
    }

    private func handleDeviceOutput(device: Device, data: [UInt8], fd: Int, pid: UInt) {
        guard let node = processNodes.first(where: { $0.deviceID == device.id && $0.pid == pid }) else { return }

        let message: String
        if var text = String(bytes: data, encoding: .utf8) {
            if text.hasSuffix("\r\n") || text.hasSuffix("\n") {
                text.removeLast()
            }
            message = text
        } else {
            message = "(\(data.count) bytes on fd \(fd))"
        }

        _events.yield(RuntimeEvent(
            sessionID: node.sessionID,
            source: .processOutput(fd: fd),
            payload: .raw(message: message, data: data),
            data: data
        ))
    }

    private func handleSpawnAdded(device: Device, details: SpawnDetails) async {
        let identifier = details.identifier ?? ""
        let pid = details.pid
        if let session = matchedArmedSession(forDeviceID: device.id, identifier: identifier) {
            await attachToGatedSpawn(device: device, pid: pid, session: session)
            emitSpawnGatingEvent(
                device: device,
                identifier: details.identifier,
                pid: pid,
                outcome: .captured,
                sessionID: session.id
            )
        } else {
            try? await device.resume(pid)
            emitSpawnGatingEvent(
                device: device,
                identifier: details.identifier,
                pid: pid,
                outcome: .released,
                sessionID: nil
            )
        }
    }

    private func emitSpawnGatingEvent(
        device: Device,
        identifier: String?,
        pid: UInt,
        outcome: RuntimeEvent.SpawnGatingOutcome,
        sessionID: UUID?
    ) {
        let displayIdentifier = identifier ?? "(unnamed)"
        let message: String = {
            switch outcome {
            case .captured:
                return "Captured \(displayIdentifier) (pid \(pid))"
            case .released:
                return "Released \(displayIdentifier) (pid \(pid))"
            }
        }()
        let event = RuntimeEvent(
            sessionID: sessionID,
            source: .spawnGating(
                deviceID: device.id,
                deviceName: device.name,
                identifier: identifier,
                pid: pid,
                outcome: outcome
            ),
            payload: .raw(message: message, data: nil)
        )
        _events.yield(event)
        if outcome == .captured,
           let sessionID,
           let collabID = collabSessionID(forSessionID: sessionID) {
            collaboration.sendEvent(sessionID: collabID, event: event)
        }
    }

    private func matchedArmedSession(forDeviceID deviceID: String, identifier: String) -> ProcessSession? {
        let candidates = sessions
            .filter { $0.deviceID == deviceID }
            .filter { node(forSessionID: $0.id) == nil }
            .compactMap { session -> (ProcessSession, Date)? in
                guard case .armed(_, let armedAt) = session.armingState else { return nil }
                return (session, armedAt)
            }
            .sorted { $0.1 < $1.1 }
        return candidates.first { matches(identifier: identifier, against: $0.0.armingState) }?.0
    }

    private func matches(identifier: String, against state: ProcessSession.ArmingState) -> Bool {
        guard case .armed(let pattern, _) = state else { return false }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(identifier.startIndex..., in: identifier)
        return regex.firstMatch(in: identifier, range: range) != nil
    }

    private func attachToGatedSpawn(device: Device, pid: UInt, session: ProcessSession) async {
        do {
            let processes = try await device.enumerateProcesses(pids: [pid], scope: .full)
            guard let process = processes.first else {
                try? await device.resume(pid)
                return
            }
            try await performAttach(device: device, process: process, session: session)
        } catch {
            try? await device.resume(pid)
            updateSession(id: session.id) {
                $0.lastError = error.localizedDescription
                $0.phase = .idle
            }
            return
        }

        guard self.session(id: session.id)?.phase == .attached else {
            try? await device.resume(pid)
            return
        }

        if shouldAutoResumeOnCapture(session) {
            try? await device.resume(pid)
        } else {
            updateSession(id: session.id) { $0.phase = .awaitingInitialResume }
        }
    }

    private func shouldAutoResumeOnCapture(_ session: ProcessSession) -> Bool {
        if case .spawn(let config) = session.kind { return config.autoResume }
        return true
    }

    // MARK: - Missions

    public func setMissionLiveDeltaSink(
        _ sink: (@MainActor (UUID, LLMTurnEvent) -> Void)?
    ) {
        externalMissionLiveDeltaSink = sink
    }

    public func missionLiveText(missionID: UUID) -> String {
        missionLiveTextByID[missionID] ?? ""
    }

    private func handleMissionLiveEvent(missionID: UUID, event: LLMTurnEvent) {
        switch event {
        case .textDelta(let text):
            missionLiveTextByID[missionID, default: ""] += text
        case .liveTextCleared:
            missionLiveTextByID.removeValue(forKey: missionID)
        default:
            break
        }
        externalMissionLiveDeltaSink?(missionID, event)
    }

    #if canImport(Network) || canImport(CSoup)
    public func registerActiveMCPServer(_ server: MCPServer, for missionID: UUID) {
        activeMCPServersByMissionID[missionID] = server
    }

    public func unregisterActiveMCPServer(for missionID: UUID) {
        activeMCPServersByMissionID.removeValue(forKey: missionID)
    }

    func purgeExternalMCPMissions() {
        guard let missions = try? store.fetchMissions() else { return }
        for mission in missions where mission.providerID == externalMCPProviderID {
            deleteMission(missionID: mission.id)
        }
    }

    public var isExternalMCPRunning: Bool { externalMCPServer != nil }

    public var externalMCPTrustsClient: Bool {
        get { LumaAppState.shared.externalMCPTrustsClient }
        set {
            LumaAppState.shared.externalMCPTrustsClient = newValue
            externalMCPServer?.trustsClientApprovals = newValue
        }
    }

    @discardableResult
    public func enableExternalMCPServer() async throws -> ExternalMCPInfo {
        if let server = externalMCPServer, let url = externalMCPURL, let id = externalMCPMissionID {
            return ExternalMCPInfo(url: url, bearerToken: server.bearerToken, missionID: id)
        }

        let token = try await loadOrMintExternalMCPToken()
        let preferredPort = await loadPreferredExternalMCPPort()

        purgeExternalMCPMissions()

        var mission = Mission(
            goalText: "External tool calls (via MCP)",
            providerID: externalMCPProviderID,
            modelID: externalMCPProviderID,
            tokenBudgetInput: 0,
            tokenBudgetOutput: 0
        )
        mission.status = .running
        try store.save(mission)
        collaboration.enqueueMissionUpsert(mission)
        externalMCPMissionID = mission.id

        let toolNames = missionTools.specs().map(\.name)
        let server = MCPServer(
            engine: self,
            resolveMission: { [weak self] in
                guard let self, let id = self.externalMCPMissionID else { return nil }
                return try? self.store.fetchMission(id: id)
            },
            toolNames: toolNames,
            bearerToken: token
        )
        server.trustsClientApprovals = LumaAppState.shared.externalMCPTrustsClient
        let url = try await server.start(preferredPort: preferredPort)
        externalMCPServer = server
        externalMCPURL = url
        registerActiveMCPServer(server, for: mission.id)

        if let port = url.port.flatMap({ UInt16(exactly: $0) }) {
            await savePreferredExternalMCPPort(port)
        }

        return ExternalMCPInfo(url: url, bearerToken: server.bearerToken, missionID: mission.id)
    }

    public func disableExternalMCPServer() async {
        guard let server = externalMCPServer else { return }
        if let id = externalMCPMissionID {
            unregisterActiveMCPServer(for: id)
            if var m = try? store.fetchMission(id: id) {
                m.status = .completed
                try? store.save(m)
                collaboration.enqueueMissionUpsert(m)
            }
        }
        server.stop()
        externalMCPServer = nil
        externalMCPURL = nil
        externalMCPMissionID = nil
    }

    @discardableResult
    public func rotateExternalMCPToken() async throws -> ExternalMCPInfo? {
        let wasRunning = isExternalMCPRunning
        if wasRunning {
            await disableExternalMCPServer()
        }
        try? await llmCredentials.backing.delete(service: Self.externalMCPCredentialService, account: Self.externalMCPCredentialAccount)
        if wasRunning {
            return try await enableExternalMCPServer()
        }
        return nil
    }

    #endif

    private let externalMCPProviderID = "external"

    private static let externalMCPCredentialService = "luma.mcp.external"
    private static let externalMCPCredentialAccount = "default"
    private static let externalMCPPortAccount = "port"

    private func loadOrMintExternalMCPToken() async throws -> String {
        if let stored = try? await llmCredentials.backing.get(
            service: Self.externalMCPCredentialService,
            account: Self.externalMCPCredentialAccount
        ), !stored.isEmpty {
            return stored
        }
        let bytes = (0..<32).map { _ in UInt8.random(in: .min...UInt8.max) }
        let token = Data(bytes).base64EncodedString()
        try? await llmCredentials.backing.set(
            service: Self.externalMCPCredentialService,
            account: Self.externalMCPCredentialAccount,
            token: token
        )
        return token
    }

    private func loadPreferredExternalMCPPort() async -> UInt16? {
        guard let stored = try? await llmCredentials.backing.get(
            service: Self.externalMCPCredentialService,
            account: Self.externalMCPPortAccount
        ) else { return nil }
        return UInt16(stored)
    }

    private func savePreferredExternalMCPPort(_ port: UInt16) async {
        try? await llmCredentials.backing.set(
            service: Self.externalMCPCredentialService,
            account: Self.externalMCPPortAccount,
            token: String(port)
        )
    }

    @discardableResult
    public func startMission(
        goal: String,
        providerID: String,
        modelID: String,
        tokenBudgetInput: Int,
        tokenBudgetOutput: Int,
        thinkingBudget: Int = 0,
        reasoningEffort: String? = nil,
        temperature: Double? = nil
    ) -> Mission? {
        var mission = Mission(
            goalText: goal,
            providerID: providerID,
            modelID: modelID,
            tokenBudgetInput: tokenBudgetInput,
            tokenBudgetOutput: tokenBudgetOutput,
            thinkingBudget: thinkingBudget,
            reasoningEffort: reasoningEffort,
            temperature: temperature
        )
        do {
            try store.save(mission)
            collaboration.enqueueMissionUpsert(mission)
        } catch {
            return nil
        }
        mission.status = .running
        try? store.save(mission)
        collaboration.enqueueMissionUpsert(mission)
        missionExecutor.start(missionID: mission.id)
        let fallbackModelID = mission.modelID
        Task { @MainActor [weak self] in
            await self?.generateMissionTitle(missionID: mission.id, providerID: providerID, fallbackModelID: fallbackModelID, goal: goal)
        }
        return mission
    }

    private func generateMissionTitle(missionID: UUID, providerID: String, fallbackModelID: String, goal: String) async {
        guard let provider = llmRegistry.provider(id: providerID) else { return }
        let descriptor = provider.descriptor
        let modelID = descriptor.summarizationModelID ?? descriptor.defaultModelID ?? fallbackModelID
        guard !modelID.isEmpty else { return }

        var apiKey: String?
        if descriptor.capabilities.supports(.apiKey) {
            apiKey = try? await llmCredentials.apiKey(providerID: providerID)
            guard let key = apiKey, !key.isEmpty else { return }
        }

        let userPrompt = """
            Label this investigation in two to four punchy words for a sidebar entry. Prefer informal shorthand — verbs and short nouns over formal phrasing (e.g. "Reverse Foo Protocol" not "Reverse Engineer the Foo Protocol for Interop"). No quotes, no punctuation, no preamble — just the label.

            Goal:
            \(goal)
            """
        let request = LLMTurnRequest(
            modelID: modelID,
            systemBlocks: [],
            messages: [LLMMessage(role: .user, blocks: [.text(userPrompt)])],
            tools: [],
            maxOutputTokens: 64,
            thinkingBudget: 0,
            temperature: 0.2
        )

        var collected = ""
        do {
            let baseURL = LumaAppState.shared.providerBaseURL(providerID: providerID).flatMap(URL.init(string:))
            for try await event in provider.streamTurn(request, apiKey: apiKey, baseURL: baseURL) {
                if case .finalMessage(_, let blocks) = event {
                    for block in blocks {
                        if case .text(let t) = block.content {
                            collected += t
                        }
                    }
                }
            }
        } catch {
            return
        }

        let title = sanitizeMissionTitle(collected)
        guard !title.isEmpty else { return }
        if let saved = store.updateMission(id: missionID, { $0.title = title }) {
            collaboration.enqueueMissionUpsert(saved)
        }
    }

    private func sanitizeMissionTitle(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.!?:;"))
        if let nl = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    public func cancelMission(missionID: UUID) {
        missionExecutor.cancel(missionID: missionID)
    }

    public func appendMissionUserMessage(missionID: UUID, text: String) {
        enqueueMissionUserText(missionID: missionID, text: text)
        guard let mission = try? store.fetchMission(id: missionID) else { return }
        switch mission.status {
        case .running, .awaitingApproval:
            break
        case .paused, .completed, .failed, .cancelled, .drafting:
            missionExecutor.resume(missionID: missionID)
        }
    }

    public func sendMissionUserMessageNow(missionID: UUID, text: String) {
        enqueueMissionUserText(missionID: missionID, text: text)
        guard let mission = try? store.fetchMission(id: missionID) else { return }
        switch mission.status {
        case .running:
            missionExecutor.cancel(missionID: missionID)
            missionExecutor.resume(missionID: missionID)
        case .awaitingApproval:
            break
        case .paused, .completed, .failed, .cancelled, .drafting:
            missionExecutor.resume(missionID: missionID)
        }
    }

    private func enqueueMissionUserText(missionID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let saved = store.updateMission(id: missionID, { m in
            m.pendingUserText = mergedSteer(existing: m.pendingUserText, addition: trimmed)
        }) else { return }
        collaboration.enqueueMissionUpsert(saved)
    }

    private func mergedSteer(existing: String, addition: String) -> String {
        existing.isEmpty ? addition : "\(existing)\n\n\(addition)"
    }

    public func deleteMission(missionID: UUID) {
        missionExecutor.cancel(missionID: missionID)
        try? store.deleteMission(id: missionID)
        collaboration.enqueueMissionRemove(missionID: missionID)
    }

    public func approveMissionAction(actionID: UUID) async {
        guard let action = try? store.fetchMissionAction(id: actionID),
            action.status == .pending,
            let mission = try? store.fetchMission(id: action.missionID)
        else { return }

        #if canImport(Network) || canImport(CSoup)
        if let server = activeMCPServersByMissionID[action.missionID] {
            server.approve(actionID: actionID)
            return
        }
        #endif

        var approved = action
        approved.status = .approved
        approved.decidedAt = Date()
        try? store.save(approved)
        collaboration.enqueueMissionAction(approved)

        await missionExecutor.runActionByID(approved.id, mission: mission)

        let stillPending = (try? store.hasPendingMissionActions(missionID: approved.missionID)) ?? false
        if !stillPending {
            missionExecutor.resume(missionID: approved.missionID)
        }
    }

    public func submitUserInputResponse(actionID: UUID, answer: String) {
        guard var action = try? store.fetchMissionAction(id: actionID),
            action.toolName == MissionTools.requestUserInputToolName,
            action.status == .pending
        else { return }
        let payload: [String: Any] = ["answer": answer]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        action.status = .succeeded
        action.decidedAt = Date()
        action.completedAt = Date()
        action.resultJSON = String(data: data, encoding: .utf8)
        action.resultSummary = answer
        try? store.save(action)
        collaboration.enqueueMissionAction(action)

        let stillPending = (try? store.hasPendingMissionActions(missionID: action.missionID)) ?? false
        if !stillPending {
            missionExecutor.resume(missionID: action.missionID)
        }
    }

    public func cancelAddressNoteReply(sessionID: UUID) async {
        activeNoteReplyTasks[sessionID]?.cancel()
        guard let missionID = sessionUIStates[sessionID]?.ambientMissionID else { return }
        let pending = (try? store.fetchPendingMissionActions(missionID: missionID)) ?? []
        for action in pending {
            await rejectMissionAction(actionID: action.id, reason: "User cancelled the note reply.")
        }
    }

    public func rejectMissionAction(actionID: UUID, reason: String? = nil) async {
        guard var action = try? store.fetchMissionAction(id: actionID),
            action.status == .pending
        else { return }

        #if canImport(Network) || canImport(CSoup)
        if let server = activeMCPServersByMissionID[action.missionID] {
            server.reject(actionID: actionID, reason: reason)
            return
        }
        #endif

        action.status = .rejected
        action.decidedAt = Date()
        action.completedAt = Date()
        action.rejectionReason = reason
        try? store.save(action)
        collaboration.enqueueMissionAction(action)

        let stillPending = (try? store.hasPendingMissionActions(missionID: action.missionID)) ?? false
        if !stillPending {
            missionExecutor.resume(missionID: action.missionID)
        }
    }

    public func acceptFinding(findingID: UUID) {
        guard var finding = try? findFinding(id: findingID) else { return }
        finding.status = .accepted
        try? store.save(finding)
        collaboration.enqueueMissionFinding(finding)
    }

    public func refuteFinding(findingID: UUID) {
        guard var finding = try? findFinding(id: findingID) else { return }
        finding.status = .refuted
        try? store.save(finding)
        collaboration.enqueueMissionFinding(finding)
    }

    private func findFinding(id: UUID) throws -> MissionFinding? {
        for mission in missions {
            if let match = (try? store.fetchMissionFindings(missionID: mission.id))?.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    private func applyRemoteMissionSnapshot(_ snapshot: MissionSnapshot) {
        let serverMissionIDs = Set(snapshot.missions.map(\.id))
        let localMissions = (try? store.fetchMissions()) ?? []
        for stale in localMissions where !serverMissionIDs.contains(stale.id) {
            try? store.deleteMission(id: stale.id)
        }
        for mission in snapshot.missions { try? store.save(mission) }
        for turn in snapshot.turns { try? store.save(turn) }
        for action in snapshot.actions { try? store.save(action) }
        for finding in snapshot.findings { try? store.save(finding) }
        for evidence in snapshot.evidence { try? store.save(evidence) }
    }

    private func applyRemoteAddressNoteOp(_ op: AddressNoteOp) {
        switch op {
        case .noteUpsert(let u):
            let existed = (try? store.fetchAddressNote(id: u.note.id)) != nil
            try? store.save(u.note)
            rebuildAddressAnnotations(sessionID: u.note.sessionID)
            onAddressNoteChanged?(existed ? .noteUpdated(u.note) : .noteAdded(u.note))
        case .noteRemove(let r):
            guard let prior = try? store.fetchAddressNote(id: r.noteID) else { return }
            try? store.deleteAddressNote(id: r.noteID)
            rebuildAddressAnnotations(sessionID: prior.sessionID)
            onAddressNoteChanged?(.noteRemoved(prior))
        case .messageAppend(let a):
            try? store.save(a.message)
            onAddressNoteChanged?(.messageAppended(a.message))
        case .messageEdit(let e):
            guard var message = try? store.fetchAddressNoteMessage(id: e.messageID) else { return }
            message.bodyMarkdown = e.bodyMarkdown
            try? store.save(message)
            onAddressNoteChanged?(.messageEdited(message))
        case .messageRemove(let r):
            guard let prior = try? store.fetchAddressNoteMessage(id: r.messageID) else { return }
            try? store.deleteAddressNoteMessage(id: r.messageID)
            onAddressNoteChanged?(.messageRemoved(prior))
        }
    }

    private func applyRemoteMissionOp(_ op: MissionOp) {
        switch op {
        case .missionUpsert(let u):
            try? store.save(u.mission)
        case .missionRemove(let r):
            try? store.deleteMission(id: r.missionID)
        case .turnAppend(let a):
            try? store.save(a.turn)
        case .actionUpsert(let u):
            try? store.save(u.action)
        case .findingUpsert(let u):
            try? store.save(u.finding)
        case .findingRemove(let r):
            try? store.deleteMissionFinding(id: r.findingID)
        case .evidenceAdd(let a):
            try? store.save(a.evidence)
        }
    }
}

public struct TracerHookCompileFailures: Swift.Error {
    public let hookErrors: [UUID: any Swift.Error]
}

@MainActor
final class SessionDisassemblyEnvironment: ModuleIntrospector, MemoryReader, PageKeying {
    private unowned let engine: Engine
    private let sessionID: UUID
    private var uuidCache: [String: String] = [:]
    private var pageAttribution: [UInt64: CachedAttribution] = [:]

    private enum CachedAttribution {
        case module(String)
        case anonymous
        case ephemeral
    }

    init(engine: Engine, sessionID: UUID) {
        self.engine = engine
        self.sessionID = sessionID
    }

    var isAvailable: Bool { engine.node(forSessionID: sessionID) != nil }

    func getModuleIdentity(name: String) async throws -> String? {
        guard let node = engine.node(forSessionID: sessionID) else { return nil }
        return try await node.getModuleIdentity(name: name)
    }

    func enumerateModuleRanges(name: String) async throws -> [ProcessNode.ModuleRange] {
        guard let node = engine.node(forSessionID: sessionID) else { return [] }
        return try await node.enumerateModuleRanges(name: name)
    }

    func enumerateModuleSymbols(name: String) async throws -> ModuleSymbolBundle {
        guard let node = engine.node(forSessionID: sessionID) else {
            throw DisassemblyError.detached
        }
        return try await node.enumerateModuleSymbols(name: name)
    }

    func read(at address: UInt64, count: Int) async throws -> [UInt8] {
        guard let node = engine.node(forSessionID: sessionID) else {
            throw DisassemblyError.detached
        }
        return try await node.readRemoteMemory(at: address, count: count)
    }

    func attribution(pageBase: UInt64) async -> PageAttribution {
        let modules = engine.modulesSnapshot(forSessionID: sessionID)
        if let direct = modules.first(where: { pageBase >= $0.base && pageBase < ($0.base &+ $0.size) }) {
            return .module(direct)
        }
        if let cached = pageAttribution[pageBase] {
            return decode(cached, modules: modules)
        }
        if let mapped = moduleByMappedRanges(pageBase: pageBase, modules: modules) {
            pageAttribution[pageBase] = .module(mapped.path)
            return .module(mapped)
        }
        guard let node = engine.node(forSessionID: sessionID) else {
            return .ephemeral
        }
        guard let range = try? await node.findRangeByAddress(pageBase) else {
            pageAttribution[pageBase] = .ephemeral
            return .ephemeral
        }
        if let filePath = range.filePath, let owner = modules.first(where: { $0.path == filePath }) {
            await ensureModuleIdentified(owner)
            pageAttribution[pageBase] = .module(owner.path)
            return .module(owner)
        }
        pageAttribution[pageBase] = .anonymous
        return .anonymous
    }

    private func decode(_ cached: CachedAttribution, modules: [ProcessModule]) -> PageAttribution {
        switch cached {
        case .module(let path):
            if let m = modules.first(where: { $0.path == path }) { return .module(m) }
            return .ephemeral
        case .anonymous: return .anonymous
        case .ephemeral: return .ephemeral
        }
    }

    private func moduleByMappedRanges(pageBase: UInt64, modules: [ProcessModule]) -> ProcessModule? {
        for module in modules {
            guard let analysis = try? engine.store.fetchModuleAnalysis(sessionID: sessionID, modulePath: module.path) else { continue }
            for range in analysis.mappedRanges {
                let rlo = module.base &+ range.offset
                if pageBase >= rlo && pageBase < (rlo &+ range.size) {
                    return module
                }
            }
        }
        return nil
    }

    private func ensureModuleIdentified(_ module: ProcessModule) async {
        if (try? engine.store.fetchModuleAnalysis(sessionID: sessionID, modulePath: module.path)) != nil { return }
        guard let node = engine.node(forSessionID: sessionID) else { return }
        let identity = try? await node.getModuleIdentity(name: module.path)
        let ranges = (try? await node.enumerateModuleRanges(name: module.path)) ?? []
        let stub = ModuleAnalysis(
            sessionID: sessionID,
            modulePath: module.path,
            moduleUUID: identity,
            mappedRanges: ranges,
            functions: []
        )
        try? engine.store.save(stub)
    }

    func moduleUUID(forPath path: String) async -> String? {
        if let cached = uuidCache[path] { return cached }
        if let stored = (try? engine.store.fetchModuleAnalysis(sessionID: sessionID, modulePath: path))?.moduleUUID {
            uuidCache[path] = stored
            return stored
        }
        guard let node = engine.node(forSessionID: sessionID),
            let uuid = try? await node.getModuleIdentity(name: path)
        else { return nil }
        uuidCache[path] = uuid
        return uuid
    }

    var processIdentity: String? {
        engine.session(id: sessionID)?.processInfo?.identity
    }
}

private actor ConsoleReplyBuffer {
    private var entries: [WidgetConsoleEntry] = []

    func append(_ entry: WidgetConsoleEntry) {
        entries.append(entry)
    }

    func snapshot() -> [WidgetConsoleEntry] {
        entries
    }
}

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
