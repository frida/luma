import Combine
import Frida
import SwiftUI
import SwiftyMonaco
import LumaCore

@MainActor
final class Workspace: ObservableObject {
    let engine: Engine

    var deviceManager: DeviceManager { engine.deviceManager }
    let store: ProjectStore

    @Published var processNodes: [ProcessNodeViewModel] = []
    @Published var sessions: [LumaCore.ProcessSession] = []

    private(set) var addressAnnotationsBySession: [UUID: [UInt64: AddressAnnotation]] = [:]
    private(set) var tracerInstanceIDBySession: [UUID: UUID] = [:]

    struct AddressAnnotation {
        var decorations: [InstrumentAddressDecoration] = []
        var tracerHookID: UUID? = nil
    }

    @Published private(set) var events: [RuntimeEvent] = []
    @Published private(set) var eventsVersion: Int = 0

    @Published var notebookEntries: [LumaCore.NotebookEntry] = []

    @Published var targetPickerContext: TargetPickerContext?

    var compilerWorkspaceRoot: URL? {
        get { engine.compilerWorkspace.workspaceRoot }
        set { engine.compilerWorkspace.workspaceRoot = newValue }
    }
    var packageBundles: [String: String] {
        get { engine.compilerWorkspace.packageBundles }
        set { engine.compilerWorkspace.packageBundles = newValue }
    }
    var packageBundlesDirty: Bool {
        get { engine.compilerWorkspace.packageBundlesDirty }
        set { engine.compilerWorkspace.packageBundlesDirty = newValue }
    }
    var packageManager: PackageManager { engine.compilerWorkspace.packageManager }
    var packageOps: PackageOperationQueue { engine.compilerWorkspace.packageOps }
    @Published var lastCompilerDiagnostics: [String] = []
    @Published var monacoFSSnapshot: MonacoFSSnapshot? = nil
    var monacoFSSnapshotDirty: Bool = true
    var monacoFSSnapshotVersion: Int = 0

    @Published var isAuthSheetPresented: Bool = false
    @Published var authState: GitHubAuthState = .signedOut
    @Published var currentGitHubUser: UserInfo?
    @Published var githubToken: String? {
        didSet {
            Task { await loadCurrentGitHubUser() }
        }
    }

    var collaborationState: LumaCore.ProjectCollaborationState?
    @Published var collaborationStatus: CollaborationStatus = .disconnected
    @Published var collaborationRoomID: String?
    @Published var collaborationUser: UserInfo?
    @Published var collaborationParticipants: [UserInfo] = []
    @Published var collaborationChatMessages: [ChatMessage] = []

    @Published var isCollaborationPanelVisible: Bool = false

    @Published var storedProjectRoomID: String?
    private var updateStoredProjectRoomID: ((String?) -> Void)?

    @Published var isCollaborationHost: Bool = false

    var portalDevice: Device?
    var portalBusTask: Task<Void, Never>?

    enum GitHubAuthState: Equatable {
        case signedOut
        case requestingCode(code: String, verifyURL: URL)
        case waitingForApproval
        case authenticated
        case failed(reason: String)
    }

    enum CollaborationStatus: Equatable {
        case disconnected
        case connecting
        case joined(roomID: String)
        case error(message: String)
    }

    struct UserInfo: Identifiable, Hashable {
        let id: String
        let displayName: String
        let avatarURL: String

        static func fromJSON(_ obj: JSONObject) -> UserInfo? {
            guard
                let id = obj["id"] as? String,
                let name = obj["name"] as? String,
                let avatar = obj["avatar"] as? String
            else {
                return nil
            }
            return UserInfo(id: id, displayName: name, avatarURL: avatar)
        }
    }

    struct ChatMessage: Identifiable, Hashable {
        let id = UUID()
        let user: UserInfo
        let text: String
        let timestamp: Date
        let isLocalUser: Bool

        static func fromJSON(_ obj: JSONObject, localUser: UserInfo) -> ChatMessage? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            guard
                let userObj = obj["user"] as? JSONObject,
                let user = UserInfo.fromJSON(userObj),
                let text = obj["text"] as? String,
                let timestampString = obj["timestamp"] as? String,
                let ts = formatter.date(from: timestampString)
            else {
                return nil
            }

