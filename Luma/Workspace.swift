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
    let traces: TraceStore

    @Published var targetPickerContext: TargetPickerContext?

    var isCollaborationPanelVisible: Bool {
        get { projectUIState.isCollaborationPanelVisible }
        set {
            guard projectUIState.isCollaborationPanelVisible != newValue else { return }
            projectUIState.isCollaborationPanelVisible = newValue
            try? store.save(projectUIState)
        }
    }

    @Published var sessionUIStates: [UUID: SessionUIState] = [:]

    @Published var projectUIState: ProjectUIState = ProjectUIState()

    var selectedSidebarItem: SidebarItemID? {
        get {
            guard let json = projectUIState.selectedItemJSON,
                let data = json.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode(SidebarItemID.self, from: data)
        }
        set {
            let newJSON: String?
            if let newValue,
                let data = try? JSONEncoder().encode(newValue),
                let json = String(data: data, encoding: .utf8)
            {
                newJSON = json
            } else {
                newJSON = nil
            }
            guard newJSON != projectUIState.selectedItemJSON else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                    newJSON != self.projectUIState.selectedItemJSON
                else { return }
                self.projectUIState.selectedItemJSON = newJSON
                try? self.store.save(self.projectUIState)
            }
        }
    }

    func setEventStreamCollapsed(_ collapsed: Bool) {
        guard projectUIState.isEventStreamCollapsed != collapsed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                self.projectUIState.isEventStreamCollapsed != collapsed
            else { return }
            self.projectUIState.isEventStreamCollapsed = collapsed
            try? self.store.save(self.projectUIState)
        }
    }

    func setEventStreamBottomHeight(_ height: Double) {
        guard projectUIState.eventStreamBottomHeight != height else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                self.projectUIState.eventStreamBottomHeight != height
            else { return }
            self.projectUIState.eventStreamBottomHeight = height
            try? self.store.save(self.projectUIState)
        }
    }

    func sessionDetailSection(for sessionID: UUID) -> SessionDetailSection {
        guard let raw = sessionUIStates[sessionID]?.detailSection,
            let section = SessionDetailSection(rawValue: raw)
        else { return .summary }
        return section
    }

    func setSessionDetailSection(sessionID: UUID, section: SessionDetailSection) {
        mutateSessionUIState(sessionID: sessionID) { $0.detailSection = section.rawValue }
    }

    func lastSelectedModuleID(for sessionID: UUID) -> String? {
        sessionUIStates[sessionID]?.lastSelectedModuleID
    }

    func setLastSelectedModuleID(sessionID: UUID, moduleID: String?) {
        mutateSessionUIState(sessionID: sessionID) { $0.lastSelectedModuleID = moduleID }
    }

    func lastSelectedThreadID(for sessionID: UUID) -> UInt? {
        sessionUIStates[sessionID]?.lastSelectedThreadID
    }

    func setLastSelectedThreadID(sessionID: UUID, threadID: UInt?) {
        mutateSessionUIState(sessionID: sessionID) { $0.lastSelectedThreadID = threadID }
    }

    private func mutateSessionUIState(sessionID: UUID, _ mutate: @escaping (inout SessionUIState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var state = self.sessionUIStates[sessionID] ?? SessionUIState(sessionID: sessionID)
            mutate(&state)
            guard state != self.sessionUIStates[sessionID] else { return }
            self.sessionUIStates[sessionID] = state
            try? self.store.save(state)
        }
    }

    private static func loadSessionUIStates(store: ProjectStore) -> [UUID: SessionUIState] {
        (try? store.fetchAllSessionUIStates()) ?? [:]
    }

    #if os(macOS)
        private let localNotifier = LocalNotifier()
    #endif

    init(store: ProjectStore, traces: TraceStore, gitHubAuth: GitHubAuth? = nil) {
        self.store = store
        self.traces = traces
        self.engine = Engine(
            store: store,
            traces: traces,
            dataDirectory: LumaAppPaths.shared.dataDirectory,
            gitHubAuth: gitHubAuth
        )
        self.sessionUIStates = Self.loadSessionUIStates(store: store)
        self.projectUIState = (try? store.fetchProjectUIState()) ?? ProjectUIState()
        engine.onSessionListChanged = { [weak self] _ in self?.objectWillChange.send() }
        registerInstrumentUIs()
    }

    private func registerInstrumentUIs() {
        let registry = InstrumentUIRegistry.shared

        registry.register(for: "tracer", ui: TracerUI())
        registry.register(for: "codeshare", ui: CodeShareUI())

        for pack in engine.hookPacks.packs {
            registry.register(
                for: "hook-pack:\(pack.manifest.id)",
                ui: HookPackUI(manifest: pack.manifest)
            )
        }

        refreshCustomInstrumentUIs()
        engine.customInstruments.observers.append { [weak self] in
            self?.refreshCustomInstrumentUIs()
            self?.objectWillChange.send()
        }
    }

    private func refreshCustomInstrumentUIs() {
        let registry = InstrumentUIRegistry.shared
        for def in engine.customInstruments.defs {
            registry.register(
                for: "custom:\(def.id.uuidString)",
                ui: CustomInstrumentUI(defID: def.id)
            )
        }
    }

    // MARK: - Persistence

    func configurePersistence() async {
        await engine.start()
        objectWillChange.send()
        if engine.collaboration.isCollaborative {
            isCollaborationPanelVisible = true
        }
        #if os(macOS)
            attachLocalNotifier()
        #endif
    }

    #if os(macOS)
        private func attachLocalNotifier() {
            let notifier = localNotifier
            engine.onNotebookChanged = { [weak engine] change in
                guard case let .added(entry) = change else { return }
                guard let engine,
                      let authorID = entry.author?.id,
                      !engine.collaboration.isSelf(authorID)
                else { return }
                notifier.notifyEntryAdded(entry, labID: engine.collaboration.labID)
            }
            engine.collaboration.onMemberAdded = { [weak engine] member in
                guard let engine,
                      !engine.collaboration.isSelf(member.user.id)
                else { return }
                notifier.notifyMemberAdded(member, labID: engine.collaboration.labID)
            }
            engine.collaboration.onChatMessageReceived = { [weak engine] message in
                guard !message.isLocal, let engine else { return }
                notifier.notifyChatMessage(message, labID: engine.collaboration.labID)
            }
        }
    #endif


    var events: [RuntimeEvent] { engine.eventLog.events }

    func processNode(for event: RuntimeEvent) -> LumaCore.ProcessNode? {
        guard let sid = event.sessionID else { return nil }
        return engine.node(forSessionID: sid)
    }

    func instrument(for event: RuntimeEvent) -> LumaCore.InstrumentInstance? {
        guard case .instrument(let id, _) = event.source,
            let sid = event.sessionID
        else { return nil }
        return engine.instrument(id: id, sessionID: sid)
    }

    func sidebarItem(for target: NavigationTarget) -> SidebarItemID {
        switch target {
        case .instrumentComponent(let sid, let iid, let cid):
            return .instrumentComponent(sid, iid, cid, UUID())
        case .itrace(let sid, let tid):
            return .itrace(sid, tid)
        }
    }


}
