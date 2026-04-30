import Foundation
import Frida
import Observation

@Observable
@MainActor
public final class Engine {
    public let deviceManager = DeviceManager()
    public let store: ProjectStore
    public let compilerWorkspace: CompilerWorkspace

    public private(set) var processNodes: [ProcessNode] = []
    public private(set) var descriptors: [InstrumentDescriptor] = []
    private var descriptorsByID: [String: InstrumentDescriptor] = [:]

    private let _events = AsyncEventSource<RuntimeEvent>()
    public var events: AsyncStream<RuntimeEvent> { _events.makeStream() }

    public let eventLog = EventLog()

    private var deviceEventTasks: [String: Task<Void, Never>] = [:]
    private var eventLogTask: Task<Void, Never>?

    public let hookPacks: HookPackLibrary

    @ObservationIgnored private var disassemblers: [UUID: Disassembler] = [:]

    public let collaboration: CollaborationSession
    public let gitHubAuth: GitHubAuth
    public let dataDirectory: URL

    public private(set) var addressAnnotations: [UUID: [UInt64: AddressAnnotation]] = [:]
    public private(set) var tracerInstanceIDBySession: [UUID: UUID] = [:]
    public private(set) var sessions: [ProcessSession] = []
    public private(set) var driverBySession: [UUID: CollaborationSession.UserInfo] = [:]
    public private(set) var notebookEntries: [NotebookEntry] = []
    public private(set) var instrumentsBySession: [UUID: [InstrumentInstance]] = [:]
    public private(set) var insightsBySession: [UUID: [AddressInsight]] = [:]
    public private(set) var capturesBySession: [UUID: [ITraceCaptureRecord]] = [:]
    public private(set) var installedPackages: [InstalledPackage] = []
    public private(set) var editorFSSnapshot: EditorFSSnapshot?
    @ObservationIgnored public var editorFSSnapshotDirty: Bool = true
    @ObservationIgnored private var editorFSSnapshotVersion: Int = 0

    private var addressActionProviders: [AddressActionProvider] = []
    @ObservationIgnored public var onSessionListChanged: (@MainActor (SessionListChange) -> Void)?
    @ObservationIgnored public var onREPLCellAdded: (@MainActor (REPLCell) -> Void)?
    @ObservationIgnored public var onNotebookChanged: (@MainActor (NotebookChange) -> Void)?
    @ObservationIgnored public var onInstalledPackagesChanged: (@MainActor ([InstalledPackage]) -> Void)?
    @ObservationIgnored private var sessionsObservation: StoreObservation?
    @ObservationIgnored private var notebookObservation: StoreObservation?
    @ObservationIgnored private var instrumentsObservation: StoreObservation?
    @ObservationIgnored private var insightsObservation: StoreObservation?
    @ObservationIgnored private var capturesObservation: StoreObservation?
    @ObservationIgnored private var packagesObservation: StoreObservation?

    public init(
        store: ProjectStore,
        dataDirectory: URL,
        tokenStore: TokenStore? = nil,
        gitHubAuth: GitHubAuth? = nil
    ) {
        self.store = store
        self.dataDirectory = dataDirectory
        self.compilerWorkspace = CompilerWorkspace(store: store)
        let hookPacksDir = dataDirectory.appendingPathComponent("HookPacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hookPacksDir, withIntermediateDirectories: true)
        self.hookPacks = HookPackLibrary(directory: hookPacksDir)
        self.collaboration = CollaborationSession(
            deviceManager: deviceManager,
            store: store,
            portalAddress: BackendConfig.portalAddress,
            portalCertificate: BackendConfig.certificate
        )

        if let gitHubAuth {
            self.gitHubAuth = gitHubAuth
        } else {
            self.gitHubAuth = GitHubAuth(
                tokenStore: tokenStore ?? defaultTokenStore(dataDirectory: dataDirectory)
            )
        }

        registerDescriptor(Self.tracerDescriptor)
        for desc in hookPacks.descriptors() {
            registerDescriptor(desc)
        }
        bindCollaborationCallbacks()

        registerAddressActionProvider { [weak self] sessionID, address in
            self?.tracerAddressActions(sessionID: sessionID, address: address) ?? []
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
                }
            }
        }

        eventLogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self._events.makeStream() {
                self.eventLog.append(event)
            }
        }
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

        collaboration.onSessionModulesUpdated = { [weak self] sessionID, modules in
            self?.applyRemoteSessionModules(sessionID: sessionID, modules: modules)
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

        collaboration.onSessionDriverChanged = { [weak self] sessionID, driver in
            self?.applyRemoteSessionDriverChange(sessionID: sessionID, driver: driver)
        }

        collaboration.onSessionReplCellAdded = { [weak self] sessionID, cell in
            self?.applyRemoteSessionReplCell(sessionID: sessionID, cell: cell)
        }

        collaboration.onSessionReplEvalRequested = { [weak self] sessionID, code, cellID in
            self?.handleRemoteReplEvalRequest(sessionID: sessionID, code: code, cellID: cellID)
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

        collaboration.onSessionInsightRemoved = { [weak self] sessionID, insightID in
            self?.applyRemoteSessionInsightRemoved(sessionID: sessionID, insightID: insightID)
        }

        collaboration.onSessionCaptureAdded = { [weak self] sessionID, capture in
            self?.applyRemoteSessionCaptureAdded(sessionID: sessionID, capture: capture)
        }

        collaboration.onSessionCaptureRemoved = { [weak self] sessionID, captureID in
            self?.applyRemoteSessionCaptureRemoved(sessionID: sessionID, captureID: captureID)
        }

        collaboration.onSessionEventReceived = { [weak self] sessionID, event in
            self?.applyRemoteSessionEvent(sessionID: sessionID, event: event)
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
        if localUserHosts(sessionID) { return }
        var stamped = event
        stamped.sessionID = sessionID
        _events.yield(stamped)
    }

    private func applyRemoteSessionCaptureAdded(sessionID: UUID, capture: ITraceCaptureRecord) {
        if localUserHosts(sessionID) { return }
        var stored = capture
        stored.sessionID = sessionID
        try? store.save(stored)
        onSessionListChanged?(.captureAdded(stored))
    }

    private func applyRemoteSessionCaptureRemoved(sessionID: UUID, captureID: UUID) {
        if localUserHosts(sessionID) { return }
        try? store.deleteCapture(id: captureID)
        onSessionListChanged?(.captureRemoved(id: captureID, sessionID: sessionID))
    }

    private func applyRemoteSessionInsightAdded(sessionID: UUID, insight: AddressInsight) {
        if localUserHosts(sessionID) { return }
        var stored = insight
        stored.sessionID = sessionID
        try? store.save(stored)
        onSessionListChanged?(.insightAdded(stored))
    }

    private func applyRemoteSessionInsightRemoved(sessionID: UUID, insightID: UUID) {
        if localUserHosts(sessionID) { return }
        try? store.deleteInsight(id: insightID)
        onSessionListChanged?(.insightRemoved(id: insightID, sessionID: sessionID))
    }

    private func applyRemoteSessionInstrumentAdded(sessionID: UUID, instance: InstrumentInstance) {
        if localUserHosts(sessionID) { return }
        var stored = instance
        stored.sessionID = sessionID
        try? store.save(stored)
        onSessionListChanged?(.instrumentAdded(stored))
    }

    private func applyRemoteSessionInstrumentUpdated(sessionID: UUID, instance: InstrumentInstance) {
        if localUserHosts(sessionID) { return }
        var stored = instance
        stored.sessionID = sessionID
        try? store.save(stored)
        onSessionListChanged?(.instrumentUpdated(stored))
    }

    private func applyRemoteSessionInstrumentRemoved(sessionID: UUID, instanceID: UUID) {
        if localUserHosts(sessionID) { return }
        try? store.deleteInstrument(id: instanceID)
        onSessionListChanged?(.instrumentRemoved(id: instanceID, sessionID: sessionID))
    }

    public func localUserHosts(_ sessionID: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
        return localUserHosts(session)
    }

    public func localUserHosts(_ session: ProcessSession) -> Bool {
        guard let host = session.host else { return true }
        return host.id == collaboration.localUser?.id
    }

    public var canHostNewSessions: Bool {
        !collaboration.isCollaborative || collaboration.isOwner
    }

    private func broadcastInstrumentUpdate(_ instance: InstrumentInstance) {
        guard localUserHosts(instance.sessionID) else { return }
        collaboration.enqueueUpdateInstrument(sessionID: instance.sessionID, instance: instance)
    }

    private func handleRemoteReplEvalRequest(sessionID: UUID, code: String, cellID: UUID) {
        guard let node = processNodes.first(where: { $0.sessionID == sessionID }) else { return }
        Task { @MainActor in
            await node.evalInREPL(code, cellID: cellID)
        }
    }

    private func handleRemoteInstrumentSetStateRequest(
        sessionID: UUID,
        instanceID: UUID,
        state: InstrumentState
    ) {
        guard localUserHosts(sessionID),
            let instance = try? store.fetchInstrument(id: instanceID)
        else { return }
        Task { @MainActor in
            await setInstrumentState(instance, state: state)
        }
    }

    private func handleRemoteInstrumentRemoveRequest(sessionID: UUID, instanceID: UUID) {
        guard localUserHosts(sessionID),
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
        guard localUserHosts(sessionID) else { return }
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
        guard localUserHosts(sessionID),
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
        announceMissingLocalSessions(serverKnown: serverKnown)
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
        }
    }

    private func adoptRemoteSession(_ session: CollaborationSession.Session) {
        driverBySession[session.id] = session.driver

        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            var record = sessions[idx]
            record.host = session.host
            record.phase = session.phase.toProcessSessionPhase
            record.processName = session.processName
            record.deviceID = session.deviceID
            record.deviceName = session.deviceName
            record.lastKnownPID = session.pid
            if !session.modules.isEmpty {
                record.lastKnownModules = session.modules.map {
                    ProcessSession.PersistedModule(name: $0.name, base: $0.base, size: $0.size)
                }
            }
            saveSession(record)
        } else {
            var record = ProcessSession(
                id: session.id,
                kind: .attach,
                host: session.host,
                deviceID: session.deviceID,
                deviceName: session.deviceName,
                processName: session.processName,
                lastKnownPID: session.pid
            )
            record.phase = session.phase.toProcessSessionPhase
            record.lastKnownModules = session.modules.map {
                ProcessSession.PersistedModule(name: $0.name, base: $0.base, size: $0.size)
            }
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

        for capture in session.captures {
            var stored = capture
            stored.sessionID = session.id
            try? store.save(stored)
            onSessionListChanged?(.captureAdded(stored))
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

    private func applyRemoteSessionModules(sessionID: UUID, modules: [ProcessModule]) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var updated = sessions[idx]
        updated.lastKnownModules = modules.map {
            ProcessSession.PersistedModule(name: $0.name, base: $0.base, size: $0.size)
        }
        saveSession(updated)
    }

    private func applyRemoteSessionDriverChange(
        sessionID: UUID,
        driver: CollaborationSession.UserInfo
    ) {
        driverBySession[sessionID] = driver
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        onSessionListChanged?(.sessionUpdated(session))
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
        updated.lastKnownModules = nil
        saveSession(updated)
    }

    private func applyRemoteSessionReplCell(sessionID: UUID, cell: REPLCell) {
        if localUserHosts(sessionID) { return }
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
        driverBySession.removeValue(forKey: sessionID)
        onSessionListChanged?(.sessionRemoved(sessionID))
    }

    public func start() async {
        if let loaded = try? store.fetchSessions() {
            for var session in loaded where session.phase != .idle {
                session.phase = .idle
                try? store.save(session)
            }
        }
        notebookEntries = (try? store.fetchNotebookEntries()) ?? []
        sessions = (try? store.fetchSessions()) ?? []

        sessionsObservation = store.observeSessions { [weak self] sessions in
            Task { @MainActor in
                self?.sessions = sessions
            }
        }
        notebookObservation = store.observeNotebookEntries { [weak self] entries in
            Task { @MainActor in self?.notebookEntries = entries }
        }
        instrumentsObservation = store.observeAllInstruments { [weak self] grouped in
            Task { @MainActor in self?.instrumentsBySession = grouped }
        }
        insightsObservation = store.observeAllInsights { [weak self] grouped in
            Task { @MainActor in self?.insightsBySession = grouped }
        }
        capturesObservation = store.observeAllITraceCaptures { [weak self] grouped in
            Task { @MainActor in self?.capturesBySession = grouped }
        }
        packagesObservation = store.observeInstalledPackages { [weak self] packages in
            Task { @MainActor in
                self?.installedPackages = packages
                self?.onInstalledPackagesChanged?(packages)
            }
        }

        await loadRemoteDevices()
        if let labID = CollaborationJoinQueue.shared.consumeNext() {
            startCollaboration(joiningLab: labID)
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
                print("[Engine] failed to add remote device \(config.address): \(String(describing: error)))")
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
            let snapshot = try Self.buildEditorFSSnapshot(paths: paths)
            editorFSSnapshotVersion += 1
            editorFSSnapshot = snapshot.withVersion(editorFSSnapshotVersion)
            editorFSSnapshotDirty = false
        } catch {
            print("Failed to rebuild editor FS snapshot: \(error)")
        }
    }

    private static func buildEditorFSSnapshot(paths: CompilerWorkspacePaths) throws -> EditorFSSnapshot {
        let fm = FileManager.default
        let root = paths.root
        let nodeModules = paths.nodeModules

        guard fm.fileExists(atPath: nodeModules.path) else {
            return EditorFSSnapshot(version: 0, files: [])
        }

        let workspaceRootURI = "file:///workspace/"

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

        return EditorFSSnapshot(version: 0, files: out)
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
        editorFSSnapshotDirty = true
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
            print("[Engine] failed to load packages: \(String(describing: error)))")
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
            node.loadedPackageNames.insert(entry["name"] as! String)
        } catch {
            let diagnostics = compilerWorkspace.lastCompilerDiagnostics.joined(separator: "\n")
            print("[Engine] failed to load package \(package.name): \(String(describing: error))")
            if !diagnostics.isEmpty {
                print("[Engine] compiler diagnostics:\n\(diagnostics)")
            }
        }
    }

    private func propagatePackage(_ package: InstalledPackage) async {
        editorFSSnapshotDirty = true
        for node in processNodes {
            await loadPackage(package, on: node)
        }
    }

    // MARK: - Descriptor Registry

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

    public func descriptor(for instance: InstrumentInstance) -> InstrumentDescriptor? {
        switch instance.kind {
        case .tracer:
            return descriptorsByID["tracer"]
        case .hookPack:
            return descriptorsByID["hook-pack:\(instance.sourceIdentifier)"]
        case .codeShare:
            return descriptorsByID["codeshare:\(instance.sourceIdentifier)"]
                ?? makeCodeShareDescriptor(for: instance)
        }
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
            icon: .system("cloud"),
            makeInitialConfigJSON: { try! JSONEncoder().encode(cfg) }
        )
    }

    public static let tracerDescriptor = InstrumentDescriptor(
        id: "tracer",
        kind: .tracer,
        sourceIdentifier: "builtin.tracer",
        displayName: "Tracer",
        icon: .system("arrow.triangle.branch"),
        makeInitialConfigJSON: {
            try! JSONEncoder().encode(TracerConfig())
        },
        summarizeEvent: { event in
            String(describing: event.payload)
        }
    )

    // MARK: - Session Orchestration

    public func spawnAndAttach(
        device: Device,
        session: ProcessSession
    ) async {
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
                s.lastError = "Spawned pid \(pid) not found"
                s.phase = .idle
                saveSession(s)
                return
            }

            s.deviceName = device.name
            saveSession(s)

            await performAttach(
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
        } catch {
            s.lastError = error.localizedDescription
            s.phase = .idle
            saveSession(s)
        }
    }

    public func attach(
        device: Device,
        process: ProcessDetails,
        session: ProcessSession
    ) async {
        await performAttach(
            device: device,
            process: process,
            session: session
        )
    }

    private func performAttach(
        device: Device,
        process: ProcessDetails,
        session: ProcessSession
    ) async {
        var s = session
        s.lastKnownPID = process.pid
        s.detachReason = .applicationRequested
        s.lastError = nil
        s.phase = .attaching
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
                drainAgentSource: LumaAgent.drainSource
            )

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

            subscribeToNodeStreams(node)

            processNodes.append(node)

            announceLocalSession(node)

            await node.waitForScriptEventsSubscription()
            await Task.yield()

            try await script.load()

            if let info = await node.fetchProcessInfo() {
                updateSession(id: s.id) {
                    $0.processInfo = ProcessSession.ProcessInfo(
                        platform: info.platform,
                        arch: info.arch,
                        pointerSize: info.pointerSize
                    )
                }
            }

            await node.setupITraceDraining()

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
            print("[Engine] attach failed: \(String(describing: error)))")
            updateSession(id: s.id) {
                $0.lastError = error.localizedDescription
                $0.phase = .idle
            }
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
            addressAnnotations[sid] = nil
            tracerInstanceIDBySession[sid] = nil
            disassemblers[sid] = nil
            updateSession(id: sid) { $0.phase = .idle }
        }
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

    public func driver(forSessionID id: UUID) -> CollaborationSession.UserInfo? {
        driverBySession[id]
    }

    public func localUserIsDriver(ofSessionID id: UUID) -> Bool {
        guard let driver = driverBySession[id], let localID = collaboration.localUser?.id else {
            return true
        }
        return driver.id == localID
    }

    public func disassembler(forSessionID sessionID: UUID) -> Disassembler? {
        if let existing = disassemblers[sessionID] { return existing }
        guard let node = node(forSessionID: sessionID),
            let info = session(id: sessionID)?.processInfo
        else { return nil }
        let d = Disassembler(node: node, processInfo: info)
        disassemblers[sessionID] = d
        return d
    }

    public func updateSession(id: UUID, _ mutate: (inout ProcessSession) -> Void) {
        guard var s = try? store.fetchSession(id: id) else { return }
        mutate(&s)
        saveSession(s)
    }

    public func createSession(_ session: ProcessSession) {
        try? store.save(session)
        sessions.insert(session, at: 0)
        onSessionListChanged?(.sessionAdded(session))
    }

    public func deleteSession(id: UUID) {
        if let node = node(forSessionID: id) {
            removeNode(node)
        }
        try? store.deleteSession(id: id)
        sessions.removeAll { $0.id == id }
        onSessionListChanged?(.sessionRemoved(id))
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

    public func deleteCapture(id: UUID, sessionID: UUID) {
        if localUserHosts(sessionID) {
            try? store.deleteCapture(id: id)
            onSessionListChanged?(.captureRemoved(id: id, sessionID: sessionID))
        }
        if collaboration.isCollaborative {
            collaboration.enqueueRemoveCapture(sessionID: sessionID, captureID: id)
        }
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
            for capture in ((try? store.fetchITraceCaptures(sessionID: session.id)) ?? []).sorted(by: { $0.capturedAt < $1.capturedAt }) {
                onSessionListChanged?(.captureAdded(capture))
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
            await claimHostingAndAttach(session: &session, device: device, process: chosen, localUser: localUser)
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

    private func claimHostingAndAttach(
        session: inout ProcessSession,
        device: Device,
        process: ProcessDetails,
        localUser: CollaborationSession.UserInfo
    ) async {
        if let existingNode = node(forSessionID: session.id) {
            removeNode(existingNode)
        }
        session.host = localUser
        session.deviceID = device.id
        session.deviceName = device.name
        session.processName = process.name
        session.lastKnownPID = process.pid
        session.lastKnownModules = nil
        session.phase = .attaching
        saveSession(session)

        collaboration.enqueueClaimHost(
            sessionID: session.id,
            deviceID: device.id,
            deviceName: device.name,
            pid: process.pid,
            processName: process.name
        )

        await attach(device: device, process: process, session: session)
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
            await spawnAndAttach(device: device, session: s)
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

            await performAttach(device: device, process: chosen, session: s)
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
        if !localUserHosts(sessionID) {
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
        if !localUserHosts(instance.sessionID) {
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
        onSessionListChanged?(.instrumentRemoved(id: instance.id, sessionID: instance.sessionID))
        rebuildAddressAnnotations(sessionID: instance.sessionID)
        if let sid {
            collaboration.enqueueRemoveInstrument(sessionID: sid, instanceID: instance.id)
        }
    }

    public func setInstrumentState(_ instance: InstrumentInstance, state: InstrumentState) async {
        if !localUserHosts(instance.sessionID) {
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
        if !localUserHosts(instance.sessionID) {
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
            } catch {
                print("[Engine] Failed to compile tracer config: \(String(describing: error)))")
                return
            }

        case .hookPack:
            let config = (try? HookPackConfig.decode(from: configJSON))
                ?? HookPackConfig(packId: inst.sourceIdentifier, features: [:])
            configObject = config.toJSON()

        case .codeShare:
            configObject = (try? JSONSerialization.jsonObject(with: configJSON, options: []) as? JSONObject) ?? [:]
        }

        do {
            try await node.pushInstrumentConfig(instanceID: inst.id, config: configObject)
        } catch {
            print("[Engine] Failed to update instrument config: \(String(describing: error)))")
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
                guard let pack = hookPacks.pack(withId: sourceIdentifier),
                    let entrySource = try? String(contentsOf: pack.entryURL, encoding: .utf8)
                else { return }

                try await loadHookPackInstrument(
                    instanceID: instanceID,
                    packID: pack.manifest.id,
                    entrySource: entrySource,
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
            }

            node.markInstrumentAttached(id: instanceID)
        } catch {
            print("[Engine] Failed to load instrument \(instanceID.uuidString): \(String(describing: error)))")
        }
    }

    // MARK: - Tracer Instruction Hook

    public func addTracerInstructionHook(
        sessionID: UUID,
        address: UInt64
    ) async -> (instrumentID: UUID, hookID: UUID)? {
        guard (try? store.fetchSession(id: sessionID)) != nil else { return nil }

        let tracer: InstrumentInstance
        if let existing = tracerInstance(forSessionID: sessionID) {
            tracer = existing
        } else {
            let configJSON = TracerConfig().encode()
            guard let added = await addInstrument(
                kind: .tracer,
                sourceIdentifier: "builtin.tracer",
                configJSON: configJSON,
                sessionID: sessionID
            ) else { return nil }
            tracer = added
        }

        let anchor: AddressAnchor
        if let node = node(forSessionID: sessionID) {
            anchor = node.anchor(for: address)
        } else {
            anchor = .absolute(address)
        }

        var config = (try? TracerConfig.decode(from: tracer.configJSON)) ?? TracerConfig()

        if let existingID = config.hooks.first(where: { $0.addressAnchor == anchor })?.id {
            return (instrumentID: tracer.id, hookID: existingID)
        }

        let stub = defaultTracerCode(kind: .instruction, anchor: anchor, displayName: anchor.displayString)

        let newHook = TracerConfig.Hook(
            id: UUID(),
            displayName: String(format: "0x%llx", address),
            addressAnchor: anchor,
            kind: .instruction,
            isEnabled: true,
            code: stub
        )

        config.hooks.append(newHook)

        let configData = config.encode()
        await applyInstrumentConfig(tracer, configJSON: configData)

        return (instrumentID: tracer.id, hookID: newHook.id)
    }

    // MARK: - Address Actions

    public func registerAddressActionProvider(_ provider: @escaping AddressActionProvider) {
        addressActionProviders.append(provider)
    }

    public func addressActions(sessionID: UUID, address: UInt64) -> [AddressAction] {
        addressActionProviders.flatMap { $0(sessionID, address) }
    }

    private func tracerAddressActions(sessionID: UUID, address: UInt64) -> [AddressAction] {
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

        return [
            AddressAction(
                title: "Add Instruction Hook\u{2026}",
                systemImage: "pin",
                perform: { [weak self] in
                    guard let self,
                        let result = await self.addTracerInstructionHook(sessionID: sessionID, address: address)
                    else { return nil }
                    return .instrumentComponent(
                        sessionID: sessionID,
                        instrumentID: result.instrumentID,
                        componentID: result.hookID
                    )
                }
            )
        ]
    }

    // MARK: - Address Annotations

    public func rebuildAddressAnnotations(sessionID: UUID) {
        guard let tracer = tracerInstance(forSessionID: sessionID),
            let node = node(forSessionID: sessionID),
            let config = try? TracerConfig.decode(from: tracer.configJSON)
        else {
            addressAnnotations[sessionID] = [:]
            tracerInstanceIDBySession[sessionID] = nil
            return
        }

        tracerInstanceIDBySession[sessionID] = tracer.id

        var map: [UInt64: AddressAnnotation] = [:]
        for hook in config.hooks where hook.isEnabled {
            guard let addr = try? node.resolveSyncIfReady(hook.addressAnchor) else { continue }
            var ann = map[addr] ?? AddressAnnotation()
            ann.decorations.append(InstrumentAddressDecoration(help: "Has instruction hook"))
            ann.tracerHookID = hook.id
            map[addr] = ann
        }
        addressAnnotations[sessionID] = map
    }

    private func tracerInstance(forSessionID sessionID: UUID) -> InstrumentInstance? {
        let instruments = (try? store.fetchInstruments(sessionID: sessionID)) ?? []
        return instruments.first(where: { $0.kind == .tracer })
    }

    // MARK: - Tracer Compilation

    public func compileTracerConfig(
        _ config: TracerConfig,
        paths: CompilerWorkspacePaths
    ) async throws -> JSONObject {
        _ = try await compilerWorkspace.ensureReady(paths: paths)

        let results: [(Int, String, TracerConfig.Hook)] =
            try await withThrowingTaskGroup(
                of: (Int, String, TracerConfig.Hook).self
            ) { group in
                for (index, hook) in config.hooks.enumerated() {
                    group.addTask {
                        let js = try await self.compileTracerHook(
                            id: hook.id,
                            tsSource: hook.code,
                            paths: paths
                        )
                        return (index, js, hook)
                    }
                }

                var out: [(Int, String, TracerConfig.Hook)] = []
                out.reserveCapacity(config.hooks.count)
                for try await item in group {
                    out.append(item)
                }
                return out
            }

        var hooksJSON: [JSONObject] = []
        hooksJSON.reserveCapacity(results.count)

        for (_, js, hook) in results.sorted(by: { $0.0 < $1.0 }) {
            var dict: JSONObject = [
                "id": hook.id.uuidString,
                "displayName": hook.displayName,
                "addressAnchor": hook.addressAnchor.toJSON(),
                "isEnabled": hook.isEnabled,
                "code": js,
            ]
            if hook.isPinned { dict["isPinned"] = true }
            if hook.itraceEnabled { dict["itraceEnabled"] = true }
            hooksJSON.append(dict)
        }

        return ["hooks": hooksJSON]
    }

    private func compileTracerHook(
        id: UUID,
        tsSource: String,
        paths: CompilerWorkspacePaths
    ) async throws -> String {
        let fm = FileManager.default

        let dirRelPath = "TracerHooks"
        let dirURL = paths.root.appendingPathComponent(dirRelPath, isDirectory: true)

        if !fm.fileExists(atPath: dirURL.path) {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        let moduleRelPath = "\(dirRelPath)/\(id.uuidString).ts"
        let entryRelPath = "\(dirRelPath)/\(id.uuidString).entry.ts"

        let moduleURL = paths.root.appendingPathComponent(moduleRelPath)
        let entryURL = paths.root.appendingPathComponent(entryRelPath)

        try tsSource.write(to: moduleURL, atomically: true, encoding: .utf8)

        let entrySource = """
            import "./\(id.uuidString).ts";
            export {};
            """
        try entrySource.write(to: entryURL, atomically: true, encoding: .utf8)

        let options = BuildOptions()
        options.projectRoot = paths.root.path
        options.typeCheck = .none
        options.sourceMaps = .omitted
        options.compression = .terser

        let bundle = try await compilerWorkspace.withCompilerDiagnostics(label: "tracer hook \(id.uuidString)") { compiler in
            try await compiler.build(entrypoint: entryRelPath, options: options)
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
        let captures = (try? store.fetchITraceCaptures(sessionID: sessionID)) ?? []
        for capture in captures {
            let key = capture.hookID.uuidString
            counters[key] = max(counters[key] ?? 0, capture.callIndex + 1)
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
        packID: String,
        entrySource: String,
        configJSON: Data,
        on node: ProcessNode
    ) async throws {
        let config = try InstrumentConfigCodec.decode(HookPackConfig.self, from: configJSON)

        let data = Data(entrySource.utf8)
        let digest = SHA256.hash(data: data)
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        let moduleName = "/hookpacks/\(packID)/\(hashHex).js"

        try await node.loadInstrumentOnAgent(
            instanceID: instanceID,
            moduleName: moduleName,
            source: entrySource,
            config: config.toJSON()
        )
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
        kind: AddressInsight.Kind
    ) throws -> AddressInsight {
        guard let node = node(forSessionID: sessionID) else {
            throw LumaCoreError.invalidOperation("No attached process")
        }

        let anchor = node.anchor(for: pointer)

        let existing = (try? store.fetchInsights(sessionID: sessionID)) ?? []
        if let match = existing.first(where: { $0.kind == kind && $0.anchor == anchor }) {
            return match
        }

        let insight = AddressInsight(
            sessionID: sessionID,
            title: anchor.displayString,
            kind: kind,
            anchor: anchor
        )
        try store.save(insight)
        onSessionListChanged?(.insightAdded(insight))
        if let sid = collabSessionID(forNode: node) {
            collaboration.enqueueAddInsight(sessionID: sid, insight: insight)
        }
        return insight
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
                self?._events.yield(event)
                if let sid = self?.collabSessionID(forNode: node) {
                    switch event.source {
                    case .instrument, .console, .script:
                        self?.collaboration.sendEvent(sessionID: sid, event: event)
                    case .repl, .processOutput:
                        break
                    }
                }
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await result in node.replResults {
                let resultValue: REPLCell.Result
                switch result.value {
                case .js(let v): resultValue = .js(v)
                case .text(let t): resultValue = .text(t)
                }
                let cell = REPLCell(
                    id: result.id,
                    sessionID: sessionID,
                    code: result.code,
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
            for await capture in node.captures {
                let record = ITraceCaptureRecord(from: capture, sessionID: sessionID)
                try? self?.store.save(record)
                self?.onSessionListChanged?(.captureAdded(record))
                if let sid = self?.collabSessionID(forNode: node) {
                    self?.collaboration.enqueueAddCapture(sessionID: sid, capture: record)
                }
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await modules in node.moduleSnapshots {
                self?.updateSession(id: sessionID) {
                    $0.lastKnownModules = modules.map {
                        ProcessSession.PersistedModule(name: $0.name, base: $0.base, size: $0.size)
                    }
                }
                self?.rebuildAddressAnnotations(sessionID: sessionID)
                if let sid = self?.collabSessionID(forNode: node) {
                    self?.collaboration.enqueueUpdateSessionModules(sessionID: sid, modules: modules)
                }
            }
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

                case .lost:
                    self.deviceEventTasks[device.id]?.cancel()
                    self.deviceEventTasks[device.id] = nil
                    return

                default:
                    break
                }
            }
        }
    }

    private func handleDeviceOutput(device: Device, data: [UInt8], fd: Int, pid: UInt) {
        guard let node = processNodes.first(where: { $0.deviceID == device.id && $0.pid == pid }) else { return }

        _events.yield(RuntimeEvent(
            sessionID: node.sessionID,
            source: .processOutput(fd: fd),
            payload: .raw(
                message: String(bytes: data, encoding: .utf8) ?? "(\(data.count) bytes on fd \(fd))",
                data: data
            ),
            data: data
        ))
    }
}

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