            return ChatMessage(
                user: user,
                text: text,
                timestamp: ts,
                isLocalUser: user.id == localUser.id
            )
        }
    }

    private var observations: [StoreObservation] = []

    init(store: ProjectStore) {
        self.store = store
        self.engine = Engine(store: store)

        engine.hookPackSourceProvider = { sourceIdentifier in
            guard let pack = HookPackLibrary.shared.pack(withId: sourceIdentifier) else { return nil }
            guard let source = try? String(contentsOf: pack.entryURL, encoding: .utf8) else { return nil }
            return (entrySource: source, packID: pack.manifest.id)
        }

        engine.hookPackDescriptorProvider = {
            HookPackLibrary.shared.packs.map { pack in
                let icon: InstrumentIcon
                if let iconMeta = pack.manifest.icon {
                    if let file = iconMeta.file {
                        icon = .file(pack.folderURL.appendingPathComponent(file))
                    } else if let system = iconMeta.systemName {
                        icon = .system(system)
                    } else {
                        icon = .system("puzzlepiece.extension")
                    }
                } else {
                    icon = .system("puzzlepiece.extension")
                }

                let packID = pack.manifest.id
                let defaultEnabled = Dictionary(
                    uniqueKeysWithValues: pack.manifest.features
                        .filter(\.defaultEnabled)
                        .map { ($0.id, FeatureConfig()) }
                )

                return InstrumentDescriptor(
                    id: "hook-pack:\(packID)",
                    kind: .hookPack,
                    sourceIdentifier: packID,
                    displayName: pack.manifest.name,
                    icon: icon,
                    makeInitialConfigJSON: {
                        try! JSONEncoder().encode(
                            HookPackConfig(packId: packID, features: defaultEnabled)
                        )
                    }
                )
            }
        }
        engine.reloadHookPackDescriptors()

        registerInstrumentUIs()

        githubToken = (try? TokenStore.load(kind: .github)) ?? nil
        Task { await loadCurrentGitHubUser() }

        subscribeToEngineEvents()
    }

    private func registerInstrumentUIs() {
        let registry = InstrumentUIRegistry.shared

        registry.register(for: "tracer", ui: TracerUI())
        registry.register(for: "codeshare", ui: CodeShareUI())

        for pack in HookPackLibrary.shared.packs {
            registry.register(
                for: "hook-pack:\(pack.manifest.id)",
                ui: HookPackUI(manifest: pack.manifest)
            )
        }
    }

    // MARK: - Persistence

    func configurePersistence() async {
        observations.append(
            store.observeSessions { [weak self] sessions in
                Task { @MainActor in self?.sessions = sessions }
            }
        )
        observations.append(
            store.observeNotebookEntries { [weak self] entries in
                Task { @MainActor in self?.notebookEntries = entries }
            }
        )

        await engine.loadRemoteDevices()
        bindProjectCollaboration()
        subscribeToEngineEvents()
    }

    // MARK: - Event Log Observation

    private func subscribeToEngineEvents() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in self.engine.eventLog.changes {
                self.refreshEventsFromLog()
            }
        }
    }

    private func refreshEventsFromLog() {
        events = engine.eventLog.events.map { coreEvent in
            wrapCoreEvent(coreEvent)
        }
        eventsVersion = engine.eventLog.totalReceived
    }

    private func wrapCoreEvent(_ coreEvent: LumaCore.RuntimeEvent) -> RuntimeEvent {
        let node = processNodes.first { vm in
            if case .instrument(let id, _) = coreEvent.source {
                return vm.instruments.contains { $0.id == id }
            }
            return true
        }
        var instrument: InstrumentRuntime?
        if case .instrument(let id, _) = coreEvent.source {
            instrument = node?.instruments.first { $0.id == id }
        }
        return RuntimeEvent(
            coreEvent: coreEvent,
            processNode: node ?? processNodes.first!,
            instrument: instrument
        )
    }

    func clearEvents() {
        engine.eventLog.clear()
    }

    // MARK: - Session Orchestration (thin delegates)

    func spawnAndAttach(
        device: Device,
        sessionRecord: LumaCore.ProcessSession
    ) async {
        await engine.spawnAndAttach(device: device, session: sessionRecord)
        syncProcessNodes()
    }

    func attachToProcess(
        device: Device,
        using process: ProcessDetails,
        sessionRecord: LumaCore.ProcessSession
    ) async {
        await engine.attach(device: device, process: process, session: sessionRecord)
        syncProcessNodes()
    }

    func resumeSpawnedProcess(node: ProcessNodeViewModel) async {
        await engine.resumeSpawnedProcess(node: node.core)
    }

    func removeNode(_ node: ProcessNodeViewModel) {
        let sessionID = node.sessionRecord.id
        addressAnnotationsBySession[sessionID] = [:]
        tracerInstanceIDBySession[sessionID] = nil

        engine.removeNode(node.core)
        syncProcessNodes()
    }

    func reestablishSession(for sessionRecord: LumaCore.ProcessSession) async {
        let result = await engine.reestablishSession(id: sessionRecord.id)
        switch result {
        case .attached:
            syncProcessNodes()
        case .needsUserInput(let reason, let session):
            targetPickerContext = .reestablish(session: session, reason: reason)
        }
    }

    // MARK: - ProcessNode VM Sync

    private func syncProcessNodes() {
        let coreNodes = engine.processNodes
        let existingIDs = Set(processNodes.map(\.core.id))
        let coreIDs = Set(coreNodes.map(\.id))

        processNodes.removeAll { !coreIDs.contains($0.core.id) }

        for coreNode in coreNodes where !existingIDs.contains(coreNode.id) {
            let sessionID = engine.sessionID(for: coreNode)
            let vm = ProcessNodeViewModel(
                core: coreNode,
                sessionID: sessionID,
                store: store
            )

            vm.onDestroyed = { [weak self] node, _ in
                self?.removeNode(node)
            }
            vm.onModulesSnapshotReady = { [weak self] node in
                guard let self else { return }
                self.rebuildAddressDecorations(for: node.sessionRecord)
            }

            processNodes.append(vm)
        }
    }

    // MARK: - Instrument Lifecycle (thin delegates)

    func addInstrument(
        descriptor: InstrumentDescriptor,
        initialConfigJSON: Data,
        for session: LumaCore.ProcessSession
    ) async -> LumaCore.InstrumentInstance {
        let instance = await engine.addInstrument(
            kind: descriptor.kind,
            sourceIdentifier: descriptor.sourceIdentifier,
            configJSON: initialConfigJSON,
            sessionID: session.id
        )

        syncInstrumentRuntimes(sessionID: session.id)

        if instance.kind == .tracer {
            rebuildAddressDecorations(for: session)
        }

        return instance
    }

    func removeInstrument(
        _ instance: LumaCore.InstrumentInstance,
        from session: LumaCore.ProcessSession
    ) async {
        await engine.removeInstrument(id: instance.id, sessionID: session.id)
        syncInstrumentRuntimes(sessionID: session.id)

        if instance.kind == .tracer {
            rebuildAddressDecorations(for: session)
        }
    }

    func setInstrumentEnabled(_ instance: LumaCore.InstrumentInstance, enabled: Bool) async {
        await engine.setInstrumentEnabled(instanceID: instance.id, sessionID: instance.sessionID, enabled: enabled)
        syncInstrumentRuntimes(sessionID: instance.sessionID)
    }

    func applyInstrumentConfig(
        _ instance: LumaCore.InstrumentInstance,
        data: Data
    ) async {
        await engine.applyInstrumentConfig(instanceID: instance.id, sessionID: instance.sessionID, configJSON: data)

        if instance.kind == .tracer, let session = try? store.fetchSession(id: instance.sessionID) {
            rebuildAddressDecorations(for: session)
        }
    }

    private func syncInstrumentRuntimes(sessionID: UUID) {
        guard let vm = processNodes.first(where: { $0.sessionRecord.id == sessionID }),
            let coreNode = engine.node(forSessionID: sessionID)
        else { return }

        let coreRefs = coreNode.instruments
        let existingIDs = Set(vm.instruments.map(\.id))
        let coreIDs = Set(coreRefs.map(\.id))

        vm.instruments.removeAll { !coreIDs.contains($0.id) }

        for ref in coreRefs where !existingIDs.contains(ref.id) {
            let inst = LumaCore.InstrumentInstance(
                id: ref.id,
                sessionID: sessionID,
                kind: ref.kind,
                sourceIdentifier: ref.sourceIdentifier,
                isEnabled: ref.isEnabled,
                configJSON: ref.configJSON
            )
            let runtime = InstrumentRuntime(instance: inst, processNode: vm)
            if ref.isAttached { runtime.markAttached() }
            vm.instruments.append(runtime)
        }

        for runtime in vm.instruments {
            if let ref = coreRefs.first(where: { $0.id == runtime.id }) {
                if ref.isAttached && !runtime.isAttached {
                    runtime.markAttached()
                }
                runtime.instance.isEnabled = ref.isEnabled
                runtime.instance.configJSON = ref.configJSON
            }
        }
    }

    // MARK: - Insight (delegate)

    func getOrCreateInsight(
        sessionID: UUID,
        pointer: UInt64,
        kind: LumaCore.AddressInsight.Kind
    ) throws -> LumaCore.AddressInsight {
        try engine.getOrCreateInsight(sessionID: sessionID, pointer: pointer, kind: kind)
    }

    // MARK: - Address Decorations (UI)

    func addressDecorations(
        sessionID: UUID,
        address: UInt64
    ) -> [InstrumentAddressDecoration] {
        addressAnnotationsBySession[sessionID]?[address]?.decorations ?? []
    }

    func rebuildAddressDecorations(for session: LumaCore.ProcessSession) {
        let hookAddresses = engine.tracerHookAddresses(sessionID: session.id)
        let tracerID = engine.tracerInstanceID(sessionID: session.id)

        tracerInstanceIDBySession[session.id] = tracerID

        guard tracerID != nil, !hookAddresses.isEmpty else {
            addressAnnotationsBySession[session.id] = [:]
            tracerInstanceIDBySession[session.id] = nil
            return
        }

        var map: [UInt64: AddressAnnotation] = [:]
        for (addr, hookID) in hookAddresses {
            var ann = map[addr] ?? AddressAnnotation()
            ann.decorations.append(InstrumentAddressDecoration(help: "Has instruction hook"))
            ann.tracerHookID = hookID
            map[addr] = ann
        }

        addressAnnotationsBySession[session.id] = map
    }

    func addressContextMenuItems(
        sessionID: UUID,
        address: UInt64,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentAddressMenuItem] {
        let context = InstrumentAddressContext(sessionID: sessionID, address: address)
        let registry = InstrumentUIRegistry.shared

        var items: [InstrumentAddressMenuItem] = []
        for descriptor in engine.descriptors {
            if let ui = registry.ui(for: descriptor.id) {
                items.append(contentsOf: ui.makeAddressContextMenuItems(context: context, workspace: self, selection: selection))
            }
        }

        return items
    }

    func addTracerInstructionHook(
        sessionID: UUID,
        address: UInt64,
        selection: Binding<SidebarItemID?>
    ) async {
        guard let result = await engine.addTracerInstructionHook(sessionID: sessionID, address: address) else { return }

        syncInstrumentRuntimes(sessionID: sessionID)

        if let session = try? store.fetchSession(id: sessionID) {
            rebuildAddressDecorations(for: session)
        }

        selection.wrappedValue = .instrumentComponent(sessionID, result.instrumentID, result.hookID, UUID())
    }

    // MARK: - Helpers

    func processSession(id sessionID: UUID) -> LumaCore.ProcessSession? {
        try? store.fetchSession(id: sessionID)
    }

    func attachedNode(for session: LumaCore.ProcessSession) -> ProcessNodeViewModel? {
        processNodes.first(where: { $0.sessionRecord.id == session.id })
    }

    func runtime(forSessionID sessionID: UUID, instrumentID: UUID) -> InstrumentRuntime? {
        guard let node = processNodes.first(where: { $0.sessionRecord.id == sessionID }) else { return nil }
        return node.instruments.first(where: { $0.instance.id == instrumentID })
    }

    // MARK: - GitHub Auth

    private func loadCurrentGitHubUser() async {
        guard let token = githubToken else {
            currentGitHubUser = nil
            return
        }

        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: req)
            struct Me: Decodable {
                let login: String
                let name: String?
                let avatar_url: String
            }
            let me = try JSONDecoder().decode(Me.self, from: data)

            currentGitHubUser = UserInfo(
                id: me.login,
                displayName: me.name ?? me.login,
                avatarURL: me.avatar_url
            )
        } catch {
            currentGitHubUser = nil
        }
    }
}
