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
    }


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
