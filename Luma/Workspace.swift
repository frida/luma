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

    @Published var targetPickerContext: TargetPickerContext?

    @Published var isCollaborationPanelVisible: Bool = false

    #if os(macOS)
        private let localNotifier = LocalNotifier()
    #endif

    init(store: ProjectStore) {
        self.store = store
        self.engine = Engine(store: store, dataDirectory: LumaAppPaths.shared.dataDirectory)
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
    }

    // MARK: - Persistence

    func configurePersistence() async {
        await engine.start()
        if engine.collaboration.status != .disconnected {
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
        }
    }


}
