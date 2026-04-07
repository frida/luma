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

    @Published var monacoFSSnapshot: MonacoFSSnapshot? = nil
    var monacoFSSnapshotDirty: Bool = true
    var monacoFSSnapshotVersion: Int = 0

    @Published var isAuthSheetPresented: Bool = false
    @Published var authState: GitHubAuthState = .signedOut
    @Published var currentGitHubUser: CollaborationSession.UserInfo?
    @Published var githubToken: String? {
        didSet {
            Task { await loadCurrentGitHubUser() }
        }
    }

    @Published var isCollaborationPanelVisible: Bool = false

    enum GitHubAuthState: Equatable {
        case signedOut
        case requestingCode(code: String, verifyURL: URL)
        case waitingForApproval
        case authenticated
        case failed(reason: String)
    }

    private var observations: [StoreObservation] = []

    init(store: ProjectStore) {
        self.store = store
        let fm = FileManager.default
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dataDirectory = appSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "re.frida.Luma", isDirectory: true)
        try! fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        self.engine = Engine(store: store, dataDirectory: dataDirectory)

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

    private func observeEngineNodes() {
        withObservationTracking {
            _ = engine.processNodes
            for node in engine.processNodes {
                _ = node.instruments
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncProcessNodes()
                self?.observeEngineNodes()
            }
        }
    }

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
        observeEngineNodes()
    }

    // MARK: - Collaboration UI

    func bindProjectCollaboration() {
        let collabState = (try? store.fetchCollaborationState()) ?? LumaCore.ProjectCollaborationState()

        let roomFromLink = CollaborationJoinCoordinator.shared.consumeNextRoomID()
        let initialRoomID = roomFromLink ?? collabState.roomID

        if let roomID = roomFromLink ?? initialRoomID, roomFromLink != nil {
            isCollaborationPanelVisible = true
            startCollaboration(joiningRoom: roomID)
        }
    }

    func startCollaboration(joiningRoom roomID: String? = nil) {
        guard let token = githubToken else {
            authState = .signedOut
            isAuthSheetPresented = true
            return
        }

        let existing = roomID ?? (try? store.fetchCollaborationState())?.roomID
        Task { @MainActor in
            await engine.collaboration.start(token: token, existingRoomID: existing)
        }
    }

    func stopCollaboration() {
        Task { @MainActor in
            await engine.collaboration.stop()
        }
    }

    func signOut() {
        Task {
            TokenStore.delete(kind: .github)
            githubToken = nil
            currentGitHubUser = nil
            authState = .signedOut
            await engine.collaboration.stop()
        }
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

    // MARK: - Reestablish (UI: needs target picker)

    func reestablishSession(for sessionRecord: LumaCore.ProcessSession) async {
        let result = await engine.reestablishSession(id: sessionRecord.id)
        if case .needsUserInput(let reason, let session) = result {
            targetPickerContext = .reestablish(session: session, reason: reason)
        }
    }

    // MARK: - VM Sync

    private func syncProcessNodes() {
        let coreNodes = engine.processNodes
        let existingIDs = Set(processNodes.map(\.core.id))
        let coreIDs = Set(coreNodes.map(\.id))

        for vm in processNodes where !coreIDs.contains(vm.core.id) {
            addressAnnotationsBySession[vm.sessionID] = nil
            tracerInstanceIDBySession[vm.sessionID] = nil
        }

        processNodes.removeAll { !coreIDs.contains($0.core.id) }

        for coreNode in coreNodes where !existingIDs.contains(coreNode.id) {
            let sessionID = engine.sessionID(for: coreNode)
            let vm = ProcessNodeViewModel(
                core: coreNode,
                sessionID: sessionID,
                store: store
            )

            vm.onModulesSnapshotReady = { [weak self] node in
                guard let self else { return }
                self.rebuildAddressDecorations(for: node.sessionRecord)
            }

            processNodes.append(vm)
        }

        for vm in processNodes {
            syncInstrumentRuntimes(for: vm)
        }
    }

    private func syncInstrumentRuntimes(for vm: ProcessNodeViewModel) {
        let coreRefs = vm.core.instruments
        let existingIDs = Set(vm.instruments.map(\.id))
        let coreIDs = Set(coreRefs.map(\.id))

        vm.instruments.removeAll { !coreIDs.contains($0.id) }

        for ref in coreRefs where !existingIDs.contains(ref.id) {
            let inst = LumaCore.InstrumentInstance(
                id: ref.id,
                sessionID: vm.sessionID,
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

            currentGitHubUser = CollaborationSession.UserInfo(
                id: me.login,
                name: me.name ?? me.login,
                avatarURL: URL(string: me.avatar_url)
            )
        } catch {
            currentGitHubUser = nil
        }
    }
}
