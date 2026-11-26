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
    public let blobs: BlobStore
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

    let _widgetUpdates = AsyncEventSource<WidgetUpdate>()
    public var widgetUpdates: AsyncStream<WidgetUpdate> { _widgetUpdates.makeStream() }
    @ObservationIgnored var widgetStates: [UUID: [String: WidgetState]] = [:]
    @ObservationIgnored var consoleEntriesDropped: [InstrumentViews.Key: Int] = [:]
    @ObservationIgnored var rowsBegun: [InstrumentViews.Key: [String: Int]] = [:]
    @ObservationIgnored private var fractionalCounters: Set<FractionalCounter> = []

    private struct FractionalCounter: Hashable {
        let key: InstrumentViews.Key
        let unit: String?
    }
    private var widgetStateWrite = WidgetStateWrite.idle
    private static let widgetStateWriteDelay = Duration.seconds(1)

    private enum WidgetStateWrite {
        case idle
        case scheduled
    }
    private var widgetPlacements: [UUID: [String: [PatternPlacement]]] = [:]
    private var disabledWidgetActions: [UUID: [String: Set<String>]] = [:]
    var fileRecipients: [UUID: FileRecipient] = [:]
    var fileStreams: [UUID: FileStreamRoute] = [:]
    var fileStreamActions: [FileStreamKey: UUID] = [:]
    var localFileReceivers: [UUID: RemoteStreamReceiver] = [:]
    var offeredFileStreams: [UUID: IncomingRemoteStream] = [:]
    public internal(set) var offeredFiles: [OfferedFile] = []
    public internal(set) var lostOfferedFiles: [LostOfferedFile] = []
    public internal(set) var instrumentChildren: [UUID: [InstrumentChild]] = [:]
    public internal(set) var childSelectionRequest: ChildSelectionRequest?
    private var remoteInstrumentAgents: [UUID: InstrumentAgentState] = [:]

    public let eventLog = EventLog()
    public let eventChime = EventChime()
    public let connectionActivity: ConnectionActivityCenter

    private var deviceEventTasks: [String: Task<Void, Never>] = [:]
    private var gatingEnabledDevices: Set<String> = []
    private var gatingIntendedDevices: Set<String> = []
    private var deviceChangeWatcher: Task<Void, Never>?
    private var eventLogTask: Task<Void, Never>?
    private var eventStoreFlushTail: Task<Void, Never> = Task {}

    public let instrumentFolders: InstrumentFolderLibrary
    public let patterns: PatternLibrary
    public let patternDecoder: PatternDecoder
    private let patternGlobals = PatternGlobals()
    public let customInstruments: CustomInstrumentLibrary
    public let fridaReleases = FridaReleaseCatalog()
    public let gadgets: GadgetLibrary
    public let virtualMachines: VirtualMachineManager

    /// The image the playground, the notebook cells and the mission tools all
    /// talk to. The frontend says where it lives; see `PharoWorkspace`.
    @ObservationIgnored public private(set) lazy var pharo = PharoWorkspace(engine: self)
    @ObservationIgnored public private(set) lazy var instrumentViews = InstrumentViews(
        engine: self, catalogURL: BackendConfig.storeCatalogURL)
    @ObservationIgnored public private(set) lazy var objectChats = ObjectChats(engine: self)

    @ObservationIgnored private var disassemblers: [UUID: Disassembler] = [:]
    @ObservationIgnored private var seekRestoredSessions: Set<UUID> = []
    @ObservationIgnored private var memoryReaders: [UUID: CachingMemoryReader] = [:]

    public let collaboration: CollaborationSession
    private var requestedLabID: String?
    public let gitHubAuth: GitHubAuth
    @ObservationIgnored public private(set) lazy var storefront = Storefront(
        engine: self,
        portal: .shared,
        catalogURL: BackendConfig.storeCatalogURL
    )
    public let dataDirectory: URL

    public private(set) var addressAnnotations: [UUID: [UInt64: AddressAnnotation]] = [:]
    public private(set) var tracerInstanceIDBySession: [UUID: UUID] = [:]
    public private(set) var sessions: [ProcessSession] = []
    public private(set) var notebookEntries: [NotebookEntry] = []
    public private(set) var instrumentsBySession: [UUID: [InstrumentInstance]] = [:]
    public private(set) var insightsBySession: [UUID: [AddressInsight]] = [:]
    public private(set) var insightRefreshGenerations: [UUID: Int] = [:]
    public private(set) var tracesBySession: [UUID: [ITrace]] = [:]
    public private(set) var moduleAnalysisStatuses: [UUID: [String: ModuleAnalysisStatus]] = [:]
    public internal(set) var projectUIState: ProjectUIState = ProjectUIState()
    public internal(set) var sessionUIStates: [UUID: SessionUIState] = [:]
    public internal(set) var customInstrumentDefUIStates: [UUID: CustomInstrumentDefUIState] = [:]
    public private(set) var missions: [Mission] = []
    public private(set) var subjectsKeptFromLab: Set<LabSubject> = []
    private var definitionsKeptForLabLimits: Set<UUID> = []
    private var problemsOfThisEngine: [LabProblem] = []

    public var labProblems: [LabProblem] {
        (objectChats.problems.map(LabProblem.init) + problemsOfThisEngine).sorted { $0.date < $1.date }
    }

    public private(set) var installedPackages: [InstalledPackage] = []
    public let placementHistory: PatternPlacementHistory

    @ObservationIgnored private var placementSnapshotTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var instrumentsEditedSinceSnapshots: Set<UUID> = []
    @ObservationIgnored private var typeScriptProjects: [TypeScriptProjectKey: Task<TypeScriptProject, Swift.Error>] = [:]
    private var addressActionProviders: [AddressActionProvider] = []
    @ObservationIgnored private var protectionRegionsBySession: [UUID: [ProtectionRegion]] = [:]
    @ObservationIgnored private var unmappedPagesBySession: [UUID: Set<UInt64>] = [:]
    @ObservationIgnored private var mappingProbesBySession: [UUID: [UInt64: Task<AddressFacts.Mapping, Never>]] = [:]
    @ObservationIgnored private var functionStartsBySession: [UUID: [UInt64: Bool]] = [:]
    @ObservationIgnored private var factsIdentityBySession: [UUID: String] = [:]
    private var runningCustomInstrumentReloads: Set<UUID> = []
    private var pendingCustomInstrumentReloads: Set<UUID> = []
    private var customInstrumentReloadWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    public private(set) var instrumentFolderLinks: [UUID: InstrumentFolderLink] = [:]
    public private(set) var instrumentFolderDrifts: [UUID: InstrumentFolderDrift] = [:]
    private var instrumentFolderSyncFailures: [UUID: String] = [:]
    @ObservationIgnored private var instrumentFolderMonitors: [UUID: InstrumentFolderMonitor] = [:]
    private var threadActionProviders: [ThreadActionProvider] = []
    @ObservationIgnored public var onSessionListChanged: (@MainActor (SessionListChange) -> Void)?
    @ObservationIgnored public var onREPLCellSaved: (@MainActor (REPLCell) -> Void)?
    @ObservationIgnored public var onNotebookChanged: (@MainActor (NotebookChange) -> Void)?
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
        blobs: BlobStore,
        eventStore: EventStore? = nil,
        dataDirectory: URL,
        tokenStore: TokenStore? = nil,
        gitHubAuth: GitHubAuth? = nil,
        deviceManager: DeviceManager = .shared
    ) {
        self.deviceManager = deviceManager
        self.store = store
        self.blobs = blobs
        self.eventStore = eventStore
        self.dataDirectory = dataDirectory
        self.connectionActivity = ConnectionActivityCenter(
            durations: StageDurationMemory(
                fileURL: dataDirectory.appendingPathComponent("connection-stage-durations.json")
            )
        )
        self.compilerWorkspace = CompilerWorkspace(store: store)
        let instrumentFoldersDir = dataDirectory.appendingPathComponent("Instruments", isDirectory: true)
        try? FileManager.default.createDirectory(at: instrumentFoldersDir, withIntermediateDirectories: true)
        self.instrumentFolders = InstrumentFolderLibrary(directory: instrumentFoldersDir)
        let workspace = try! Self.compilerWorkspacePaths(store: store, dataDirectory: dataDirectory)
        self.patterns = PatternLibrary(store: store, workspace: workspace)
        self.placementHistory = PatternPlacementHistory(store: store)
        self.patternDecoder = PatternDecoder(
            projectRoot: workspace.root, draftDirectory: PatternLibrary.directory(in: workspace),
            defines: PatternDecoder.processMemoryDefines)
        self.customInstruments = CustomInstrumentLibrary()
        self.gadgets = GadgetLibrary(catalog: fridaReleases)
        self.virtualMachines = VirtualMachineManager(
            deviceManager: deviceManager, store: store, dataDirectory: dataDirectory, releases: fridaReleases)
        self.collaboration = CollaborationSession(connection: .shared, store: store)

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
                MissionSystemPrompt.build(for: mission, tools: catalog)
            }
        )

        #if os(Windows) || os(macOS) || os(Linux)
        virtualMachines.register(QemuBackend())
        #endif
        #if os(Windows) || os(macOS) || os(Linux)
        virtualMachines.register(AndroidEmulatorBackend())
        #endif
        #if os(macOS)
        virtualMachines.register(VirtualizationBackend())
        virtualMachines.register(VPhoneBackend())
        #endif

        registerDescriptor(Self.tracerDescriptor)
        customInstruments.start(store: store)
        for desc in customInstruments.descriptors() {
            registerDescriptor(desc)
        }
        customInstruments.observers.append { [weak self] in
            self?.refreshCustomInstrumentDescriptors()
            self?.mirrorCustomInstrumentSources()
            self?.patterns.reloadInstrumentSources()
            self?.republishPlacementSnapshotsOfEditedInstruments()
            self?.restoreInstrumentFolderLinks()
            self?.settleInstrumentFolders()
        }
        mirrorCustomInstrumentSources()
        restoreInstrumentFolderLinks()
        bindCollaborationCallbacks()
        missionExecutor.liveDeltaSink = { [weak self] missionID, event in
            self?.handleMissionLiveEvent(missionID: missionID, event: event)
        }
        missionExecutor.assignExecutor = { [weak self] action, mission in
            self?.assignExecutor(to: &action, askedBy: mission.author)
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
                self.eventStoreFlushTail = Task { [store = self.store] in
                    await previous.value
                    await eventStore.append(batch)
                    store.announceRecorded()
                }
            }
        }

        #if os(Windows) || os(macOS) || os(Linux)
        llmRegistry.register(ClaudeCodeProvider(engine: self))
        #endif
        llmRegistry.register(AnthropicProvider())
        llmRegistry.register(OpenAIProvider())
        llmRegistry.register(OpenAICompatibleProvider.local())
        llmRegistry.register(OpenAICompatibleProvider.remote())
        MissionTools.registerStandard(in: missionTools, engine: self)
        ObjectChatTools.register(in: missionTools, engine: self)
        missionsObservation = store.observeMissions { [weak self] missions in
            Task { @MainActor in
                guard let self else { return }
                self.missions = missions
                self.onMissionsChanged?(missions)
            }
        }
        instrumentFolders.onError = { [weak self] message in
            self?.emitEngineError(subsystem: "instruments", text: message)
        }
        instrumentFolders.awaitsUpdate = { [directory = instrumentFolders.directory] folderURL in
            LumaAppState.shared.storeInstallations.keys.contains {
                InstalledStoreItems.folderURL(for: $0, in: directory).standardizedFileURL == folderURL
            }
        }
        instrumentFolders.reload()
        patterns.onChange = { [weak self] in
            self?.publishPatternGlobals()
        }
        patterns.onSaved = { [weak self] record in
            self?.collaboration.enqueuePatternSourceUpsert(record)
            self?.republishPlacementSnapshots { $0 == record.id.uuidString }
        }
        patterns.onDeleted = { [weak self] id in
            self?.collaboration.enqueuePatternSourceRemove(sourceID: id)
        }
        patterns.reload()
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

    public var associatedLabID: String? {
        requestedLabID ?? collaboration.projectLabID
    }

    public func startCollaboration(joiningLab labID: String? = nil) {
        if let labID {
            requestedLabID = labID
        }
        let existing = labID ?? collaboration.projectLabID
        Task { @MainActor in
            guard let token = await gitHubAuth.requestToken() else { return }
            if case .error = collaboration.status {
                await collaboration.stop()
            }
            await collaboration.start(token: token, existingLabID: existing)
        }
    }

    public func followLabLink() {
        switch collaboration.status {
        case .disconnected, .error: startCollaboration()
        case .connecting, .joined: break
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

    /// Spacing between consecutive `position` values assigned locally. The
    /// server stamps definitive values on echo; this is just enough slack
    /// so a drag-between-neighbors computes a non-degenerate midpoint.
    private static let notebookPositionStep: Double = 1000

    public func pinToNotebook(_ cell: REPLCell) {
        addNotebookEntry(NotebookEntry(pinning: cell, processName: session(id: cell.sessionID)?.processName ?? ""))
    }

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
        if !e.placements.isEmpty {
            publishPlacementSnapshots(of: e)
        }
    }

    public func updateNotebookEntry(_ entry: NotebookEntry) {
        updateNotebookEntry(entry, changed: .all)
    }

    /// The caller names the fields it moved so views apply just those; the model
    /// does not diff the entry to find out. Only the fields the collaboration
    /// protocol carries are enqueued, and only when one of them actually moved.
    public func updateNotebookEntry(_ entry: NotebookEntry, changed: NotebookEntryFields) {
        try? store.save(entry)
        if let i = notebookEntries.firstIndex(where: { $0.id == entry.id }) {
            notebookEntries[i] = entry
        }
        onNotebookChanged?(.updated(entry, changed: changed))
        if !changed.isDisjoint(with: [.title, .details, .processName, .pharoSnapshot, .jsValue, .placements]) {
            collaboration.enqueueUpdate(
                entryID: entry.id,
                title: entry.title,
                details: entry.details,
                processName: entry.processName,
                pharoSnapshot: changed.contains(.pharoSnapshot) ? entry.pharoSnapshot : nil,
                pharoResultFuel: changed.contains(.pharoSnapshot) ? entry.pharoResultFuel : nil,
                jsValue: changed.contains(.jsValue) ? entry.jsValue : nil,
                placements: changed.contains(.placements) ? entry.placements : nil
            )
        }
    }

    private func setPlacements(_ placements: [PatternPlacement], forNotebookEntry entry: NotebookEntry) {
        var updated = entry
        updated.placements = placements
        updateNotebookEntry(updated, changed: .placements)
        publishPlacementSnapshots(of: updated)
    }

    private func republishPlacementSnapshotsOfEditedInstruments() {
        let edited = instrumentsEditedSinceSnapshots.map(PatternLibrary.instrumentSourceIDPrefix(defID:))
        instrumentsEditedSinceSnapshots.removeAll()
        republishPlacementSnapshots { sourceID in edited.contains(where: sourceID.hasPrefix) }
    }

    private func republishPlacementSnapshots(decodedWith isAffected: (String) -> Bool) {
        for entry in notebookEntries where entry.placements.contains(where: { isAffected($0.sourceID) }) {
            publishPlacementSnapshots(of: entry)
        }
    }

    private func publishPlacementSnapshots(of entry: NotebookEntry) {
        placementSnapshotTasks[entry.id]?.cancel()
        guard collaboration.isCollaborative else { return }
        placementSnapshotTasks[entry.id] = Task { [weak self] in
            guard let self else { return }
            var snapshots: [PlacementSnapshot] = []
            for placement in entry.placements {
                guard let (data, baseAddress) = Self.bytes(placedOnBy: placement, in: entry) else { continue }
                do {
                    let decoded = try await decode(placement, in: data, at: baseAddress, forSession: entry.sessionID)
                    snapshots.append(PlacementSnapshot(of: placement, decoded: decoded, base: baseAddress))
                } catch {
                    snapshots.append(PlacementSnapshot(of: placement, problem: error.localizedDescription))
                }
            }
            guard !Task.isCancelled else { return }
            collaboration.enqueueUpdate(entryID: entry.id, placementSnapshots: snapshots)
        }
    }

    private static func bytes(placedOnBy placement: PatternPlacement, in entry: NotebookEntry) -> (data: Data, baseAddress: UInt64)? {
        guard let origin = placement.origin else {
            return entry.binaryData.flatMap { data in entry.binaryMeta?.baseAddress.map { (data, $0) } }
        }
        return entry.jsValue?.bytes(readAt: origin).map { ($0.data, origin) }
    }

    public func deleteNotebookEntry(_ entry: NotebookEntry) {
        if entry.kind == .pharo {
            Task { await pharo.stopRun(entry.id) }
        }
        try? store.deleteNotebookEntry(id: entry.id)
        notebookEntries.removeAll { $0.id == entry.id }
        onNotebookChanged?(.removed(entry.id))
        collaboration.enqueueRemove(entryID: entry.id)
    }

    private func isTerminal(_ status: MissionActionStatus) -> Bool {
        switch status {
        case .succeeded, .failed, .rejected: return true
        default: return false
        }
    }

    private func isBehindWhatIsHeld(_ action: MissionAction) -> Bool {
        guard let held = (try? store.fetchMissionAction(id: action.id)).flatMap({ $0 }) else { return false }
        return stage(of: held.status) > stage(of: action.status)
    }

    private func stage(of status: MissionActionStatus) -> Int {
        switch status {
        case .pending: 0
        case .approved: 1
        case .running: 2
        case .succeeded, .failed, .rejected: 3
        }
    }

    func instructionContext(sessionID: UUID, anchor: AddressAnchor) async -> InstructionContext? {
        guard let dis = disassembler(forSessionID: sessionID),
            let address = await resolve(sessionID: sessionID, anchor: anchor)
        else { return nil }
        let atAddress = (insightsBySession[sessionID] ?? []).filter { $0.lastResolvedAddress == address }
        let named = atAddress.first(where: { hasUserTitle($0) }) ?? atAddress.first
        let window = await dis.disassemble(DisassemblyRequest(address: address, count: 32, appearance: .light))
        return InstructionContext(
            insightName: named.map { displayTitle(for: $0) },
            disassembly: window.map { String(format: "0x%llx", $0.address) + "  " + $0.asmText.plainText }.joined(separator: "\n"),
            decompilation: await dis.decompile(at: address).output ?? ""
        )
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

        collaboration.onCustomInstrumentOpReceived = { [weak self] op, editor in
            guard let self else { return }
            switch op {
            case .upsert(let u):
                guard var bundle = try? Self.validatedCustomInstrumentBundle(u.bundle) else { return }
                bundle.def.normalize()
                try? self.store.save(bundle.def)
                if let editor, editor.id != self.collaboration.localUser?.id {
                    self.recordCodeOrigin(.labMember(name: editor.name), ofCustomInstrument: bundle.def.id)
                }
                try? self.store.replaceCustomInstrumentFiles(defID: bundle.def.id, files: bundle.files)
                self.scheduleCustomInstrumentReload(defID: bundle.def.id)
            case .remove(let r):
                self.forgetCustomInstrument(r.defID)
            }
        }

        collaboration.onPatternSourceOpReceived = { [weak self] op in
            switch op {
            case .upsert(let u):
                self?.patterns.adopt(u.record)
            case .remove(let r):
                self?.patterns.discard(r.sourceID)
            }
        }

        collaboration.onPatternSourcesSnapshot = { [weak self] records in
            self?.adoptPatternSources(records)
        }

        collaboration.onOpRejected = { [weak self] subject, reason in
            guard let self else { return }
            emitEngineWarning(subsystem: "collaboration", text: "The lab turned away your change to “\(name(of: subject))”: \(reason).")
        }

        collaboration.onChangeKeptAsCopy = { [weak self] subject, reason in
            self?.keepCopy(of: subject, turnedAwayBecause: reason)
        }

        collaboration.onPatternSourceNameTaken = { [weak self] record in
            self?.patterns.keepUnderAnotherName(record)
        }

        collaboration.onLabCreated = { [weak self] in
            self?.republishPlacementSnapshots { _ in true }
            self?.reconcileWidgetStates(with: [])
            self?.objectChats.adopt([])
        }

        collaboration.onMissionOpReceived = { [weak self] op in
            self?.applyRemoteMissionOp(op)
        }

        collaboration.onMissionSnapshot = { [weak self] snapshot in
            self?.applyRemoteMissionSnapshot(snapshot)
        }

        collaboration.onObjectChatOpReceived = { [weak self] op in
            self?.objectChats.apply(op)
        }

        collaboration.onObjectChatsSnapshot = { [weak self] threads in
            self?.objectChats.adopt(threads)
        }

        collaboration.onSubjectKeptFromLab = { [weak self] subject, reason in
            guard let self, !self.subjectsKeptFromLab.contains(subject) else { return }
            self.keepFromLab(subject, because: "the lab turned it away: \(reason)")
        }

        collaboration.onObjectChatMessageRefused = { [weak self] message, reason in
            self?.objectChats.refused(message, because: reason)
        }

        collaboration.onObjectChatOpRefused = { [weak self] op, reason in
            self?.objectChats.refused(op, because: reason)
        }

        collaboration.onSessionRemovedInLab = { [weak self] sessionID in
            self?.applyRemoteSessionRemoval(sessionID: sessionID)
        }

        collaboration.onLabLeft = { [weak self] in
            self?.objectChats.followLab()
        }

        collaboration.onMissionRemovedInLab = { [weak self] missionID in
            self?.endMissionRemovedInLab(missionID)
        }

        collaboration.onCustomInstrumentRemovedInLab = { [weak self] defID in
            self?.keepCopy(ofCustomInstrument: defID) { name in
                "“\(name)” was deleted in the lab, so your changes to it are kept here as an instrument the lab does not have. "
                    + "Add it to the lab again, or delete it."
            }
        }

        collaboration.onPatternRemovedInLab = { [weak self] sourceID in
            self?.keepCopy(ofPattern: sourceID) { name in
                "The pattern “\(name)” was deleted in the lab, so your changes to it are kept here "
                    + "as a pattern the lab does not have. Add it to the lab again, or delete it."
            }
        }

        collaboration.onCustomInstrumentSnapshot = { [weak self] bundles, editors in
            guard let self else { return }
            let serverIDs = Set(bundles.map(\.def.id))
            let local = (try? self.store.fetchCustomInstrumentDefs()) ?? []
            let pending = self.subjectsOfPendingOps(CustomInstrumentOp.self)
            let known = self.knownToLab(.definition)
            for absent in local where !serverIDs.contains(absent.id) && !pending.contains(absent.id) && !known.contains(absent.id) {
                self.broadcastCustomInstrumentUpsert(defID: absent.id)
            }
            for stale in local where !serverIDs.contains(stale.id) && !pending.contains(stale.id) && known.contains(stale.id) {
                self.forgetCustomInstrument(stale.id)
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
            for (defID, editor) in editors where editor.id != self.collaboration.localUser?.id {
                self.recordCodeOrigin(.labMember(name: editor.name), ofCustomInstrument: defID)
            }
            for bundle in normalized {
                self.scheduleCustomInstrumentReload(defID: bundle.def.id)
            }
        }

        collaboration.onNotebookSnapshot = { [weak self] entries in
            self?.adoptNotebook(entries)
        }

        collaboration.onEntryUpserted = { [weak self] upserted in
            guard let self else { return }
            let existing = try? self.store.fetchNotebookEntry(id: upserted.id)
            let existed = existing != nil
            var entry = upserted
            entry.binaryData = upserted.binaryData ?? existing?.binaryData
            entry.pharoResultFuel = upserted.pharoResultFuel ?? existing?.pharoResultFuel
            entry.sessionID = upserted.sessionID ?? existing?.sessionID
            guard Self.asSent(existing, merging: entry) != entry else { return }
            try? self.store.save(entry)
            if let i = self.notebookEntries.firstIndex(where: { $0.id == entry.id }) {
                self.notebookEntries[i] = entry
            } else {
                self.notebookEntries.append(entry)
            }
            self.onNotebookChanged?(existed ? .updated(entry, changed: .all) : .added(entry))
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

        collaboration.onSessionReplCellUpdated = { [weak self] sessionID, cell in
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

        collaboration.onSessionInstrumentAgentReported = { [weak self] instanceID, agent in
            guard let self else { return }
            let wasAwaiting = self.remoteInstrumentAgents[instanceID]?.awaitsApproval ?? false
            self.remoteInstrumentAgents[instanceID] = agent
            if agent.awaitsApproval != wasAwaiting {
                self.instrumentViews.hostApprovalChanged(of: instanceID)
            }
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

        collaboration.onSessionPlacementsSet = { [weak self] sessionID, subject, placements in
            guard let self else { return }
            switch subject {
            case .replCell(let cellID):
                storePlacements(placements, forREPLCell: cellID)
            case .insight(let insightID):
                guard let insight = try? store.fetchInsights(sessionID: sessionID).first(where: { $0.id == insightID }) else { return }
                storePlacements(placements, forInsight: insight)
            case .widget(let instanceID, let widget):
                storePlacements(placements, forWidget: widget, of: instanceID)
            }
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

        collaboration.onSessionEventUpdated = { [weak self] sessionID, event in
            self?.applyRemoteSessionEventUpdate(sessionID: sessionID, event: event)
        }

        collaboration.onSessionWidgetUpdateReceived = { [weak self] sessionID, update in
            self?.applyWidgetUpdate(update, sessionID: sessionID, origin: .remote)
        }
        collaboration.onSessionViewStateReceived = { [weak self] sessionID, instanceID, widget, state in
            let update = WidgetUpdate(instanceID: instanceID, widget: widget, kind: .viewState(state), revision: state.revision)
            self?.applyWidgetUpdate(update, sessionID: sessionID, origin: .remote)
        }
        collaboration.onSessionViewEventReceived = { [weak self] sessionID, instanceID, widget, event in
            let kind: WidgetUpdate.Kind
            do throws(WidgetViewRefusal) {
                kind = .viewEvent(try event.checkingData(atMost: WidgetViewPayload.maxEventDataBytes))
            } catch {
                kind = .viewRefused("An event from the lab was refused: \(error.message)")
            }
            self?.applyWidgetUpdate(WidgetUpdate(instanceID: instanceID, widget: widget, kind: kind), sessionID: sessionID, origin: .remote)
        }
        collaboration.onSessionViewMessageReceived = { [weak self] sessionID, instanceID, widget, message, sender in
            do throws(WidgetViewRefusal) {
                let checked = try message.checkingData(atMost: InstrumentViews.messageDataLimit)
                self?.deliverViewMessage(checked, sessionID: sessionID, instanceID: instanceID, widget: widget, from: sender)
            } catch {
                self?.emitEngineWarning(
                    subsystem: "collaboration", text: "A message from \(sender.name)'s view was refused: \(error.message)")
            }
        }
        collaboration.onSessionViewRefused = { [weak self] sessionID, instanceID, widget, message in
            let refused = WidgetUpdate(instanceID: instanceID, widget: widget, kind: .viewRefused(message))
            self?.applyWidgetUpdate(refused, sessionID: sessionID, origin: .remote)
        }

        collaboration.onChildReceived = { [weak self] child, instanceID in
            self?.receiveRemoteChild(child, instanceID: instanceID)
        }

        collaboration.onChildRemoved = { [weak self] ref, instanceID in
            self?.receiveRemoteChildRemoval(ref, instanceID: instanceID)
        }

        collaboration.onChildShown = { [weak self] child, sessionID, instanceID in
            self?.receiveShow(child, sessionID: sessionID, instanceID: instanceID)
        }

        collaboration.onChildrenSnapshot = { [weak self] snapshot, sessions in
            guard let self else { return }
            let remote = sessions.filter { !self.isHostingNode($0.id) }
            adoptRemoteChildren(snapshot, instanceIDs: Set(remote.flatMap { $0.instruments.map(\.id) + (self.instrumentsBySession[$0.id] ?? []).map(\.id) }))
            republishChildren(over: snapshot, sessionIDs: Set(sessions.map(\.id).filter { self.isHostingNode($0) }))
        }

        collaboration.onOfferedStream = { [weak self] instanceID, stream in
            self?.offer(stream, instanceID: instanceID)
        }

        collaboration.onRelayedStreamReply = { [weak self] actionID, stanza in
            self?.relayedStreamReplied(actionID: actionID, stanza: stanza)
        }

        collaboration.onRelayedStreamEnded = { [weak self] actionID, reason in
            self?.relayedStreamEnded(actionID: actionID, reason: reason)
        }

        collaboration.onSessionWidgetActionRequested = { [weak self] sessionID, instanceID, widget, action, item, actionID, revision in
            self?.handleRemoteWidgetActionRequest(
                sessionID: sessionID,
                instanceID: instanceID,
                widget: widget,
                action: action,
                item: item,
                actionID: actionID,
                seenRevision: revision
            )
        }

        collaboration.onWidgetActionFailed = { [weak self] failure in
            self?.reportFailedAction(failure)
        }

        collaboration.onWidgetStale = { [weak self] sessionID, instanceID, widget, revision in
            self?.resendStaleWidgetState(sessionID: sessionID, instanceID: instanceID, slot: widget, labRevision: revision)
        }

        collaboration.onInstanceHeld = { [weak self] sessionID, instanceID in
            self?.republishWidgetStates(ofInstance: instanceID, in: sessionID)
        }

        collaboration.onWidgetStatesSnapshot = { [weak self] snapshots in
            self?.reconcileWidgetStates(with: snapshots)
        }

        collaboration.onWidgetPlacementsSnapshot = { [weak self] placements in
            self?.adoptWidgetPlacements(placements)
        }

        collaboration.onReplEvalTimedOut = { [weak self] cellID in
            self?.markReplCellTimedOut(cellID: cellID)
        }

        collaboration.onSessionRemoved = { [weak self] sessionID in
            self?.applyRemoteSessionRemoval(sessionID: sessionID)
        }
    }

    private func adoptPatternSources(_ labRecords: [PatternSourceRecord]) {
        let pending = subjectsOfPendingOps(PatternSourceOp.self)
        let known = knownToLab(.pattern)
        let labIDs = Set(labRecords.map(\.id))
        let unsent = ((try? store.fetchPatternSources()) ?? []).filter {
            !labIDs.contains($0.id) && (pending.contains($0.id) || !known.contains($0.id))
        }
        patterns.replaceProjectSources(with: labRecords + unsent)
        for record in unsent where !pending.contains(record.id) {
            collaboration.enqueuePatternSourceUpsert(record)
        }
    }

    private func adoptNotebook(_ labEntries: [NotebookEntry]) {
        let pending = subjectsOfPendingOps(NotebookOp.self)
        let known = knownToLab(.entry)
        let labIDs = Set(labEntries.map(\.id))
        let unsent = notebookEntries.filter { !labIDs.contains($0.id) && (pending.contains($0.id) || !known.contains($0.id)) }
        for entry in unsent where !pending.contains(entry.id) {
            collaboration.enqueueAdd(entry)
        }
        for entry in notebookEntries where !unsent.contains(where: { $0.id == entry.id }) {
            try? store.deleteNotebookEntry(id: entry.id)
        }
        for entry in labEntries {
            try? store.save(entry)
        }
        notebookEntries = (labEntries + unsent).sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }
        onNotebookChanged?(.snapshot(notebookEntries))
    }

    private func subjectsOfPendingOps<Op: OutboxOp>(_ type: Op.Type) -> Set<UUID> {
        Set(((try? store.fetchOutboxOps(type)) ?? []).map(\.outboxSubject))
    }

    private func knownToLab(_ family: LabSubject.Family) -> Set<UUID> {
        (try? store.subjectsKnownToLab(family)) ?? []
    }

    private func markReplCellTimedOut(cellID: UUID) {
        guard let cell = try? store.fetchREPLCell(id: cellID),
            case .text(let text) = cell.result,
            text == "Running…"
        else { return }
        var updated = cell
        updated.result = .text("Timed out — host did not respond.")
        try? store.save(updated)
        onREPLCellSaved?(updated)
    }

    private func applyRemoteSessionEvent(sessionID: UUID, event: RuntimeEvent) {
        var stamped = event
        stamped.sessionID = sessionID
        _events.yield(stamped)
    }

    private func applyRemoteSessionEventUpdate(sessionID: UUID, event: RuntimeEvent) {
        var stamped = event
        stamped.sessionID = sessionID
        eventLog.update(stamped)
    }

    private func applyRemoteSessionTraceUpserted(sessionID: UUID, trace: ITrace) {
        var stored = trace
        stored.sessionID = sessionID
        try? store.save(stored)
        onSessionListChanged?(.traceUpdated(stored))
    }

    private func applyRemoteSessionTraceRemoved(sessionID: UUID, traceID: UUID) {
        try? store.deleteITrace(id: traceID)
        blobs.delete(id: traceID, kind: .trace)
        onSessionListChanged?(.traceRemoved(id: traceID, sessionID: sessionID))
    }

    private func applyRemoteTraceDataProgressed(sessionID: UUID, traceID: UUID, totalSize: Int) {
        let cachedSize = blobs.size(id: traceID, kind: .trace) ?? 0
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
        widgetPlacements.removeValue(forKey: instanceID)
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

    func emitEngineError(subsystem: String, text: String) {
        emitEngineEvent(subsystem: subsystem, level: .error, text: text)
    }

    func emitEngineWarning(subsystem: String, text: String) {
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
        collaboration.enqueueUpdateInstrument(
            sessionID: instance.sessionID, instance: instance, runtimeStatus: status, agent: agentState(of: instance))
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
        let known = knownToLab(.session)
        let pending = subjectsOfPendingOps(SessionOp.self)
        for cached in sessions where !serverKnown.contains(cached.id) {
            guard !localUserHosts(cached) || (known.contains(cached.id) && !pending.contains(cached.id)) else { continue }
            applyRemoteSessionRemoval(sessionID: cached.id)
        }
        for session in snapshot {
            adoptRemoteSession(session)
            reconcileChildren(of: session)
        }
        markOrphanedHostsDetached(serverKnown: serverKnown)
        announceMissingLocalSessions(serverKnown: serverKnown)
    }

    private func reconcileChildren(of labSession: CollaborationSession.Session) {
        let sessionID = labSession.id
        let pending = Set(((try? store.fetchOutboxOps(SessionOp.self)) ?? []).map(\.labSubject))
        let hostedHere = labSession.host.id == collaboration.localUser?.id
        let lab = Set(labSession.labSubjects)
        let absent = { (subject: LabSubject) in !lab.contains(subject) && !pending.contains(subject) }
        let families: [LabSubject.Family] = [.replCell, .instrument, .insight, .trace]
        let knownByFamily = Dictionary(uniqueKeysWithValues: families.map { ($0, knownToLab($0)) })
        let known = { (subject: LabSubject) in knownByFamily[subject.family]!.contains(subject.id) }

        for cell in (try? store.fetchREPLCells(sessionID: sessionID)) ?? [] {
            let subject = LabSubject(.replCell, cell.id)
            if absent(subject), hostedHere, !known(subject) {
                collaboration.enqueueAddReplCell(sessionID: sessionID, cell: cell)
            }
        }
        for instance in (try? store.fetchInstruments(sessionID: sessionID)) ?? [] {
            let subject = LabSubject(.instrument, instance.id)
            guard absent(subject) else { continue }
            if known(subject) {
                applyRemoteSessionInstrumentRemoved(sessionID: sessionID, instanceID: instance.id)
            } else if hostedHere {
                announce(instance, sessionID: sessionID)
            }
        }
        for insight in (try? store.fetchInsights(sessionID: sessionID)) ?? [] {
            let subject = LabSubject(.insight, insight.id)
            guard absent(subject) else { continue }
            if known(subject) {
                applyRemoteSessionInsightRemoved(sessionID: sessionID, insightID: insight.id)
            } else if hostedHere {
                collaboration.enqueueAddInsight(sessionID: sessionID, insight: insight)
            }
        }
        for trace in (try? store.fetchITraces(sessionID: sessionID)) ?? [] {
            let subject = LabSubject(.trace, trace.id)
            guard absent(subject) else { continue }
            if known(subject) {
                applyRemoteSessionTraceRemoved(sessionID: sessionID, traceID: trace.id)
            } else if hostedHere {
                announce(trace, sessionID: sessionID)
            }
        }
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
        let pending = subjectsOfPendingOps(SessionOp.self)
        let known = knownToLab(.session)
        for session in sessions where !serverKnown.contains(session.id) && !pending.contains(session.id) {
            if session.host?.id == localUser.id, known.contains(session.id) {
                applyRemoteSessionRemoval(sessionID: session.id)
                continue
            }
            guard session.host == nil || session.host?.id == localUser.id else { continue }
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
            if let info = session.processInfo {
                collaboration.enqueueUpdateProcessInfo(sessionID: session.id, info: info)
            }
            collaboration.enqueueUpdateSessionModules(sessionID: session.id, delta: ModuleDelta(added: session.lastKnownModules ?? []))
            collaboration.enqueueUpdateSessionThreads(sessionID: session.id, delta: ThreadDelta(added: session.lastKnownThreads ?? []))
            announceLocalSessionChildren(sessionID: session.id)
        }
    }

    private func announceLocalSessionChildren(sessionID: UUID) {
        for cell in (try? store.fetchREPLCells(sessionID: sessionID)) ?? [] {
            collaboration.enqueueAddReplCell(sessionID: sessionID, cell: cell)
        }
        for instance in (try? store.fetchInstruments(sessionID: sessionID)) ?? [] {
            announce(instance, sessionID: sessionID)
        }
        for insight in (try? store.fetchInsights(sessionID: sessionID)) ?? [] {
            collaboration.enqueueAddInsight(sessionID: sessionID, insight: insight)
        }
        for trace in (try? store.fetchITraces(sessionID: sessionID)) ?? [] {
            announce(trace, sessionID: sessionID)
        }
    }

    private func announce(_ instance: InstrumentInstance, sessionID: UUID) {
        let status = node(forSessionID: sessionID)?.instruments.first(where: { $0.id == instance.id })?.status
        collaboration.enqueueAddInstrument(sessionID: sessionID, instance: instance, runtimeStatus: status, agent: agentState(of: instance))
        for (widget, placements) in widgetPlacements[instance.id] ?? [:] where !placements.isEmpty {
            collaboration.enqueueSetPlacements(placements, sessionID: sessionID, on: .widget(instanceID: instance.id, widget: widget))
        }
    }

    private func announce(_ trace: ITrace, sessionID: UUID) {
        collaboration.enqueueUpsertTrace(sessionID: sessionID, trace: trace)
        Task { @MainActor [weak self] in
            await self?.uploadTraceDelta(trace, collabSessionID: sessionID)
        }
    }

    private func adoptRemoteSession(_ session: CollaborationSession.Session) {
        if var record = (try? store.fetchSession(id: session.id)) ?? nil {
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
            record.processInfo = session.processInfo
            try? store.save(record)
            sessions.insert(record, at: 0)
            rebuildAddressAnnotations(sessionID: record.id)
            onSessionListChanged?(.sessionAdded(record))
        }

        for cell in session.replCells {
            var stored = cell
            stored.sessionID = session.id
            try? store.save(stored)
            onREPLCellSaved?(stored)
        }

        remoteInstrumentAgents.merge(session.instrumentAgents) { _, reported in reported }
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
        updateSession(id: sessionID) { $0.phase = phase.toProcessSessionPhase }
    }

    private func applyRemoteSessionArming(
        sessionID: UUID,
        armingState: ProcessSession.ArmingState
    ) {
        updateSession(id: sessionID) { $0.armingState = armingState }
    }

    private func applyRemoteSessionModules(sessionID: UUID, delta: ModuleDelta) {
        updateSession(id: sessionID) { $0.lastKnownModules = delta.applied(to: $0.lastKnownModules) }
    }

    private func applyRemoteSessionThreads(sessionID: UUID, delta: ThreadDelta) {
        updateSession(id: sessionID) { $0.lastKnownThreads = delta.applied(to: $0.lastKnownThreads) }
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

        updateSession(id: sessionID) { updated in
            updated.host = host
            updated.deviceID = deviceID
            updated.deviceName = deviceName
            updated.processName = processName
            updated.lastKnownPID = pid
            updated.lastKnownMainModule = nil
            updated.lastKnownModules = nil
            updated.lastKnownThreads = nil
        }
    }

    private func applyRemoteSessionReplCell(sessionID: UUID, cell: REPLCell) {
        var stored = cell
        stored.sessionID = sessionID
        try? store.save(stored)
        onREPLCellSaved?(stored)
    }

    private func applyRemoteSessionRemoval(sessionID: UUID) {
        collaboration.forget(removedSession: sessionID)
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        removeSessionHere(sessionID)
        guard let host = session.host, host.id == localUserID else { return }
        emitEngineWarning(
            subsystem: "collaboration",
            text: "The session “\(session.processName)” you were hosting was removed from the lab, so it was removed here too.")
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
        virtualMachines.load()
        #if canImport(Network) || canImport(CSoup)
        let externalMCPWasRunning = hasRunningExternalMCPMission()
        purgeExternalMCPMissions()
        if externalMCPWasRunning {
            Task { try? await self.enableExternalMCPServer() }
        }
        #endif
        notebookEntries = (try? store.fetchNotebookEntries()) ?? []
        subjectsKeptFromLab = (try? store.subjectsWithheldFromLab()) ?? []
        definitionsKeptForLabLimits = Set(subjectsKeptFromLab.filter { $0.family == .definition && overLabLimits($0.id) }.map(\.id))
        objectChats.load()
        widgetPlacements = (try? store.fetchWidgetPlacements()) ?? [:]
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
                self?.instrumentViews.reconcile(with: grouped)
            }
        }
        insightsObservation = store.observeAllInsights { [weak self] grouped in
            Task { @MainActor in self?.adoptInsights(grouped) }
        }
        tracesObservation = store.observeAllITraces { [weak self] grouped in
            Task { @MainActor in self?.tracesBySession = grouped }
        }
        packagesObservation = store.observeInstalledPackages { [weak self] packages in
            Task { @MainActor in
                self?.installedPackages = packages
                self?.patterns.reload()
                self?.onInstalledPackagesChanged?(packages)
            }
        }
        patterns.reload()
        instrumentViews.start()
        Task { [weak self] in
            guard let self, let paths = try? compilerWorkspacePaths() else { return }
            _ = try? await compilerWorkspace.ensureReady(paths: paths)
            patterns.reload()
        }
        storefront.start()

        await loadRemoteDevices()
        watchDevicesForGating()
        if let labID = CollaborationJoinQueue.shared.consumeNext() {
            startCollaboration(joiningLab: labID)
        }
    }

    public func shutdown() async {
        guard !hasShutDown else { return }
        hasShutDown = true

        writeStagedWidgetStates()
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

        for monitor in instrumentFolderMonitors.values { monitor.stop() }
        instrumentFolderMonitors.removeAll()

        await instrumentViews.stopAll()

        for node in processNodes { node.stop() }
        processNodes.removeAll()

        await virtualMachines.stopAll()

        for service in drainServices.values { await service.shutdown() }
        drainServices.removeAll()

        await collaboration.stop()
        await storefront.stop()
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
                    self.ensureDeviceEventsHooked(for: device)
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

    public func installSwiftBridge() async throws {
        let name = SwiftTypesOutline.bridgePackageName
        _ = try await installPackage(
            name: name,
            versionSpec: SwiftTypesOutline.bridgeVersionSpec,
            globalAlias: InstalledPackage.defaultGlobalAlias(forPackageName: name)
        )
    }

    public func typeScriptProject(for profile: EditorProfile) async throws -> TypeScriptProject {
        let key = TypeScriptProjectKey(languageId: profile.languageId, ambientDeclarations: profile.ambientDeclarations)
        if let starting = typeScriptProjects[key] {
            return try await starting.value
        }
        let starting = Task { @MainActor in
            let paths = try compilerWorkspacePaths()
            let root = try await compilerWorkspace.ensureReady(paths: paths)
            let project = TypeScriptProject(root: root)
            try await project.start(ambientDeclarations: profile.ambientDeclarations)
            return project
        }
        typeScriptProjects[key] = starting
        do {
            return try await starting.value
        } catch {
            typeScriptProjects[key] = nil
            throw error
        }
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
            emitEngineError(subsystem: "packages", text: "Failed to load package \(package.name): \(describedCompileError(error))")
        }
    }

    private func loadPatternGlobals(on node: ProcessNode) async {
        await refreshPatternGlobals()
        await installPatternGlobals(patternGlobals.all, removing: [], on: node)
    }

    private func publishPatternGlobals() {
        guard !processNodes.isEmpty else { return }
        Task {
            let update = await refreshPatternGlobals()
            for node in processNodes {
                await installPatternGlobals(update.installed, removing: update.removed, on: node)
            }
        }
    }

    @discardableResult
    private func refreshPatternGlobals() async -> PatternGlobals.Update {
        let update = await patternGlobals.refresh(from: patterns.sources) { [self] source in
            try await compilerWorkspace.buildPatternBundle(for: source, paths: try compilerWorkspacePaths())
        }
        for (source, error) in update.failures {
            emitEngineError(subsystem: "patterns", text: "Failed to expose \(source.name) to the REPL: \(describedCompileError(error))")
        }
        return update
    }

    private func installPatternGlobals(
        _ globals: [PatternGlobals.CompiledPattern], removing removed: [String], on node: ProcessNode
    ) async {
        guard !globals.isEmpty || !removed.isEmpty else { return }
        do {
            let refused = try await node.installPatternGlobals(globals.map(\.agentEntry), removing: removed)
            for global in refused {
                let name = patternGlobals.source(ofGlobal: global) ?? global
                let reason = userFacingMessage(PatternGlobalError.wouldReplace(global))
                emitEngineError(subsystem: "patterns", text: "Failed to expose \(name) to the REPL: \(reason)")
            }
        } catch {
            emitEngineError(subsystem: "patterns", text: "Failed to expose patterns to the REPL: \(userFacingMessage(error))")
        }
    }

    private func describedCompileError(_ error: any Swift.Error) -> String {
        var message = userFacingMessage(error)
        if let compile = error as? CompileFailure, !compile.diagnostics.isEmpty {
            message += "\n\n" + compile.diagnostics.map(\.description).joined(separator: "\n")
        }
        return message
    }

    private func propagatePackage(_ package: InstalledPackage) async {
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
                node.markInstrumentDetached(id: instance.id)
                broadcastInstrumentStatus(instanceID: instance.id, sessionID: node.sessionID)
                try? await node.disposeInstrumentOnAgent(instanceID: instance.id)
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

    public func descriptor(for instance: InstrumentInstance) -> InstrumentDescriptor {
        switch instance.kind {
        case .tracer:
            return descriptorsByID["tracer"] ?? Self.missingDescriptor(for: instance)
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

    private func mirrorCustomInstrumentSources() {
        guard let root = try? compilerWorkspacePaths().root else { return }
        let customRoot = root.appendingPathComponent("InstrumentSources/Custom", isDirectory: true)
        for def in customInstruments.defs {
            let dirURL = customRoot.appendingPathComponent(def.id.uuidString, isDirectory: true)
            let files = customInstruments.files(forDefID: def.id).map { (path: $0.path, content: Data($0.content.utf8)) }
            try? Self.syncInstrumentSources(files, into: dirURL)
            Task { [compilerWorkspace] in
                try? await compilerWorkspace.installDependencies(def.dependencies, in: dirURL)
            }
        }
    }

    private func makeCodeShareDescriptor(for instance: InstrumentInstance) -> InstrumentDescriptor? {
        guard
            let cfg = try? CodeShareConfig.decode(from: instance.configJSON)
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
        if session.iconPNGData == nil, case .application(_, _, let iconPNGData) = config.target {
            session.iconPNGData = iconPNGData
        }
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
            let gadget = try await gadgetPath(for: device)
            let aux: [String: Any]? = if let gadget { ["gadget": gadget] } else { nil }
            let pid = try await device.spawn(
                program: config.programString,
                argv: config.argvParam,
                envp: nil,
                env: config.envParam,
                cwd: config.cwdParam,
                stdio: config.stdio,
                aux: aux
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
                try await device.resume(pid: pid)
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

            let fridaSession = try await device.attach(pid: process.pid, gadgetPath: gadgetPath(for: device))

            updateSession(id: s.id) { $0.lastAttachedAt = Date() }

            let script = try await fridaSession.createScript(
                source: LumaAgent.coreSource,
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
                blobStore: blobs
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
                onREPLCellSaved?(cell)
                if let sid = collabSessionID(forNode: node) {
                    collaboration.enqueueAddReplCell(sessionID: sid, cell: cell)
                }
            }

            let previousModules = sessions.first { $0.id == s.id }?.lastKnownModules ?? []
            updateSession(id: s.id) {
                $0.lastKnownMainModule = nil
                $0.lastKnownModules = nil
                $0.lastKnownThreads = nil
            }
            if let sid = collabSessionID(forNode: node), !previousModules.isEmpty {
                collaboration.enqueueUpdateSessionModules(sessionID: sid, delta: ModuleDelta(removed: previousModules))
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
            await loadPatternGlobals(on: node)

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

    private func gadgetPath(for device: Device) async throws -> String? {
        guard let flavor = await gadgetFlavor(for: device) else { return nil }
        return try await gadgets.ensure(flavor).path
    }

    public func gadgetFlavor(for device: Device) async -> GadgetFlavor? {
        await systemParameters.parameters(for: device).flatMap(GadgetFlavor.init(system:))
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
            node.onWidgetUpdate = nil
            node.onActionStateChange = nil
            node.onFileStreamTraffic = nil
            node.onChildTraffic = nil
            node.stop()
            endFileStreams(ofSession: sid, reason: "the session was detached")
            for instance in instrumentsBySession[sid] ?? [] {
                dropTransientChildren(of: instance.id)
            }
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
        instrumentsBySession[sessionID]?.first { $0.id == id } ?? (try? store.fetchInstrument(id: id))
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
                shareInsightUpdate(c)
                emitInsightUpdated(c)
            }
        }
    }

    public func memoryReader(forSessionID sessionID: UUID) -> CachingMemoryReader {
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
        shareInsightUpdate(updated)
    }

    public func renameInsight(_ insight: AddressInsight, to newTitle: String) {
        var updated = insight
        updated.userTitle = newTitle
        persistInsight(updated)
        shareInsightUpdate(updated)
        applyInsightNameToR2(updated)
        emitInsightUpdated(updated)
    }

    public func setPlacements(_ placements: [PatternPlacement], forInsight insight: AddressInsight) {
        storePlacements(placements, forInsight: insight)
        collaboration.enqueueSetPlacements(placements, sessionID: insight.sessionID, on: .insight(insight.id))
    }

    private func storePlacements(_ placements: [PatternPlacement], forInsight insight: AddressInsight) {
        var updated = insight
        updated.placements = placements
        persistInsight(updated)
        emitInsightUpdated(updated)
    }

    public func setByteCount(_ byteCount: Int, forInsight insight: AddressInsight) {
        var updated = insight
        updated.byteCount = byteCount
        persistInsight(updated)
        shareInsightUpdate(updated)
        emitInsightUpdated(updated)
    }

    private func shareInsightUpdate(_ insight: AddressInsight) {
        guard localUserHosts(insight.sessionID) else { return }
        collaboration.enqueueUpdateInsight(sessionID: insight.sessionID, insight: insight)
    }

    public func placements(at origin: UInt64?, in stored: StoredValue) -> [PatternPlacement] {
        placements(in: stored).placed(at: origin)
    }

    public func setPlacements(_ placements: [PatternPlacement], at origin: UInt64?, in stored: StoredValue) {
        let all = self.placements(in: stored).replacingThose(at: origin, with: placements)
        switch stored {
        case .replCell(let id):
            setPlacements(all, forREPLCell: id)
        case .notebookEntry(let id):
            guard let entry = notebookEntries.first(where: { $0.id == id }) else { return }
            setPlacements(all, forNotebookEntry: entry)
        case .event(let id):
            guard var event = eventLog.event(id: id) else { return }
            event.placements = all
            update(event)
        }
    }

    private func placements(in stored: StoredValue) -> [PatternPlacement] {
        switch stored {
        case .replCell(let id):
            return (try? store.fetchREPLCell(id: id))?.placements ?? []
        case .notebookEntry(let id):
            return notebookEntries.first { $0.id == id }?.placements ?? []
        case .event(let id):
            return eventLog.event(id: id)?.placements ?? []
        }
    }

    public func setPlacements(_ placements: [PatternPlacement], forREPLCell cellID: UUID) {
        guard let cell = storePlacements(placements, forREPLCell: cellID) else { return }
        collaboration.enqueueSetPlacements(placements, sessionID: cell.sessionID, on: .replCell(cellID))
    }

    @discardableResult
    private func storePlacements(_ placements: [PatternPlacement], forREPLCell cellID: UUID) -> REPLCell? {
        guard var cell = try? store.fetchREPLCell(id: cellID) else { return nil }
        cell.placements = placements
        try? store.save(cell)
        onREPLCellSaved?(cell)
        return cell
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

    public func rereadBytes(of insight: AddressInsight) async {
        if let address = insight.lastResolvedAddress {
            await memoryReader(forSessionID: insight.sessionID).forget(from: address, count: insight.byteCount)
        }
        requestRefresh(of: insight)
    }

    public func writeMemory(_ bytes: [UInt8], at address: UInt64, of insight: AddressInsight) async throws {
        try await writeMemory(bytes, at: address, forSessionID: insight.sessionID)
        requestRefresh(of: insight)
    }

    public func writeMemory(
        _ bytes: [UInt8], at address: UInt64, forSessionID sessionID: UUID, updating stored: StoredValue
    ) async throws {
        try await writeMemory(bytes, at: address, forSessionID: sessionID)
        recordMemory(bytes, at: address, in: stored)
    }

    @discardableResult
    public func rereadMemory(of bytes: JSInspectValue.Bytes, forSessionID sessionID: UUID, updating stored: StoredValue) async throws -> [UInt8] {
        guard let address = bytes.address, let node = node(forSessionID: sessionID) else {
            throw DisassemblyError.detached
        }
        let fresh = try await node.readRemoteMemory(at: address, count: bytes.data.count)
        recordMemory(fresh, at: address, in: stored)
        return fresh
    }

    public func writeMemory(_ bytes: [UInt8], at address: UInt64, forSessionID sessionID: UUID) async throws {
        try await memoryReader(forSessionID: sessionID).write(bytes, at: address)
    }

    private func recordMemory(_ bytes: [UInt8], at address: UInt64, in stored: StoredValue) {
        switch stored {
        case .replCell(let id):
            recordMemory(bytes, at: address, inREPLCell: id)
        case .notebookEntry(let id):
            recordMemory(bytes, at: address, inNotebookEntry: id)
        case .event(let id):
            recordMemory(bytes, at: address, inEvent: id)
        }
    }

    private func recordMemory(_ bytes: [UInt8], at address: UInt64, inREPLCell id: UUID) {
        guard var cell = try? store.fetchREPLCell(id: id), case .js(let value) = cell.result else { return }
        cell.result = .js(value.recordingMemory(bytes, at: address))
        try? store.save(cell)
        onREPLCellSaved?(cell)
        collaboration.enqueueUpdateReplCell(sessionID: cell.sessionID, cell: cell)
    }

    private func recordMemory(_ bytes: [UInt8], at address: UInt64, inNotebookEntry id: UUID) {
        guard var entry = notebookEntries.first(where: { $0.id == id }), let value = entry.jsValue else { return }
        entry.jsValue = value.recordingMemory(bytes, at: address)
        updateNotebookEntry(entry, changed: .jsValue)
    }

    private func recordMemory(_ bytes: [UInt8], at address: UInt64, inEvent id: RuntimeEvent.ID) {
        guard let event = eventLog.event(id: id) else { return }
        update(event.recordingMemory(bytes, at: address))
    }

    private func update(_ event: RuntimeEvent) {
        eventLog.update(event)
        if let sessionID = event.sessionID, let collabID = collabSessionID(forSessionID: sessionID) {
            collaboration.sendEventUpdate(sessionID: collabID, event: event)
        }
    }

    public func reanalyzeModule(of insight: AddressInsight) {
        guard let module = enclosingModule(of: insight) else { return }
        invalidateModule(sessionID: insight.sessionID, modulePath: module.path)
        requestRefresh(of: insight)
    }

    public func enclosingModule(of insight: AddressInsight) -> ProcessModule? {
        if let address = insight.lastResolvedAddress, let module = enclosingModule(at: address, sessionID: insight.sessionID) {
            return module
        }
        if case .moduleOffset(let name, _) = insight.anchor {
            return modulesSnapshot(forSessionID: insight.sessionID).first { $0.name == name }
        }
        return nil
    }

    private func requestRefresh(of insight: AddressInsight) {
        insightRefreshGenerations[insight.id, default: 0] += 1
    }

    private func adoptInsights(_ grouped: [UUID: [AddressInsight]]) {
        insightsBySession = grouped
        let live = Set(grouped.values.joined().map(\.id))
        insightRefreshGenerations = insightRefreshGenerations.filter { live.contains($0.key) }
    }

    public func invalidateModule(sessionID: UUID, modulePath: String) {
        guard let analysis = try? store.fetchModuleAnalysis(sessionID: sessionID, modulePath: modulePath) else { return }
        if let uuid = analysis.moduleUUID {
            try? store.deleteMemoryPagesModule(sessionID: sessionID, moduleUUID: uuid)
            memoryReaders[sessionID]?.forgetPages(ofModuleUUID: uuid)
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

    public func anchor(for address: UInt64, sessionID: UUID) -> AddressAnchor {
        guard let module = enclosingModule(at: address, sessionID: sessionID) else { return .absolute(address) }
        return .moduleOffset(name: module.name, offset: address &- module.base)
    }

    public func resolve(sessionID: UUID, anchor: AddressAnchor, hint: UInt64? = nil) async -> UInt64? {
        if let node = node(forSessionID: sessionID) {
            do {
                return try await node.resolve(anchor)
            } catch {
                return nil
            }
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
        let session = sessions.first { $0.id == id } ?? (try? store.fetchSession(id: id))
        let inLab = knownToLab(.session).contains(id)
        let forEveryone = inLab && (session.map(localUserHosts) ?? false || isLabOwner)
        collaboration.forget(removedSession: id)
        if forEveryone {
            collaboration.enqueueRemoveSession(sessionID: id)
        } else if inLab {
            try? store.dismissLabSession(id)
        }
        removeSessionHere(id)
    }

    public func canRemoveFromLab(_ session: ProcessSession) -> Bool {
        knownToLab(.session).contains(session.id) && (localUserHosts(session) || isLabOwner)
    }

    private func removeSessionHere(_ id: UUID) {
        let removedDeviceID = sessions.first(where: { $0.id == id })?.deviceID
        if let node = node(forSessionID: id) {
            removeNode(node)
        }
        rejectMyMissionActions(inSession: id)
        try? store.deleteSession(id: id)
        sessions.removeAll { $0.id == id }
        objectChats.forgetChats(ofSession: id)
        addressAnnotations[id] = nil
        onSessionListChanged?(.sessionRemoved(id))
        if let deviceID = removedDeviceID {
            Task { @MainActor [weak self] in
                await self?.evaluateGating(forDeviceID: deviceID)
            }
        }
    }

    private func rejectMyMissionActions(inSession sessionID: UUID) {
        let mine = ((try? store.fetchMissions()) ?? []).filter(isStartedByMe)
        for mission in mine {
            for action in (try? store.fetchPendingMissionActions(missionID: mission.id)) ?? [] where action.sessionID == sessionID {
                Task { await self.rejectMissionAction(actionID: action.id, reason: "The session was removed.") }
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
            blobs.delete(id: id, kind: .trace)
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
        if blobs.exists(id: traceID, kind: .trace) {
            let cached = try blobs.load(id: traceID, kind: .trace)
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
        try await loadBlob(
            id: traceID, sessionID: sessionID, kind: .trace, expectedSize: expectedSize, onProgress: onProgress)
    }

    /// The three tiers a blob is read through: the live capture still in the
    /// node, this session's on-disk store, then a paginated fetch from the lab.
    /// The live tier and the fetch are the trace's to give -- other kinds live
    /// only in the store until the blob transport is generalized -- so they are
    /// skipped for everything else.
    public func loadBlob(
        id: UUID,
        sessionID: UUID,
        kind: BlobKind,
        expectedSize: Int? = nil,
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async throws -> Data {
        if kind == .trace,
            let node = node(forSessionID: sessionID),
            let live = node.livePendingTraceData(traceID: id)
        {
            return live
        }

        let collabID = kind == .trace ? collabSessionID(forSessionID: sessionID) : nil
        var data: Data
        var cursor: Int

        if blobs.exists(id: id, kind: kind) {
            let cached = try blobs.load(id: id, kind: kind)
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
            return try blobs.load(id: id, kind: kind)
        }

        while expectedSize.map({ cursor < $0 }) ?? true {
            let remaining = expectedSize.map { $0 - cursor }
            let length = remaining.map { min($0, Self.traceDataPageSize) } ?? Self.traceDataPageSize
            let (chunk, totalSize) = try await collaboration.fetchTraceData(
                sessionID: sid,
                traceID: id,
                offset: cursor,
                length: length
            )
            if chunk.isEmpty { break }
            data.append(chunk)
            cursor += chunk.count
            onProgress?(cursor, expectedSize ?? totalSize)
            if expectedSize == nil, cursor >= totalSize { break }
        }

        try? blobs.write(data, id: id, kind: kind)
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
            if sessions[i].phase == .attached, session.phase != .attached {
                objectChats.discardDrafts(ofSession: session.id)
            }
            let modulesChanged = sessions[i].lastKnownModules != session.lastKnownModules
            sessions[i] = session
            if modulesChanged {
                rebuildAddressAnnotations(sessionID: session.id)
            }
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
        writeStagedWidgetStates()
        try? store.deleteInstrument(id: instance.id)
        forgetViewData(of: instance)
        widgetStates.removeValue(forKey: instance.id)
        forgetCounterAndConsoleTallies(of: instance.id)
        instrumentChildren.removeValue(forKey: instance.id)
        widgetPlacements.removeValue(forKey: instance.id)
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
                node.markInstrumentDetached(id: inst.id)
                broadcastInstrumentStatus(instanceID: inst.id, sessionID: node.sessionID)
                try? await node.disposeInstrumentOnAgent(instanceID: inst.id)
                dropTransientChildren(of: inst.id)
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

            case .codeShare:
                let cfg = try CodeShareConfig.decode(from: configJSON)
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
                guard try await loadCustomInstrument(instanceID: instanceID, bundle: bundle, config: cfg, on: node) else { return }
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

        for chat in objectChats.listed {
            guard case .instruction(sessionID, let anchor) = chat.subject, let addr = resolve(anchor) else { continue }
            map[addr, default: AddressAnnotation()].chatIDs.append(chat.id)
        }

        addressAnnotations[sessionID] = map
    }

    func instructionChatsChanged(from old: [ObjectChat], to new: [ObjectChat]) {
        let before = Self.instructionChatIDsBySession(in: old)
        let after = Self.instructionChatIDsBySession(in: new)
        for sessionID in Set(before.keys).union(after.keys) where before[sessionID] != after[sessionID] {
            rebuildAddressAnnotations(sessionID: sessionID)
        }
    }

    private static func instructionChatIDsBySession(in chats: [ObjectChat]) -> [UUID: Set<UUID>] {
        var bySession: [UUID: Set<UUID>] = [:]
        for chat in chats {
            if case .instruction(let sessionID, _) = chat.subject {
                bySession[sessionID, default: []].insert(chat.id)
            }
        }
        return bySession
    }

    func place(ofInstructionChat chatID: UUID, sessionID: UUID, anchor: AddressAnchor) -> ObjectChatInstructionPlace {
        ObjectChatInstructionPlace(
            sessionID: sessionID,
            anchor: anchor,
            address: addressAnnotations[sessionID]?.first { $0.value.chatIDs.contains(chatID) }?.key
                ?? resolveSync(sessionID: sessionID, anchor: anchor),
            sessionName: sessions.first { $0.id == sessionID }?.processName,
            presence: presence(ofSession: sessionID)
        )
    }

    public func presence(ofSession sessionID: UUID) -> SessionPresence {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return .unknown }
        return session.phase == .attached ? .attached : .detached
    }

    public func disassemblyUnavailableReason(at place: ObjectChatInstructionPlace) async -> String? {
        if let reason = place.unavailableReason { return reason }
        return await disassemblyUnavailableReason(sessionID: place.sessionID, address: place.address!)
    }

    public func disassemblyUnavailableReason(sessionID: UUID, address: UInt64) async -> String? {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return "The session this instruction is in is not in the project."
        }
        guard (try? await memoryReader(forSessionID: sessionID).read(at: address, count: 4)) == nil else { return nil }
        let at = anchor(sessionID: sessionID, address: address).displayString
        guard let host = session.host, host.id != localUserID else {
            return "The memory at \(at) was not read while \(session.processName) was attached."
        }
        return "\(host.name) has not shared the memory at \(at) with the lab yet."
    }

    public func disassemblyInsight(at place: ObjectChatInstructionPlace) throws -> AddressInsight {
        try getOrCreateInsight(sessionID: place.sessionID, pointer: place.address!, kind: .disassembly, preferredAnchor: place.anchor)
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
        let hookID = id.uuidString
        let ambientTypings = EditorProfile.fridaTracerHook(packages: installedPackages).ambientDeclarations

        return try await compilerWorkspace.withStagingArea(paths: paths) { area in
            let hookName = "\(hookID).ts"
            let hookPath = try area.write(tsSource, named: hookName)
            let entrySource = try Self.importsOfStaged(ambientTypings, in: area) + """
                import "./\(hookName)";
                export {};
                """
            let entryPath = try area.write(entrySource, named: "luma-entry.ts")

            let areaPrefix = "\(area.relativePath)/"
            let bundle = try await compilerWorkspace.withCompilerDiagnostics(
                label: "tracer hook \(hookID)",
                pathDisplay: { path in
                    if path.hasSuffix(hookPath) || path.hasSuffix(entryPath) {
                        return displayName
                    }
                    return Self.displayPath(of: path, strippingAnyOf: [areaPrefix])
                }
            ) { compiler in
                try await compiler.build(
                    entrypoint: entryPath,
                    projectRoot: paths.root.path,
                    sourceMaps: .omitted,
                    compression: .terser)
            }

            let modules = try ESMBundleParser.parse(bundle)
            return modules.modules[modules.order[0]]!
        }
    }

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

    @discardableResult
    public func loadCustomInstrument(
        instanceID: UUID,
        bundle: CustomInstrumentBundle,
        config: CustomInstrumentConfig,
        on node: ProcessNode
    ) async throws -> Bool {
        forgetCounterAndConsoleTallies(of: instanceID)
        let def = bundle.def
        guard await instrumentViews.isAllowed(instanceID) else {
            broadcastInstrumentStatus(instanceID: instanceID, sessionID: node.sessionID)
            return false
        }
        let paths = try compilerWorkspacePaths()
        let sourceSlug = "Custom/\(def.id.uuidString)"
        let files = bundle.files.map { (path: $0.path, content: Data($0.content.utf8)) }
        let compiledSource = try await compileTypeScriptInstrument(
            sourceSlug: sourceSlug,
            files: files,
            entrypoint: def.entrypoint,
            dependencies: def.dependencies,
            ambientTypings: CustomInstrumentTypings.compilerTypings(for: def, packages: installedPackages),
            paths: paths,
            diagnosticLabel: "custom instrument \(def.id.uuidString)"
        )

        let digest = SHA256.hash(data: Data(compiledSource.utf8))
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        let moduleName = "/\(sourceSlug)/\(hashHex).js"

        let restored = hydrateRestoredState(instanceID: instanceID, def: def)

        try await node.loadInstrumentOnAgent(
            instanceID: instanceID,
            moduleName: moduleName,
            source: compiledSource,
            config: config.toAgentJSON(def: def),
            restored: restored,
            childTemplates: def.children.map(\.id)
        )
        return true
    }

    private func hydrateRestoredState(instanceID: UUID, def: CustomInstrumentDef) -> [String: Any] {
        let children = restoreChildren(of: instanceID, def: def)
        let persistent = def.widgets.filter { $0.persistence == .session }.map { (slot: $0.id, widget: $0) }
            + children.flatMap { child in
                (def.children.first { $0.id == child.ref.template }?.widgets ?? []).filter { $0.persistence == .session }
                    .map { (slot: child.widgetKey($0.id), widget: $0) }
            }
        let states = persistent.isEmpty ? [:] : persistedWidgetStates(instanceID: instanceID)
        restartWidgetStates(
            of: instanceID, declared: def.widgets.map(\.id),
            restored: Dictionary(uniqueKeysWithValues: persistent.map { ($0.slot, states[$0.slot] ?? WidgetState()) }))
        guard !persistent.isEmpty else { return [:] }

        var restored: [String: Any] = [:]
        for widget in def.widgets where widget.persistence == .session {
            restored[widget.id] = restoredValue(of: widget, state: states[widget.id] ?? WidgetState())
        }
        var restoredChildren: [String: [String: Any]] = [:]
        for child in children {
            let widgets = (def.children.first { $0.id == child.ref.template }?.widgets ?? []).filter { $0.persistence == .session }
            var entry = child.toWireJSON()
            entry["widgets"] = Dictionary(uniqueKeysWithValues: widgets.map {
                ($0.id, restoredValue(of: $0, state: states[child.widgetKey($0.id)] ?? WidgetState()))
            })
            restoredChildren[child.ref.template, default: [:]][child.ref.id] = entry
        }
        if !restoredChildren.isEmpty {
            restored["children"] = restoredChildren
        }
        return restored
    }

    private func restoredValue(of widget: InstrumentWidget, state: WidgetState) -> Any {
        switch widget.kind {
        case .counter:
            if let counter = state.counter {
                var obj: [String: Any] = ["value": counter.value]
                if let unit = counter.unit { obj["unit"] = unit }
                if let delta = counter.delta { obj["delta"] = delta }
                if let fractionDigits = counter.fractionDigits { obj["fractionDigits"] = fractionDigits }
                return ["counter": obj]
            } else {
                return ["counter": NSNull()]
            }
        case .histogram:
            let buckets = state.histogram.map { ["label": $0.label, "count": $0.count] }
            return ["buckets": buckets]
        case .graph:
            let points = state.graphSeries.flatMap { (seriesID, pts) -> [[String: Any]] in
                pts.map { ["series": seriesID, "x": $0.x, "y": $0.y] }
            }
            return ["points": points]
        case .list:
            let items = state.listItems.map { item -> [String: Any] in
                var obj: [String: Any] = ["id": item.id, "title": item.title]
                if let s = item.subtitle { obj["subtitle"] = s }
                if let a = item.accessory { obj["accessory"] = a }
                return obj
            }
            return ["items": items]
        case .table:
            let rows = state.tableRows.map { row -> [String: Any] in
                ["id": row.id, "cells": row.cells]
            }
            return ["rows": rows]
        case .hex:
            if let hex = state.hex {
                return [
                    "hex": [
                        "bytes": hex.bytes.base64EncodedString(),
                        "base_address": HexAddress.string(hex.baseAddress),
                    ],
                ]
            } else {
                return ["hex": NSNull()]
            }
        case .console:
            return ["entries": state.consoleEntries.map { $0.toWireJSON() }]
        case .view:
            return ["state": state.view?.payload.value ?? NSNull()]
        }
    }

    private func forgetCounterAndConsoleTallies(of instanceID: UUID) {
        consoleEntriesDropped = consoleEntriesDropped.filter { $0.key.instanceID != instanceID }
        fractionalCounters = fractionalCounters.filter { $0.key.instanceID != instanceID }
    }

    public func counterText(_ counter: WidgetCounterValue, instanceID: UUID?, widget: String) -> CounterText {
        let steady = counter.hasFraction || instanceID.map {
            fractionalCounters.contains(FractionalCounter(key: InstrumentViews.Key(instanceID: $0, widget: widget), unit: counter.unit))
        } ?? false
        return counter.text(steadyFractionDigits: steady ? 1 : 0)
    }

    public func consoleEntriesNotKept(instanceID: UUID, widget: String) -> String? {
        let dropped = consoleEntriesDropped[InstrumentViews.Key(instanceID: instanceID, widget: widget)] ?? 0
        return dropped > 0 ? "\(dropped.formatted()) earlier entries not kept" : nil
    }

    public func widgetState(instanceID: UUID, widget: String) -> WidgetState {
        widgetStates[instanceID]?[widget] ?? WidgetState()
    }

    func widgetSlots(of instanceID: UUID) -> [String] {
        Array((widgetStates[instanceID] ?? [:]).keys)
    }

    func forgetWidgetState(_ slot: String, of instanceID: UUID) {
        widgetStates[instanceID]?[slot] = nil
    }

    public func placements(forWidget widget: String, of instanceID: UUID) -> [PatternPlacement] {
        widgetPlacements[instanceID]?[widget] ?? []
    }

    public func setPlacements(_ placements: [PatternPlacement], forWidget widget: String, of instanceID: UUID) {
        guard let instance = storePlacements(placements, forWidget: widget, of: instanceID) else { return }
        collaboration.enqueueSetPlacements(placements, sessionID: instance.sessionID, on: .widget(instanceID: instanceID, widget: widget))
    }

    @discardableResult
    private func storePlacements(_ placements: [PatternPlacement], forWidget widget: String, of instanceID: UUID) -> InstrumentInstance? {
        guard let instance = try? store.fetchInstrument(id: instanceID) else { return nil }
        widgetPlacements[instanceID, default: [:]][widget] = placements
        try? store.saveWidgetPlacements(placements, instanceID: instanceID, widgetID: widget)
        return instance
    }

    private func hydrateWidgetStatesFromStore(_ grouped: [UUID: [InstrumentInstance]]) {
        for instances in grouped.values {
            for instance in instances where widgetStates[instance.id] == nil && instrumentChildren[instance.id] == nil && instance.kind == .custom {
                guard let def = UUID(uuidString: instance.sourceIdentifier).flatMap(customInstruments.def(withId:)) else { continue }
                _ = hydrateRestoredState(instanceID: instance.id, def: def)
            }
        }
    }

    private func compileTypeScriptInstrument(
        sourceSlug: String,
        files: [(path: String, content: Data)],
        entrypoint: String,
        dependencies: [String: String],
        ambientTypings: [AmbientDeclarations],
        paths: CompilerWorkspacePaths,
        diagnosticLabel: String
    ) async throws -> String {
        _ = try await compilerWorkspace.ensureReady(paths: paths)

        let sourcesRelPath = "InstrumentSources/\(sourceSlug)"
        let sourcesURL = paths.root.appendingPathComponent(sourcesRelPath, isDirectory: true)
        try Self.syncInstrumentSources(files, into: sourcesURL)
        try await compilerWorkspace.installDependencies(dependencies, in: sourcesURL)

        let userEntry = try CustomInstrumentFile.validateRelativePath(entrypoint)
        let userEntryPath = "\(sourcesRelPath)/\(userEntry)"

        return try await compilerWorkspace.withStagingArea(paths: paths) { area in
            let entryPath = try Self.stageInstrumentEntry(reexporting: userEntryPath, ambientTypings: ambientTypings, in: area)

            let displayedPrefixes = ["\(sourcesRelPath)/", "\(area.relativePath)/"]
            let bundle = try await compilerWorkspace.withCompilerDiagnostics(
                label: diagnosticLabel,
                pathDisplay: { path in Self.displayPath(of: path, strippingAnyOf: displayedPrefixes) }
            ) { compiler in
                try await compiler.build(
                    entrypoint: entryPath,
                    projectRoot: paths.root.path,
                    sourceMaps: .omitted,
                    compression: .terser)
            }

            let modules = try ESMBundleParser.parse(bundle)
            return modules.modules[modules.order[0]]!
        }
    }

    private static func syncInstrumentSources(_ files: [(path: String, content: Data)], into dirURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)

        var wanted = Set<String>()
        for file in files {
            let path = try CustomInstrumentFile.validateRelativePath(file.path)
            wanted.insert(path)
            let fileURL = dirURL.appendingPathComponent(path)
            if fm.contents(atPath: fileURL.path) == file.content { continue }
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: fileURL)
        }

        let dependencyArtifacts = CompilerWorkspacePaths(root: dirURL).dependencyArtifactNames
        for path in try fm.subpathsOfDirectory(atPath: dirURL.path) where !wanted.contains(path) {
            if dependencyArtifacts.contains(String(path.prefix { $0 != "/" })) { continue }
            var isDirectory: ObjCBool = false
            let url = dirURL.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                try fm.removeItem(at: url)
            }
        }
    }

    private static func stageInstrumentEntry(
        reexporting userEntryPath: String,
        ambientTypings: [AmbientDeclarations],
        in area: CompilerStagingArea
    ) throws -> String {
        let wrapper = try importsOfStaged(ambientTypings, in: area)
            + "export * from \"\(area.importSpecifier(ofWorkspacePath: userEntryPath))\";\n"
        return try area.write(wrapper, named: "luma-entry.ts")
    }

    private static func importsOfStaged(_ typings: [AmbientDeclarations], in area: CompilerStagingArea) throws -> String {
        try typings.map { declarations in
            let name = "luma-" + declarations.fileName.replacingOccurrences(of: ".d.ts", with: ".ts")
            try area.write(declarations.content, named: name)
            return "import \"./\(name)\";\n"
        }.joined()
    }

    nonisolated private static func displayPath(of path: String, strippingAnyOf prefixes: [String]) -> String {
        guard let range = prefixes.lazy.compactMap({ path.range(of: $0) }).first else { return path }
        return String(path[range.upperBound...])
    }

    static func validatedCustomInstrumentBundle(_ bundle: CustomInstrumentBundle) throws -> CustomInstrumentBundle {
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
            settings: [],
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

    public func updateCustomInstrument(_ defID: UUID, _ change: (inout CustomInstrumentDef) -> Void) {
        guard let current = customInstruments.def(withId: defID) else { return }
        var updated = current
        change(&updated)
        guard updated != current else { return }
        updateCustomInstrument(updated)
    }

    public func updateCustomInstrument(_ def: CustomInstrumentDef) {
        if let problem = def.childrenProblemSentence {
            emitEngineError(subsystem: "instruments", text: "“\(def.name)” was not saved: \(problem)")
            return
        }
        var updated = def
        updated.normalize()
        updated.requireLuma(given: (try? store.fetchCustomInstrumentFiles(defID: def.id)) ?? [])
        updated.updatedAt = Date()
        try? store.save(updated)
        registerDescriptor(customInstruments.descriptor(for: updated))
        broadcastCustomInstrumentUpsert(defID: updated.id)
        onSessionListChanged?(.customInstrumentDefsChanged)
        scheduleCustomInstrumentReload(defID: updated.id)
    }

    @discardableResult
    public func addCustomInstrumentFile(defID: UUID, path: String, by author: CustomInstrumentAuthor = .localUser) throws -> String {
        let validatedPath = try CustomInstrumentFile.validateRelativePath(path)
        try requireNoProblem(customInstrumentFileProblem(defID: defID, path: validatedPath))
        return try writeCustomInstrumentFile(
            defID: defID,
            path: validatedPath,
            content: PatternSource.Kind(path: validatedPath)?.template ?? "",
            by: author
        )
    }

    @discardableResult
    public func writeCustomInstrumentFile(
        defID: UUID,
        path: String,
        content: String,
        by author: CustomInstrumentAuthor = .localUser
    ) throws -> String {
        let validatedPath = try CustomInstrumentFile.validateRelativePath(path)
        try requireNoProblem(reservedCustomInstrumentFileProblem(defID: defID, path: validatedPath))
        let file = CustomInstrumentFile(defID: defID, path: validatedPath, content: content)
        _ = try requireCustomInstrumentDef(defID: defID)
        try noteHostCodeEdit(ofCustomInstrument: defID, by: author) {
            try store.save(file)
        }
        try store.save(requiringLuma(touchUpdatedAt(defID: defID)))
        broadcastCustomInstrumentUpsert(defID: defID)
        scheduleCustomInstrumentReload(defID: defID)
        return validatedPath
    }

    public func deleteCustomInstrumentFile(defID: UUID, path: String, by author: CustomInstrumentAuthor = .localUser) throws {
        let validatedPath = try CustomInstrumentFile.validateRelativePath(path)
        let def = try requireCustomInstrumentDef(defID: defID)
        guard def.entrypoint != validatedPath else {
            throw LumaCoreError.invalidOperation("Cannot delete the entrypoint file.")
        }
        try noteHostCodeEdit(ofCustomInstrument: defID, by: author) {
            try store.deleteCustomInstrumentFile(defID: defID, path: validatedPath)
        }
        try store.save(touchUpdatedAt(defID: defID))
        broadcastCustomInstrumentUpsert(defID: defID)
        scheduleCustomInstrumentReload(defID: defID)
    }

    @discardableResult
    public func renameCustomInstrumentFile(
        defID: UUID,
        from: String,
        to: String,
        by author: CustomInstrumentAuthor = .localUser
    ) throws -> String {
        let fromPath = try CustomInstrumentFile.validateRelativePath(from)
        let toPath = try CustomInstrumentFile.validateRelativePath(to)
        guard try store.fetchCustomInstrumentFile(defID: defID, path: fromPath) != nil else {
            throw LumaCoreError.invalidArgument("No file '\(fromPath)' in this custom instrument.")
        }
        try requireNoProblem(customInstrumentFileProblem(defID: defID, path: toPath))
        let renamesEntrypoint = try requireCustomInstrumentDef(defID: defID).entrypoint == fromPath
        if renamesEntrypoint {
            try Self.requireEntrypointCandidate(toPath)
        }
        try noteHostCodeEdit(ofCustomInstrument: defID, by: author) {
            try store.renameCustomInstrumentFile(defID: defID, from: fromPath, to: toPath)
        }
        var def = try requiringLuma(touchUpdatedAt(defID: defID))
        if renamesEntrypoint {
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
        try Self.requireEntrypointCandidate(validatedPath)
        var def = try touchUpdatedAt(defID: defID)
        def.entrypoint = validatedPath
        try store.save(def)
        broadcastCustomInstrumentUpsert(defID: defID)
        scheduleCustomInstrumentReload(defID: defID)
        return validatedPath
    }

    private func noteHostCodeEdit(ofCustomInstrument defID: UUID, by author: CustomInstrumentAuthor, _ edit: () throws -> Void) throws {
        let previous = HostCode(files: try store.fetchCustomInstrumentFiles(defID: defID))
        try edit()
        let next = HostCode(files: try store.fetchCustomInstrumentFiles(defID: defID))
        switch author {
        case .localUser:
            instrumentViews.noteLocalEdit(from: previous, to: next)
        case .mission:
            guard next != nil, next != previous else { return }
            recordCodeOrigin(.mission, ofCustomInstrument: defID)
        }
    }

    func codeOrigin(ofCustomInstrument defID: UUID) -> HostCodeOrigin {
        if let link = instrumentFolderLinks[defID] {
            return .folder(path: link.path)
        }
        return (try? store.fetchCodeOrigin(ofCustomInstrument: defID)) ?? .project
    }

    private func recordCodeOrigin(_ origin: HostCodeOrigin, ofCustomInstrument defID: UUID) {
        try? store.saveCodeOrigin(origin, ofCustomInstrument: defID)
    }

    private func requiringLuma(_ def: CustomInstrumentDef) throws -> CustomInstrumentDef {
        var required = def
        required.requireLuma(given: try store.fetchCustomInstrumentFiles(defID: def.id))
        return required
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
        guard let def = try store.fetchCustomInstrumentDef(id: defID) else {
            throw LumaCoreError.invalidArgument("No custom instrument with id \(defID).")
        }
        return def
    }

    public func customInstrumentFileProblem(defID: UUID, path: String) -> String? {
        if customInstruments.file(defID: defID, path: path) != nil {
            return "There is already a file '\(path)' in this custom instrument."
        }
        return reservedCustomInstrumentFileProblem(defID: defID, path: path)
    }

    private func reservedCustomInstrumentFileProblem(defID: UUID, path: String) -> String? {
        let folder = instrumentFolderLinks[defID].flatMap { try? InstrumentFolder(folderURL: $0.folderURL) }
        let prefix = folder?.prefix ?? ""
        let ownPath = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        let usesIconFile = if case .pixels = customInstruments.def(withId: defID)?.icon { true } else { false }
        let iconPath = usesIconFile ? folder?.iconPath ?? InstrumentFolder.defaultIconFileName : nil
        guard path.hasPrefix(prefix), !InstrumentFolder.isInstrumentFile(ownPath, iconPath: iconPath) else { return nil }
        return "'\(path)' is kept by Luma and cannot be a file of this custom instrument."
    }

    private func requireNoProblem(_ problem: String?) throws {
        if let problem {
            throw LumaCoreError.invalidArgument(problem)
        }
    }

    private func touchUpdatedAt(defID: UUID) throws -> CustomInstrumentDef {
        var def = try requireCustomInstrumentDef(defID: defID)
        def.updatedAt = Date()
        return def
    }

    private static func requireEntrypointCandidate(_ path: String) throws {
        guard PatternSource.Kind(path: path) == nil else {
            throw LumaCoreError.invalidArgument("A pattern file cannot be the entrypoint.")
        }
    }

    @discardableResult
    public func linkInstrumentFolder(at folderURL: URL) throws -> CustomInstrumentDef {
        let folderURL = folderURL.standardizedFileURL
        if let defID = customInstrumentID(linkedToFolderAt: folderURL) {
            return try requireCustomInstrumentDef(defID: defID)
        }

        let now = Date()
        let bundle = try Self.validatedCustomInstrumentBundle(
            InstrumentFolder(folderURL: folderURL).customInstrument(id: UUID(), createdAt: now, updatedAt: now)
        )
        try saveCustomInstrumentBundle(bundle)
        recordCodeOrigin(.folder(path: folderURL.path), ofCustomInstrument: bundle.def.id)
        try InstrumentFolder.writeTypings(for: bundle.def, to: folderURL)
        setInstrumentFolderLink(InstrumentFolderLink(path: folderURL.path, synced: .init(of: bundle)), forDefID: bundle.def.id)
        watchInstrumentFolder(defID: bundle.def.id)
        return bundle.def
    }

    public func customInstrumentID(linkedToFolderAt folderURL: URL) -> UUID? {
        let path = folderURL.standardizedFileURL.path
        return instrumentFolderLinks.first { $0.value.folderURL.standardizedFileURL.path == path }?.key
    }

    private func forgetCustomInstrument(_ defID: UUID) {
        try? store.deleteCustomInstrumentDef(id: defID)
        unlinkInstrumentFolder(defID: defID)
    }

    public func unlinkInstrumentFolder(defID: UUID) {
        setInstrumentFolderLink(nil, forDefID: defID)
        watchInstrumentFolder(defID: defID)
    }

    public func reloadCustomInstrumentFromFolder(defID: UUID) throws {
        var link = try requireInstrumentFolderLink(defID: defID)
        var bundle = try Self.validatedCustomInstrumentBundle(
            folderContents(for: storedCustomInstrumentBundle(defID: defID).def, in: link.folderURL)
        )
        bundle.def.updatedAt = Date()
        try saveCustomInstrumentBundle(bundle)
        recordCodeOrigin(.folder(path: link.path), ofCustomInstrument: defID)
        try InstrumentFolder.writeTypings(for: bundle.def, to: link.folderURL)
        link.synced = .init(of: bundle)
        setInstrumentFolderLink(link, forDefID: defID)
        instrumentFolderDrifts[defID] = nil
        scheduleCustomInstrumentReload(defID: defID)
    }

    public func writeCustomInstrumentToFolder(defID: UUID) throws {
        try writeToFolder(storedCustomInstrumentBundle(defID: defID), link: requireInstrumentFolderLink(defID: defID))
        settleInstrumentFolder(defID: defID)
    }

    public func exportCustomInstrument(defID: UUID, to folderURL: URL) throws {
        try InstrumentFolder.write(exportableCustomInstrumentBundle(defID: defID), to: folderURL)
    }

    public func exportedFiles(forCustomInstrument defID: UUID) throws -> [InstrumentFolder.File] {
        try InstrumentFolder.files(for: exportableCustomInstrumentBundle(defID: defID))
    }

    private func saveCustomInstrumentBundle(_ bundle: CustomInstrumentBundle) throws {
        try store.save(bundle.def)
        try store.replaceCustomInstrumentFiles(defID: bundle.def.id, files: bundle.files)
        registerDescriptor(customInstruments.descriptor(for: bundle.def))
        broadcastCustomInstrumentUpsert(defID: bundle.def.id)
        onSessionListChanged?(.customInstrumentDefsChanged)
    }

    private func setInstrumentFolderLink(_ link: InstrumentFolderLink?, forDefID defID: UUID) {
        LumaAppState.shared.setInstrumentFolderLink(link, forDefID: defID)
        instrumentFolderLinks[defID] = link
    }

    private func restoreInstrumentFolderLinks() {
        for def in customInstruments.defs where instrumentFolderLinks[def.id] == nil {
            guard let link = LumaAppState.shared.instrumentFolderLink(forDefID: def.id) else { continue }
            instrumentFolderLinks[def.id] = link
            watchInstrumentFolder(defID: def.id)
        }
    }

    private func watchInstrumentFolder(defID: UUID) {
        instrumentFolderMonitors.removeValue(forKey: defID)?.stop()
        guard let link = instrumentFolderLinks[defID] else {
            instrumentFolderDrifts[defID] = nil
            instrumentFolderSyncFailures[defID] = nil
            return
        }
        instrumentFolderMonitors[defID] = InstrumentFolderMonitor(folderURL: link.folderURL) { [weak self] in
            self?.settleInstrumentFolder(defID: defID)
        }
        settleInstrumentFolder(defID: defID)
    }

    private func settleInstrumentFolders() {
        for defID in instrumentFolderLinks.keys {
            settleInstrumentFolder(defID: defID)
        }
    }

    private func settleInstrumentFolder(defID: UUID) {
        if let link = instrumentFolderLinks[defID], isRemovedFromLibrary(link) {
            unlinkInstrumentFolder(defID: defID)
            return
        }
        do {
            instrumentFolderDrifts[defID] = try writeThroughOrReportDrift(defID: defID)
            instrumentFolderSyncFailures[defID] = nil
        } catch {
            let name = customInstruments.def(withId: defID)?.name ?? "A custom instrument"
            let text = "\(name) could not be synced with its folder: \(userFacingMessage(error))"
            guard instrumentFolderSyncFailures[defID] != text else { return }
            instrumentFolderSyncFailures[defID] = text
            emitEngineError(subsystem: "instruments", text: text)
        }
    }

    private func isRemovedFromLibrary(_ link: InstrumentFolderLink) -> Bool {
        let parentPath = link.folderURL.deletingLastPathComponent().standardizedFileURL.path
        let isInLibrary = parentPath == instrumentFolders.directory.standardizedFileURL.path
        return isInLibrary && !FileManager.default.fileExists(atPath: link.folderURL.path)
    }

    private func writeThroughOrReportDrift(defID: UUID) throws -> InstrumentFolderDrift? {
        var link = try requireInstrumentFolderLink(defID: defID)
        let project = try storedCustomInstrumentBundle(defID: defID)
        let inProject = InstrumentFolderLink.Snapshot(of: project)
        let inFolder = InstrumentFolderLink.Snapshot(of: try folderContents(for: project.def, in: link.folderURL))

        if inFolder == inProject {
            link.synced = inProject
            setInstrumentFolderLink(link, forDefID: defID)
            return nil
        }

        if inFolder == link.synced {
            do {
                try writeToFolder(project, link: link)
            } catch {
                emitEngineError(
                    subsystem: "instruments",
                    text: "Failed to write \(project.def.name) to \(link.path): \(userFacingMessage(error))"
                )
            }
            return nil
        }

        return inProject == link.synced ? .folderChanged : .diverged
    }

    private func writeToFolder(_ instrument: CustomInstrumentBundle, link: InstrumentFolderLink) throws {
        try InstrumentFolder.write(
            Self.validatedCustomInstrumentBundle(instrument),
            to: link.folderURL,
            replacing: link.synced.files.keys
        )
        let written = try folderContents(for: instrument.def, in: link.folderURL)
        let writtenSnapshot = InstrumentFolderLink.Snapshot(of: written)
        if writtenSnapshot != InstrumentFolderLink.Snapshot(of: instrument) {
            try saveCustomInstrumentBundle(written)
        }
        var link = link
        link.synced = writtenSnapshot
        setInstrumentFolderLink(link, forDefID: instrument.def.id)
    }

    private func requireInstrumentFolderLink(defID: UUID) throws -> InstrumentFolderLink {
        guard let link = instrumentFolderLinks[defID] else {
            throw LumaCoreError.invalidOperation("Custom instrument \(defID) is not linked to a folder.")
        }
        return link
    }

    private func folderContents(for def: CustomInstrumentDef, in folderURL: URL) throws -> CustomInstrumentBundle {
        try InstrumentFolder(folderURL: folderURL).customInstrument(id: def.id, createdAt: def.createdAt, updatedAt: def.updatedAt)
    }

    private func exportableCustomInstrumentBundle(defID: UUID) throws -> CustomInstrumentBundle {
        try Self.validatedCustomInstrumentBundle(storedCustomInstrumentBundle(defID: defID))
    }

    func storedSnapshot(ofCustomInstrument defID: UUID) throws -> InstrumentFolderLink.Snapshot {
        InstrumentFolderLink.Snapshot(of: try storedCustomInstrumentBundle(defID: defID))
    }

    private func storedCustomInstrumentBundle(defID: UUID) throws -> CustomInstrumentBundle {
        CustomInstrumentBundle(
            def: try requireCustomInstrumentDef(defID: defID),
            files: try store.fetchCustomInstrumentFiles(defID: defID).sorted { $0.path < $1.path }
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
        item: String?,
        actionID: UUID,
        seenRevision: Int
    ) {
        guard isHostingNode(sessionID) else { return }
        if let refusal = refusal(ofRemoteAction: action, on: widget, item: item, instanceID: instanceID, sessionID: sessionID, seenRevision: seenRevision) {
            return collaboration.sendOutcome(sessionID: sessionID, actionID: actionID, offersFile: false, error: refusal)
        }
        let instance = instrumentsBySession[sessionID]!.first { $0.id == instanceID }!
        Task { @MainActor [weak self] in
            await self?.runAction(instance: instance, widget: widget, action: action, item: item, actionID: actionID, recipient: .member(sessionID))
        }
    }

    private func reconcileWidgetStates(with lab: [WidgetStateSnapshot]) {
        let held = Dictionary(grouping: lab, by: \.sessionID)
        for session in sessions where !localUserHosts(session) {
            adoptWidgetStates(of: session.id, from: held[session.id] ?? [])
        }
        for session in sessions where localUserHosts(session) && isHostingNode(session.id) {
            republishWidgetStates(of: session.id, over: held[session.id] ?? [])
        }
        let viewing = lab.filter { localUserHosts($0.sessionID) && !isHostingNode($0.sessionID) }
        publishWidgetStates(newerThan: viewing)
        for snapshot in viewing {
            let update = WidgetUpdate(
                instanceID: snapshot.instanceID,
                widget: snapshot.widget,
                kind: .snapshot(snapshot.state),
                revision: snapshot.state.revision
            )
            applyWidgetUpdate(update, sessionID: snapshot.sessionID, origin: .remote)
        }
    }

    private func publishWidgetStates(newerThan lab: [WidgetStateSnapshot]) {
        let labRevisions = Dictionary(
            lab.map { (InstrumentViews.Key(instanceID: $0.instanceID, widget: $0.widget), $0.state.revision) },
            uniquingKeysWith: max)
        for session in sessions where session.host != nil && localUserHosts(session) && !isHostingNode(session.id) {
            for instance in instrumentsBySession[session.id] ?? [] {
                for (widget, state) in widgetStates[instance.id] ?? [:]
                where state.revision > labRevisions[InstrumentViews.Key(instanceID: instance.id, widget: widget)] ?? 0 {
                    publish(state, of: instance.id, widget: widget, sessionID: session.id)
                }
            }
        }
    }

    func publish(_ state: WidgetState, of instanceID: UUID, widget: String, sessionID: UUID) {
        if let view = state.view {
            collaboration.sendViewState(view, sessionID: sessionID, instanceID: instanceID, widget: widget)
        } else {
            let update = WidgetUpdate(instanceID: instanceID, widget: widget, kind: .snapshot(state), revision: state.revision)
            collaboration.sendWidgetUpdate(sessionID: sessionID, update: update)
        }
    }

    private func adoptWidgetPlacements(_ labPlacements: [UUID: [String: [PatternPlacement]]]) {
        widgetPlacements.merge(labPlacements) { _, lab in lab }
        try? store.replaceWidgetPlacements(labPlacements)
    }

    private func applyWidgetUpdate(_ proposed: WidgetUpdate, sessionID: UUID, origin: WidgetUpdateOrigin) {
        guard let update = admitted(proposed, sessionID: sessionID, origin: origin) else { return }
        let key = InstrumentViews.Key(instanceID: update.instanceID, widget: update.widget)
        let widgetDef = widget(forInstanceID: update.instanceID, widgetID: update.widget)
        var dropped = 0
        let state = modifyWidgetState(of: key) { state in
            state.apply(update.kind)
            if !update.kind.isTransient {
                state.revision = max(state.revision, update.revision)
            }
            if let widgetDef { dropped = state.cap(to: widgetDef.kind) }
        }
        if case .counterSet(let counter) = update.kind, counter.hasFraction {
            fractionalCounters.insert(FractionalCounter(key: key, unit: counter.unit))
        }
        switch update.kind {
        case .clear, .snapshot:
            consoleEntriesDropped[key] = dropped
        default:
            consoleEntriesDropped[key, default: 0] += dropped
        }
        if origin == .local, isHostingNode(sessionID) {
            noteRows(of: key, changedBy: update)
        }
        _widgetUpdates.yield(update)

        if let widgetDef, widgetDef.persistence == .session, !update.kind.isTransient {
            store.stageWidgetState(state, instanceID: key.instanceID, widgetID: key.widget)
            scheduleWidgetStateWrite()
            if widgetDef.kind.isView {
                persistViewData(of: state.view, instanceID: key.instanceID, widget: key.widget)
            }
        }

        if origin == .local, let collabSID = collabSessionID(forSessionID: sessionID) {
            switch update.kind {
            case .viewState(let viewState):
                collaboration.sendViewState(viewState, sessionID: collabSID, instanceID: update.instanceID, widget: update.widget)
            case .viewEvent(let payload):
                collaboration.sendViewEvent(payload, sessionID: collabSID, instanceID: update.instanceID, widget: update.widget)
            case .viewRefused:
                break
            default:
                collaboration.sendWidgetUpdate(sessionID: collabSID, update: update)
            }
        }
    }

    private func admitted(_ proposed: WidgetUpdate, sessionID: UUID, origin: WidgetUpdateOrigin) -> WidgetUpdate? {
        let state = widgetStates[proposed.instanceID]?[proposed.widget] ?? WidgetState()
        switch origin {
        case .local:
            return localUserHosts(sessionID) ? stamped(proposed, after: state) : proposed
        case .remote:
            return proposed.supersedes(state) ? proposed : nil
        }
    }

    private func modifyWidgetState(of key: InstrumentViews.Key, _ body: (inout WidgetState) -> Void) -> WidgetState {
        body(&widgetStates[key.instanceID, default: [:]][key.widget, default: WidgetState()])
        return widgetStates[key.instanceID]![key.widget]!
    }

    func scheduleWidgetStateWrite() {
        guard widgetStateWrite == .idle else { return }
        widgetStateWrite = .scheduled
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.widgetStateWriteDelay)
            self?.writeStagedWidgetStates()
        }
    }

    private func writeStagedWidgetStates() {
        widgetStateWrite = .idle
        store.writeStagedWidgetStates()
    }

    private func stamped(_ update: WidgetUpdate, after state: WidgetState) -> WidgetUpdate {
        guard !update.kind.isTransient else { return update }
        let revision = state.revision + 1
        var kind = update.kind
        if case .viewState(var next) = kind {
            next.revision = revision
            kind = .viewState(next)
        }
        return WidgetUpdate(id: update.id, instanceID: update.instanceID, widget: update.widget, kind: kind, revision: revision)
    }

    public func submitConsoleInput(
        instance: InstrumentInstance,
        widget: String,
        text: String
    ) async {
        let entry = WidgetConsoleEntry(kind: .input, text: text)
        await dispatchConsoleInput(instance: instance, widget: widget, entry: entry, recipient: .person)
    }

    public struct ConsoleResponse: Sendable {
        public let inputEntryID: String
        public let replies: [WidgetConsoleEntry]
        public var offeredFile: OfferedFileSummary? = nil
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
        guard canSubmitConsoleInput(of: instance) else { return ConsoleResponse(inputEntryID: inputID, replies: []) }
        let instanceID = instance.id
        let updates = widgetUpdates
        let offeredFile = await dispatchConsoleInput(instance: instance, widget: widget, entry: entry, recipient: nil)

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
        return ConsoleResponse(inputEntryID: inputID, replies: await buffer.snapshot(), offeredFile: offeredFile)
    }

    @discardableResult
    private func dispatchConsoleInput(
        instance: InstrumentInstance,
        widget: String,
        entry: WidgetConsoleEntry,
        recipient: FileRecipient?
    ) async -> OfferedFileSummary? {
        if let refusal = gateRefusal(of: instance) {
            emitEngineWarning(subsystem: "instruments", text: refusal)
            return nil
        }
        guard canSubmitConsoleInput(of: instance) else { return nil }
        let update = WidgetUpdate(instanceID: instance.id, widget: widget, kind: .consoleAppend(entry))
        applyWidgetUpdate(update, sessionID: instance.sessionID, origin: .local)

        guard let node = node(forSessionID: instance.sessionID),
            node.instruments.first(where: { $0.id == instance.id })?.attachment == .attached
        else { return nil }
        let actionID = UUID()
        fileRecipients[actionID] = recipient
        do {
            let outcome = try await node.submitConsoleInput(
                instanceID: instance.id, widget: widget, entryID: entry.id, text: entry.text, actionID: actionID, savesFile: recipient != nil)
            handlerEnded(actionID: actionID, offeredFile: outcome.file != nil)
            show(outcome.show, toChooserOf: actionID, recipient: recipient, instance: instance)
            return outcome.file
        } catch {
            handlerEnded(actionID: actionID, offeredFile: false)
            emitEngineError(subsystem: "instruments", text: "Failed to submit console input on \(widget): \(userFacingMessage(error))")
            return nil
        }
    }

    public func canChooseWidgetActions(of instance: InstrumentInstance) -> Bool {
        canReachAgent(of: instance)
    }

    public func widgetActionRefusal(of instance: InstrumentInstance) -> String? {
        guard !canReachAgent(of: instance) else { return nil }
        let hosting = isHostingNode(instance.sessionID)
        if !hosting && !isHostedRemotelyLive(instance.sessionID) {
            return "The session is not attached."
        }
        if !hosting && !collaboration.isOwner {
            return "Only the member hosting this session and the lab’s owners can run this instrument’s actions."
        }
        if let waiting = gate(of: instance).waitingLabel {
            return "\(waiting) this instrument’s code to run."
        }
        return "The instrument is not running."
    }

    public func canChoose(_ action: String, of widget: String, instance: InstrumentInstance) -> Bool {
        canReachAgent(of: instance) && agentState(of: instance).isEnabled(action, of: widget)
    }

    public func canSubmitConsoleInput(of instance: InstrumentInstance) -> Bool {
        isHostingNode(instance.sessionID) && agentState(of: instance).isLive && instrumentViews.approvalWanted(byInstance: instance.id) == nil
    }

    public func canReachAgent(of instance: InstrumentInstance) -> Bool {
        let mayAsk = isHostingNode(instance.sessionID) || (isHostedRemotelyLive(instance.sessionID) && collaboration.isOwner)
        return mayAsk && agentState(of: instance).isLive && instrumentViews.approvalWanted(byInstance: instance.id) == nil
    }

    public enum InstrumentGate: Equatable, Sendable {
        case none
        case awaitingHost(name: String)
        case awaitingYou(HostCodeOrigin)

        public static let hostGateNote = "Nothing of it runs here until then."

        public var waitingLabel: String? {
            switch self {
            case .none: nil
            case .awaitingHost(let name): "Waiting for \(name) to allow"
            case .awaitingYou: "Waiting for you to allow"
            }
        }

        public var hostCardLine: String? {
            guard case .awaitingHost(let name) = self else { return nil }
            return "Waiting for \(name) to allow this instrument."
        }
    }

    public func gate(ofInstance instanceID: UUID) -> InstrumentGate {
        instrumentsBySession.values.joined().first { $0.id == instanceID }.map(gate(of:)) ?? .none
    }

    public func gate(of instance: InstrumentInstance) -> InstrumentGate {
        if let host = approvalAwaitedFromHost(of: instance) {
            return .awaitingHost(name: host.name)
        }
        if let origin = instrumentViews.approvalWanted(byInstance: instance.id) {
            return .awaitingYou(origin)
        }
        return .none
    }

    func isAwaitingHost(_ instanceID: UUID) -> Bool {
        instrumentsBySession.values.joined().first { $0.id == instanceID }.map { approvalAwaitedFromHost(of: $0) != nil } ?? false
    }

    func approvalAwaitedFromHost(of instance: InstrumentInstance) -> CollaborationSession.UserInfo? {
        guard !isHostingNode(instance.sessionID), isHostedRemotelyLive(instance.sessionID) else { return nil }
        let agent = agentState(of: instance)
        guard agent.awaitsApproval || hostCode(of: instance).map({ $0.digest != agent.allowedCode }) == true else { return nil }
        return sessions.first { $0.id == instance.sessionID }?.host
    }

    func gateRefusal(of instance: InstrumentInstance) -> String? {
        let name = descriptor(for: instance).displayName
        switch gate(of: instance) {
        case .none:
            return nil
        case .awaitingHost(let host):
            return "“\(name)” is waiting for \(host) to allow its code to run."
        case .awaitingYou:
            return "“\(name)” is waiting for you to allow its code to run; nothing of it runs until you do."
        }
    }

    func instanceAllowed(_ instanceID: UUID) {
        guard let instance = instrumentsBySession.values.joined().first(where: { $0.id == instanceID }), instance.state == .enabled,
            let node = node(forSessionID: instance.sessionID)
        else { return }
        broadcastInstrumentStatus(instanceID: instanceID, sessionID: instance.sessionID)
        guard node.instruments.first(where: { $0.id == instanceID })?.attachment != .attached else { return }
        Task { @MainActor [weak self] in
            await self?.loadInstrumentOnNode(
                instanceID: instance.id, kind: instance.kind, sourceIdentifier: instance.sourceIdentifier, configJSON: instance.configJSON,
                node: node, sessionID: instance.sessionID)
        }
    }

    public func agentState(of instance: InstrumentInstance) -> InstrumentAgentState {
        if let node = node(forSessionID: instance.sessionID) {
            let isLive = node.instruments.first(where: { $0.id == instance.id })?.attachment == .attached
            return InstrumentAgentState(
                isLive: isLive, disabledActions: disabledWidgetActions[instance.id] ?? [:],
                awaitsApproval: instrumentViews.approvalWanted(byInstance: instance.id) != nil,
                allowedCode: instrumentViews.allowedHostCode(ofInstance: instance.id))
        }
        guard isHostedRemotelyLive(instance.sessionID) else { return InstrumentAgentState() }
        return remoteInstrumentAgents[instance.id] ?? InstrumentAgentState()
    }

    public func invokeWidgetAction(instance: InstrumentInstance, widget: String, action: String) async {
        await invokeAction(instance: instance, widget: widget, action: action, item: nil)
    }

    public func invokeRowAction(instance: InstrumentInstance, widget: String, action: String, item: String) async {
        await invokeAction(instance: instance, widget: widget, action: action, item: item)
    }

    @discardableResult
    func invokeAction(
        instance: InstrumentInstance,
        widget: String,
        action: String,
        item: String?,
        chooser: ActionChooser = .person
    ) async -> OfferedFileSummary? {
        if let refusal = gateRefusal(of: instance) {
            emitEngineWarning(subsystem: "instruments", text: refusal)
            return nil
        }
        guard canReachAgent(of: instance), item != nil || agentState(of: instance).isEnabled(action, of: widget) else { return nil }
        if isHostedRemotelyLive(instance.sessionID) {
            collaboration.sendWidgetAction(
                sessionID: instance.sessionID,
                instanceID: instance.id,
                widget: widget,
                action: action,
                item: item,
                revision: widgetState(instanceID: instance.id, widget: widget).revision,
                savesFile: chooser == .person
            )
            return nil
        }
        return await runAction(
            instance: instance, widget: widget, action: action, item: item, actionID: UUID(), recipient: chooser == .person ? .person : nil)
    }

    private func runAction(
        instance: InstrumentInstance,
        widget: String,
        action: String,
        item: String?,
        actionID: UUID,
        recipient: FileRecipient?
    ) async -> OfferedFileSummary? {
        guard let node = node(forSessionID: instance.sessionID) else { return nil }
        fileRecipients[actionID] = recipient
        do {
            let outcome = try await node.invokeWidgetAction(
                instanceID: instance.id, widget: widget, action: action, item: item, actionID: actionID, savesFile: recipient != nil)
            handlerEnded(actionID: actionID, offeredFile: outcome.file != nil)
            show(outcome.show, toChooserOf: actionID, recipient: recipient, instance: instance)
            reportOutcome(of: actionID, to: recipient, offersFile: outcome.file != nil, error: outcome.error)
            if let failure = outcome.error {
                emitEngineError(subsystem: "instruments", text: "Failed to invoke widget action \(widget).\(action): \(failure)")
            }
            return outcome.file
        } catch {
            handlerEnded(actionID: actionID, offeredFile: false)
            reportOutcome(of: actionID, to: recipient, offersFile: false, error: userFacingMessage(error))
            emitEngineError(subsystem: "instruments", text: "Failed to invoke widget action \(widget).\(action): \(userFacingMessage(error))")
            return nil
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
        forgetCustomInstrument(defID)
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
        instrumentViews.reload(customInstrument: defID)
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
                    node.markInstrumentDetached(id: liveInstance.id)
                    broadcastInstrumentStatus(instanceID: liveInstance.id, sessionID: node.sessionID)
                    do {
                        try await node.disposeInstrumentOnAgent(instanceID: liveInstance.id)
                    } catch {
                        emitEngineError(
                            subsystem: "instruments",
                            text: "Failed to dispose custom instance \(liveInstance.id): \(userFacingMessage(error))"
                        )
                    }
                }
                if await skipIfIncompatible(instanceID: liveInstance.id, compatibility: def.compatibility, on: node) {
                    onSessionListChanged?(.instrumentUpdated(liveInstance))
                    continue
                }
                do {
                    guard try await loadCustomInstrument(instanceID: liveInstance.id, bundle: bundle, config: cfg, on: node) else {
                        onSessionListChanged?(.instrumentUpdated(liveInstance))
                        continue
                    }
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
        if let refusal = bundle.labRefusal, collaboration.isCollaborative {
            guard !subjectsKeptFromLab.contains(LabSubject(.definition, defID)) else { return }
            definitionsKeptForLabLimits.insert(defID)
            return keepFromLab(
                LabSubject(.definition, defID),
                because: "\(refusal). Luma offers it to the lab again on the first save that brings it within these limits")
        }
        if definitionsKeptForLabLimits.remove(defID) != nil {
            return addToLab(LabSubject(.definition, defID))
        }
        collaboration.enqueueCustomInstrumentOp(.upsert(.init(bundle: bundle)))
        instrumentsEditedSinceSnapshots.insert(defID)
    }

    private func overLabLimits(_ defID: UUID) -> Bool {
        guard let def = try? store.fetchCustomInstrumentDef(id: defID),
            let files = try? store.fetchCustomInstrumentFiles(defID: defID)
        else { return false }
        return CustomInstrumentBundle(def: def, files: files).labRefusal != nil
    }

    private func broadcastCustomInstrumentRemove(defID: UUID) {
        collaboration.enqueueCustomInstrumentOp(.remove(.init(defID: defID)))
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
                shareInsightUpdate(updated)
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
            shareInsightUpdate(updated)
            emitInsightUpdated(updated)
        }
    }

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

    public func compilerWorkspacePaths() throws -> CompilerWorkspacePaths {
        try Self.compilerWorkspacePaths(store: store, dataDirectory: dataDirectory)
    }

    private static func compilerWorkspacePaths(store: ProjectStore, dataDirectory: URL) throws -> CompilerWorkspacePaths {
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

    private func collabSessionID(forNode node: ProcessNode) -> UUID? {
        guard let session = sessions.first(where: { $0.id == node.sessionID }),
              let host = session.host,
              host.id == collaboration.localUser?.id
        else { return nil }
        return session.id
    }

    func collabSessionID(forSessionID sessionID: UUID) -> UUID? {
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

        node.onMalformedMessage = { [weak self] problem in
            self?.emitEngineError(subsystem: "instruments", text: problem)
        }

        node.onDroppedAtSource = { [weak self] dropped in
            switch dropped {
            case .events(_, let count):
                self?.eventLog.countDroppedAtSource(count)
            case .consoleEntries(let instanceID, let widget, let count):
                self?.consoleEntriesDropped[InstrumentViews.Key(instanceID: instanceID, widget: widget), default: 0] += count
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
                self?.onREPLCellSaved?(cell)
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

        node.onWidgetUpdate = { [weak self] update in
            self?.applyWidgetUpdate(update, sessionID: sessionID, origin: .local)
        }
        node.onActionStateChange = { [weak self] change in
            self?.applyActionStateChange(change, sessionID: sessionID)
        }
        node.onFileStreamTraffic = { [weak self] traffic in
            self?.handleFileStreamTraffic(traffic, sessionID: sessionID)
        }
        node.onChildTraffic = { [weak self] traffic in
            self?.handleChildTraffic(traffic)
        }
    }

    private func applyActionStateChange(_ change: InstrumentActionStateChange, sessionID: UUID) {
        switch change {
        case .reset(let instanceID):
            guard disabledWidgetActions.removeValue(forKey: instanceID) != nil else { return }
            broadcastInstrumentStatus(instanceID: instanceID, sessionID: sessionID)
        case .set(let instanceID, let widget, let action, let isEnabled):
            var disabled = disabledWidgetActions[instanceID, default: [:]][widget, default: []]
            let changed = isEnabled ? disabled.remove(action) != nil : disabled.insert(action).inserted
            guard changed else { return }
            disabledWidgetActions[instanceID, default: [:]][widget] = disabled.isEmpty ? nil : disabled
            broadcastInstrumentStatus(instanceID: instanceID, sessionID: sessionID)
        }
    }

    func widget(forInstanceID instanceID: UUID, widgetID: String) -> InstrumentWidget? {
        guard let instance = instrumentsBySession.values.flatMap({ $0 }).first(where: { $0.id == instanceID }) else {
            return nil
        }
        switch instance.kind {
        case .custom:
            guard let defID = UUID(uuidString: instance.sourceIdentifier),
                let def = customInstruments.def(withId: defID)
            else { return nil }
            return def.widget(atSlot: widgetID)
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

                case .connecting(let status, let progress):
                    self.connectionActivity.report(
                        deviceID: device.id,
                        deviceKind: device.type.description,
                        status: status,
                        fraction: progress
                    )

                case .connected:
                    self.connectionActivity.complete(deviceID: device.id)

                case .lost:
                    self.connectionActivity.complete(deviceID: device.id)
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
            try? await device.resume(pid: pid)
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
                try? await device.resume(pid: pid)
                return
            }
            try await performAttach(device: device, process: process, session: session)
        } catch {
            try? await device.resume(pid: pid)
            updateSession(id: session.id) {
                $0.lastError = error.localizedDescription
                $0.phase = .idle
            }
            return
        }

        guard self.session(id: session.id)?.phase == .attached else {
            try? await device.resume(pid: pid)
            return
        }

        if shouldAutoResumeOnCapture(session) {
            try? await device.resume(pid: pid)
        } else {
            updateSession(id: session.id) { $0.phase = .awaitingInitialResume }
        }
    }

    private func shouldAutoResumeOnCapture(_ session: ProcessSession) -> Bool {
        if case .spawn(let config) = session.kind { return config.autoResume }
        return true
    }

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

    private func hasRunningExternalMCPMission() -> Bool {
        let missions = (try? store.fetchMissions()) ?? []
        return missions.contains { $0.providerID == externalMCPProviderID && $0.status == .running }
    }

    func purgeExternalMCPMissions() {
        guard let missions = try? store.fetchMissions() else { return }
        for mission in missions where mission.providerID == externalMCPProviderID && isStartedByMe(mission) {
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

        let toolNames = missionTools.specs(in: ToolNeed.missionContext).map(\.name)
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
        if let nl = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[..<nl])
        }
        return trimmed.withoutInlineMarkdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.!?:;"))
    }

    public func cancelMission(missionID: UUID) {
        guard let mission = try? store.fetchMission(id: missionID), isStartedByMe(mission) else {
            return stopForTheLabsOwner(missionID)
        }
        stopLoopHere(missionID)
    }

    public func canStop(_ mission: Mission) -> Bool {
        mission.status.isLive && (isStartedByMe(mission) || isLabOwner)
    }

    private func stopForTheLabsOwner(_ missionID: UUID) {
        guard let mission = try? store.fetchMission(id: missionID), canStop(mission) else { return }
        guard let stopped = store.updateMission(id: missionID, { $0.status = .cancelled }) else { return }
        collaboration.enqueueMissionUpsert(stopped)
    }

    private func stopLoopHere(_ missionID: UUID) {
        missionExecutor.cancel(missionID: missionID)
        #if canImport(Network) || canImport(CSoup)
        activeMCPServersByMissionID[missionID]?.cancelPendingApprovals()
        #endif
    }

    public func appendMissionUserMessage(missionID: UUID, text: String) {
        enqueueMissionUserText(missionID: missionID, text: text)
        guard let mission = try? store.fetchMission(id: missionID), runsLoopHere(mission) else { return }
        switch mission.status {
        case .running, .awaitingApproval:
            break
        case .paused, .completed, .failed, .cancelled, .drafting:
            missionExecutor.resume(missionID: missionID)
        }
    }

    public func sendMissionUserMessageNow(missionID: UUID, text: String) {
        enqueueMissionUserText(missionID: missionID, text: text)
        guard let mission = try? store.fetchMission(id: missionID), runsLoopHere(mission) else { return }
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
        let steer = MissionSteer(missionID: missionID, author: localUser, text: trimmed)
        try? store.save(steer)
        collaboration.enqueueMissionSteer(steer)
    }

    public func pendingSteering(missionID: UUID) -> [MissionSteer] {
        (try? store.fetchMissionSteering(missionID: missionID)) ?? []
    }

    public func myPendingSteering(missionID: UUID) -> [MissionSteer] {
        pendingSteering(missionID: missionID).filter { $0.author == nil || $0.author?.id == localUserID }
    }

    private func isConsumedHere(_ steer: MissionSteer) -> Bool {
        ((try? store.fetchOutboxOps(MissionOp.self)) ?? []).contains { op in
            if case .steerConsume(let c) = op { return c.steerIDs.contains(steer.id) }
            return false
        }
    }

    private func takeUpSteering(_ missionID: UUID) {
        guard let mission = try? store.fetchMission(id: missionID), runsLoopHere(mission), !missionExecutor.isRunning(missionID: missionID),
            !pendingSteering(missionID: missionID).isEmpty
        else { return }
        let actions = (try? store.fetchMissionActions(missionID: missionID)) ?? []
        guard !actions.contains(where: { [.pending, .approved, .running].contains($0.status) }) else { return }
        missionExecutor.resume(missionID: missionID)
    }

    public func canDelete(missionID: UUID) -> Bool {
        guard let mission = try? store.fetchMission(id: missionID) else { return false }
        return isStartedByMe(mission) || isLabOwner
    }

    public func isStartedByMe(_ mission: Mission) -> Bool {
        mission.author == nil || mission.author?.id == localUserID
    }

    private var isLabOwner: Bool {
        collaboration.members.first { $0.user.id == localUserID }?.role == .owner
    }

    public func deleteMission(missionID: UUID) {
        guard canDelete(missionID: missionID) else { return }
        collaboration.forget(removedMission: missionID)
        endMissionHere(missionID, because: "this mission was deleted")
        try? store.deleteMission(id: missionID)
        collaboration.enqueueMissionRemove(missionID: missionID)
    }

    public func approveMissionAction(actionID: UUID) async {
        guard let action = try? store.fetchMissionAction(id: actionID), canApprove(action) else { return }

        #if canImport(Network) || canImport(CSoup)
        if isExecutor(of: action), let server = activeMCPServersByMissionID[action.missionID] {
            server.approve(actionID: actionID)
            return
        }
        #endif

        var approved = action
        approved.status = .approved
        approved.decidedAt = Date()
        try? store.save(approved)
        collaboration.enqueueMissionAction(approved)
        await continueMissionHere(approved.missionID)
    }

    public func canApprove(_ action: MissionAction) -> Bool {
        action.status == .pending && isExecutor(of: action) && hold(on: action) == nil
    }

    public func isExecutor(of action: MissionAction) -> Bool {
        let executor = executor(of: action)
        return executor == nil || executor?.id == localUserID
    }

    public func executor(of action: MissionAction) -> Author? {
        action.executor
    }

    public func hold(on action: MissionAction) -> ObjectChatCallHold? {
        guard action.status == .pending || action.status == .approved else { return nil }
        let executor = executor(of: action)
        guard let sessionID = action.sessionID, needsSession(action) else {
            return isOnline(executor) ? nil : .executorOffline
        }
        return hold(onCallExecutedBy: executor, in: sessionID)
    }

    public func isWaitingForStarter(_ mission: Mission) -> Bool {
        mission.status.isLive && !isStartedByMe(mission) && !isOnline(mission.author)
    }

    func hold(onCallExecutedBy executor: Author?, in sessionID: UUID) -> ObjectChatCallHold? {
        let session = sessions.first { $0.id == sessionID }
        guard isOnline(executor) else { return .executorOffline }
        guard session?.host?.id == executor?.id else {
            return .executorNoLongerHosts(currentHost: session?.host.map(Self.author))
        }
        guard session?.phase == .attached else { return .sessionDetached }
        return nil
    }

    func assignExecutor(to action: inout MissionAction, askedBy asker: Author?) {
        let asker = asker ?? localUser
        if let sessionID = action.sessionID, needsSession(action) {
            action.executor = sessions.first { $0.id == sessionID }?.host.map(Self.author) ?? asker
        } else {
            action.executor = asker
        }
        guard !isExecutor(of: action) else { return }
        action.status = .pending
        action.decidedAt = nil
    }

    private func continueMissionHere(_ missionID: UUID) async {
        guard let mission = try? store.fetchMission(id: missionID) else { return }
        let actions = (try? store.fetchMissionActions(missionID: missionID)) ?? []
        for action in actions where action.status == .approved && isExecutor(of: action) && hold(on: action) == nil {
            #if canImport(Network) || canImport(CSoup)
            if let server = activeMCPServersByMissionID[missionID] {
                server.approve(actionID: action.id)
                continue
            }
            #endif
            await missionExecutor.runActionByID(action.id, mission: mission)
        }
        resumeMissionHere(missionID)
    }

    private func resumeMissionHere(_ missionID: UUID) {
        guard let mission = try? store.fetchMission(id: missionID), runsLoopHere(mission), mission.status == .awaitingApproval else {
            return
        }
        let actions = (try? store.fetchMissionActions(missionID: missionID)) ?? []
        guard !actions.contains(where: { [.pending, .approved, .running].contains($0.status) }) else { return }
        missionExecutor.resume(missionID: missionID)
    }

    private func runsLoopHere(_ mission: Mission) -> Bool {
        isStartedByMe(mission) && mission.providerID != externalMCPProviderID
    }

    private func needsSession(_ action: MissionAction) -> Bool {
        missionTools.spec(named: action.toolName)?.needs.contains(.session) == true
    }

    private func isOnline(_ author: Author?) -> Bool {
        author == nil || author?.id == localUserID || collaboration.members.first { $0.user.id == author?.id }?.presence == .online
    }

    private var localUser: Author? {
        (collaboration.localUser ?? gitHubAuth.currentUser).map(Self.author)
    }

    private static func author(_ user: CollaborationSession.UserInfo) -> Author {
        Author(id: user.id, name: user.name, avatarURL: user.avatarURL?.absoluteString ?? "")
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
        resumeMissionHere(action.missionID)
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
        resumeMissionHere(action.missionID)
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

    private func endMissionRemovedInLab(_ missionID: UUID) {
        collaboration.forget(removedMission: missionID)
        let removed = try? store.fetchMission(id: missionID)
        for steer in myPendingSteering(missionID: missionID) {
            emitEngineWarning(
                subsystem: "missions",
                text: "Your message to the mission “\(removed?.title ?? removed?.goalText ?? "")” was not delivered because "
                    + "the mission was deleted in the lab: \(steer.text)")
        }
        let wasRunningHere = endMissionHere(missionID, because: "this mission was deleted in the lab")
        try? store.deleteMission(id: missionID)
        guard let removed, wasRunningHere else { return }
        let title = removed.title ?? removed.goalText
        report(
            .missionDeletedInLab(missionID: missionID, title: title), in: "missions",
            reason: "The mission “\(title)” was deleted in the lab, so it was stopped here.")
    }

    @discardableResult
    private func endMissionHere(_ missionID: UUID, because reason: String) -> Bool {
        var wasRunningHere = missionExecutor.isRunning(missionID: missionID)
        var turnEndsOnItsOwn = false
        #if canImport(Network) || canImport(CSoup)
        if let server = activeMCPServersByMissionID[missionID] {
            wasRunningHere = true
            turnEndsOnItsOwn = server.isWaitingForApproval
            server.end(because: reason)
        }
        #endif
        if !turnEndsOnItsOwn {
            missionExecutor.cancel(missionID: missionID)
        }
        return wasRunningHere
    }

    private func keepCopy(of subject: LabSubject, turnedAwayBecause reason: String) {
        let name = name(of: subject)
        let saying = { (what: String) in
            "The lab turned away your change to “\(name)”: \(reason). The lab's “\(name)” stays as it was, and your version is kept here as "
                + "\(what) the lab does not have. Add it to the lab again, or delete it."
        }
        switch subject.family {
        case .definition:
            keepCopy(ofCustomInstrument: subject.id) { _ in saying("an instrument") }
        case .pattern:
            keepCopy(ofPattern: subject.id) { _ in saying("a pattern") }
        case .entry:
            keepCopy(ofEntry: subject.id, saying: saying("a notebook entry"))
        default:
            break
        }
    }

    private func keepCopy(ofCustomInstrument defID: UUID, saying reason: (String) -> String) {
        guard let def = try? store.fetchCustomInstrumentDef(id: defID),
            let files = try? store.fetchCustomInstrumentFiles(defID: defID)
        else { return }
        var copy = def
        copy.id = UUID()
        let copiedFiles = files.map { file -> CustomInstrumentFile in
            var copied = file
            copied.defID = copy.id
            return copied
        }
        try? store.withholdFromLab(LabSubject(.definition, copy.id))
        try? store.save(copy)
        try? store.replaceCustomInstrumentFiles(defID: copy.id, files: copiedFiles)
        if let link = instrumentFolderLinks[defID] {
            LumaAppState.shared.setInstrumentFolderLink(link, forDefID: copy.id)
            unlinkInstrumentFolder(defID: defID)
        }
        subjectsKeptFromLab.insert(LabSubject(.definition, copy.id))
        report(.copyKeptFromLab(LabSubject(.definition, copy.id), name: def.name), in: "collaboration", reason: reason(def.name))
    }

    private func keepCopy(ofPattern sourceID: UUID, saying reason: (String) -> String) {
        guard var copy = try? store.fetchPatternSource(id: sourceID) else { return }
        copy.id = UUID()
        try? store.withholdFromLab(LabSubject(.pattern, copy.id))
        patterns.adopt(copy)
        subjectsKeptFromLab.insert(LabSubject(.pattern, copy.id))
        report(.copyKeptFromLab(LabSubject(.pattern, copy.id), name: copy.name), in: "collaboration", reason: reason(copy.name))
    }

    private func keepCopy(ofEntry entryID: UUID, saying reason: String) {
        guard let original = notebookEntries.first(where: { $0.id == entryID }) else { return }
        var copy = original
        copy.id = UUID()
        try? store.withholdFromLab(LabSubject(.entry, copy.id))
        addNotebookEntry(copy, after: original)
        subjectsKeptFromLab.insert(LabSubject(.entry, copy.id))
        report(.copyKeptFromLab(LabSubject(.entry, copy.id), name: copy.title), in: "collaboration", reason: reason)
    }

    private func keepFromLab(_ subject: LabSubject, because reason: String) {
        try? store.withholdFromLab(subject)
        subjectsKeptFromLab.insert(subject)
        let name = name(of: subject)
        let concern: LabProblem.Concern = Self.familiesCopiedWhenKept.contains(subject.family)
            ? .copyKeptFromLab(subject, name: name) : .keptFromLab(subject, name: name)
        report(concern, in: "collaboration", reason: "“\(name)” is kept here, and the lab does not have it: \(reason).")
    }

    private static let familiesCopiedWhenKept: Set<LabSubject.Family> = [.definition, .pattern, .entry, .mission]

    private func name(of subject: LabSubject) -> String {
        switch subject.family {
        case .definition: (try? store.fetchCustomInstrumentDef(id: subject.id))?.name ?? "The instrument"
        case .pattern: (try? store.fetchPatternSource(id: subject.id))?.name ?? "The pattern"
        case .entry: notebookEntries.first { $0.id == subject.id }?.title ?? "The notebook entry"
        case .mission: (try? store.fetchMission(id: subject.id)).flatMap { $0.title ?? $0.goalText } ?? "The mission"
        case .instrument: instrumentsBySession.values.joined().first { $0.id == subject.id }.map { descriptor(for: $0).displayName } ?? "The instrument"
        case .session: sessions.first { $0.id == subject.id }?.processName ?? "The session"
        case .insight: insightsBySession.values.joined().first { $0.id == subject.id }?.userTitle ?? "The insight"
        case .trace: tracesBySession.values.joined().first { $0.id == subject.id }?.displayName ?? "The trace"
        case .replCell: (try? store.fetchREPLCell(id: subject.id)).map { String($0.code.prefix(40)) } ?? "The REPL cell"
        case .objectChat, .objectChatMessage: "The chat"
        }
    }

    public func dismiss(_ problem: LabProblem) {
        if case .objectChat(let chatProblem) = problem.concern {
            objectChats.dismiss(chatProblem.id)
        } else {
            problemsOfThisEngine.removeAll { $0.id == problem.id }
        }
    }

    private func report(_ concern: LabProblem.Concern, in subsystem: String, reason: String) {
        problemsOfThisEngine.append(LabProblem(concern, reason: reason))
        emitEngineWarning(subsystem: subsystem, text: reason)
    }

    public func canShow(_ subject: LabSubject) -> Bool {
        switch subject.family {
        case .definition, .pattern, .entry, .mission: true
        case .session, .instrument, .insight, .trace: sessionID(holding: subject) != nil
        case .replCell, .objectChat, .objectChatMessage: false
        }
    }

    public func sessionID(holding subject: LabSubject) -> UUID? {
        switch subject.family {
        case .session: sessions.first { $0.id == subject.id }?.id
        case .instrument: instrumentsBySession.first { $0.value.contains { $0.id == subject.id } }?.key
        case .insight: insightsBySession.first { $0.value.contains { $0.id == subject.id } }?.key
        case .trace: tracesBySession.first { $0.value.contains { $0.id == subject.id } }?.key
        default: nil
        }
    }

    public func addToLab(_ subject: LabSubject) {
        try? store.releaseToLab(subject)
        subjectsKeptFromLab.remove(subject)
        problemsOfThisEngine.removeAll {
            if case .copyKeptFromLab(subject, _) = $0.concern { return true }
            return false
        }
        switch subject.family {
        case .definition:
            broadcastCustomInstrumentUpsert(defID: subject.id)
            announceInstances(ofDefinition: subject.id)
        case .pattern:
            guard let record = try? store.fetchPatternSource(id: subject.id) else { return }
            collaboration.enqueuePatternSourceUpsert(record)
        case .entry:
            guard let entry = notebookEntries.first(where: { $0.id == subject.id }) else { return }
            collaboration.enqueueAdd(entry)
        default:
            break
        }
    }

    private func announceInstances(ofDefinition defID: UUID) {
        let known = knownToLab(.instrument)
        for (sessionID, instances) in instrumentsBySession where localUserHosts(sessionID) && collabSessionID(forSessionID: sessionID) != nil {
            for instance in instances where instance.kind == .custom && instance.sourceIdentifier == defID.uuidString && !known.contains(instance.id) {
                let subject = LabSubject(.instrument, instance.id)
                try? store.releaseToLab(subject)
                subjectsKeptFromLab.remove(subject)
                problemsOfThisEngine.removeAll {
                    if case .keptFromLab(subject, _) = $0.concern { return true }
                    return false
                }
                announce(instance, sessionID: sessionID)
            }
        }
    }

    private func applyRemoteMissionSnapshot(_ snapshot: MissionSnapshot) {
        let serverMissionIDs = Set(snapshot.missions.map(\.id))
        let localMissions = (try? store.fetchMissions()) ?? []
        let pending = subjectsOfPendingOps(MissionOp.self)
        let known = knownToLab(.mission)
        for absent in localMissions where !serverMissionIDs.contains(absent.id) && !pending.contains(absent.id) {
            if known.contains(absent.id) {
                endMissionRemovedInLab(absent.id)
            } else {
                collaboration.enqueueMission(absent)
            }
        }
        let queued = (try? store.fetchOutboxOps(MissionOp.self)) ?? []
        let queuedRows = Set(queued.compactMap(\.rowID))
        let queuedMissions = Set(queued.compactMap { op -> UUID? in
            if case .missionUpsert(let u) = op { return u.mission.id }
            return nil
        })
        for mission in snapshot.missions where !queuedMissions.contains(mission.id) { try? store.save(mission) }
        for turn in snapshot.turns where !queuedRows.contains(turn.id) { try? store.save(turn) }
        for action in snapshot.actions where !queuedRows.contains(action.id) && !isBehindWhatIsHeld(action) { try? store.save(action) }
        for finding in snapshot.findings where !queuedRows.contains(finding.id) { try? store.save(finding) }
        for evidence in snapshot.evidence where !queuedRows.contains(evidence.id) { try? store.save(evidence) }
        adoptSteering(of: snapshot, keeping: queued)
        dropRowsTheLabRefused(in: snapshot)
        Task {
            for mission in snapshot.missions {
                await continueMissionHere(mission.id)
                takeUpSteering(mission.id)
            }
        }
    }

    private func adoptSteering(of snapshot: MissionSnapshot, keeping queued: [MissionOp]) {
        let queuedSteers = Set(queued.compactMap { op -> UUID? in
            if case .steerAppend(let a) = op { return a.steer.id }
            return nil
        })
        let consumed = Set(queued.flatMap { op -> [UUID] in
            if case .steerConsume(let c) = op { return c.steerIDs }
            return []
        })
        let held = Set(snapshot.steering.map(\.id))
        for mission in snapshot.missions {
            let gone = pendingSteering(missionID: mission.id).filter { !held.contains($0.id) && !queuedSteers.contains($0.id) }
            try? store.deleteMissionSteering(ids: gone.map(\.id))
        }
        for steer in snapshot.steering where !consumed.contains(steer.id) {
            try? store.save(steer)
        }
    }

    private func dropRowsTheLabRefused(in snapshot: MissionSnapshot) {
        let queued = Set(((try? store.fetchOutboxOps(MissionOp.self)) ?? []).compactMap(\.rowID))
        let held = Set(snapshot.turns.map(\.id) + snapshot.actions.map(\.id) + snapshot.findings.map(\.id) + snapshot.evidence.map(\.id))
        let isRefused = { (id: UUID) in !held.contains(id) && !queued.contains(id) }
        for mission in snapshot.missions {
            let turns = ((try? store.fetchMissionTurns(missionID: mission.id)) ?? []).filter { isRefused($0.id) }
            let actions = ((try? store.fetchMissionActions(missionID: mission.id)) ?? []).filter { isRefused($0.id) }
            let findings = (try? store.fetchMissionFindings(missionID: mission.id)) ?? []
            let evidence = findings.flatMap { (try? store.fetchMissionEvidence(findingID: $0.id)) ?? [] }.filter { isRefused($0.id) }
            try? store.deleteMissionRows(
                turns: turns.map(\.id), actions: actions.map(\.id), findings: findings.map(\.id).filter(isRefused),
                evidence: evidence.map(\.id))
            let typed = turns.filter { $0.role == .user }.flatMap(Self.typedText(of:))
            if !typed.isEmpty {
                enqueueMissionUserText(missionID: mission.id, text: typed.joined(separator: "\n\n"))
            }
        }
    }

    private static func typedText(of turn: MissionTurn) -> [String] {
        let blocks = (try? JSONDecoder().decode([LLMContentBlock].self, from: Data(turn.contentJSON.utf8))) ?? []
        return blocks.compactMap { block in
            if case .text(let text) = block.content { return text }
            return nil
        }
    }

    private static func asSent(_ held: NotebookEntry?, merging entry: NotebookEntry) -> NotebookEntry? {
        guard let held, var sent = NotebookEntry.fromJSON(held.toJSON(), binaryData: held.binaryData.map { [UInt8]($0) }) else { return nil }
        sent.pharoResultFuel = entry.pharoResultFuel
        sent.sessionID = entry.sessionID
        return sent
    }

    private static func asSent<Row: Codable>(_ row: Row?) -> Row? {
        row.flatMap { decodeRow(encodeRow($0)) }
    }

    private func applyRemoteMissionOp(_ op: MissionOp) {
        switch op {
        case .missionUpsert(let u):
            let held = (try? store.fetchMission(id: u.mission.id)).flatMap { $0 }
            guard held.flatMap({ $0.toWireJSON() }).flatMap(Mission.fromWireJSON) != u.mission else { return }
            try? store.save(u.mission)
            if u.mission.status == .cancelled, held?.status.isLive == true, isStartedByMe(u.mission) {
                stopLoopHere(u.mission.id)
                let title = u.mission.title ?? u.mission.goalText
                report(
                    .missionStoppedByOwner(missionID: u.mission.id, title: title), in: "missions",
                    reason: "The lab's owner stopped the mission “\(title)”, so it was stopped here.")
            }
        case .missionRemove(let r):
            endMissionRemovedInLab(r.missionID)
        case .turnAppend(let a):
            try? store.save(a.turn)
        case .actionUpsert(let u):
            guard !isBehindWhatIsHeld(u.action) else { return }
            let local = (try? store.fetchMissionAction(id: u.action.id)).flatMap { $0 }
            guard local.flatMap({ $0.toWireJSON() }).flatMap(MissionAction.fromWireJSON) != u.action else { return }
            try? store.save(u.action)
            #if canImport(Network) || canImport(CSoup)
            if isTerminal(u.action.status) {
                activeMCPServersByMissionID[u.action.missionID]?.settle(u.action)
            }
            #endif
            Task { await continueMissionHere(u.action.missionID) }
        case .findingUpsert(let u):
            try? store.save(u.finding)
        case .findingRemove(let r):
            try? store.deleteMissionFinding(id: r.findingID)
        case .evidenceAdd(let a):
            try? store.save(a.evidence)
        case .steerAppend(let a):
            guard !isConsumedHere(a.steer) else { return }
            try? store.save(a.steer)
            takeUpSteering(a.steer.missionID)
        case .steerConsume(let c):
            try? store.deleteMissionSteering(ids: c.steerIDs)
        }
    }
}

public struct TracerHookCompileFailures: Swift.Error {
    public let hookErrors: [UUID: any Swift.Error]
}

@MainActor
final class SessionDisassemblyEnvironment: ModuleIntrospector, MemoryReader, MemoryWriter, PageKeying {
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

    func enumerateModuleFunctions(name: String) async throws -> [ModuleFunction] {
        guard let node = engine.node(forSessionID: sessionID) else {
            throw DisassemblyError.detached
        }
        return try await node.enumerateModuleFunctions(name: name)
    }

    func read(at address: UInt64, count: Int) async throws -> [UInt8] {
        guard let node = engine.node(forSessionID: sessionID) else {
            throw engine.isHostedRemotelyLive(sessionID) ? DisassemblyError.notShared(address: address) : DisassemblyError.detached
        }
        return try await node.readRemoteMemory(at: address, count: count)
    }

    func write(_ bytes: [UInt8], at address: UInt64) async throws {
        guard let node = engine.node(forSessionID: sessionID) else {
            throw DisassemblyError.detached
        }
        try await node.writeRemoteMemory(at: address, bytes: bytes)
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
            guard let mappedRanges = try? engine.store.fetchModuleMappedRanges(sessionID: sessionID, modulePath: module.path) else { continue }
            for range in mappedRanges {
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
