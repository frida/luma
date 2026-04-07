import Combine
import Foundation
import Frida
import LumaCore
import SwiftyR2

@MainActor
final class ProcessNodeViewModel: ObservableObject, Identifiable {
    let core: LumaCore.ProcessNode

    var sessionID: UUID
    private let store: ProjectStore

    @Published var modules: [ProcessModule] = []
    @Published var instruments: [InstrumentRuntime] = []

    var r2: R2Core!
    private var openR2Task: Task<Void, Never>?

    var onDestroyed: ((ProcessNodeViewModel, SessionDetachReason) -> Void)?
    var onModulesSnapshotReady: ((ProcessNodeViewModel) -> Void)?

    var id: UUID { core.id }
    var device: Device { core.device }
    var process: ProcessDetails { core.process }
    var session: Session { core.session }
    var script: Script { core.script }
    var loadedPackageNames: Set<String> {
        get { core.loadedPackageNames }
        set { core.loadedPackageNames = newValue }
    }

    var sessionRecord: LumaCore.ProcessSession {
        try! store.fetchSession(id: sessionID)!
    }

    init(
        core: LumaCore.ProcessNode,
        sessionID: UUID,
        store: ProjectStore
    ) {
        self.core = core
        self.sessionID = sessionID
        self.store = store

        let instances = (try? store.fetchInstruments(sessionID: sessionID)) ?? []
        self.instruments = instances.map {
            InstrumentRuntime(instance: $0, processNode: self)
        }

        subscribeToStreams()
    }

    private func subscribeToStreams() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await modules in self.core.moduleSnapshots {
                self.modules = modules
            }
        }
    }

    func stop() {
        core.stop()
    }

    func markSessionBoundary() {
        let cell = LumaCore.REPLCell(
            sessionID: sessionID,
            code: "New process attached",
            result: .text(""),
            isSessionBoundary: true
        )
        try? store.save(cell)
    }

    func fetchAndPersistProcessInfoIfNeeded() async {
        guard sessionRecord.processInfo == nil else { return }

        if let info = await core.fetchProcessInfo() {
            updateSession {
                $0.processInfo = LumaCore.ProcessSession.ProcessInfo(
                    platform: info.platform,
                    arch: info.arch,
                    pointerSize: info.pointerSize
                )
            }
        }
    }

    // MARK: - R2 Integration

    func ensureR2Opened() async {
        if let task = openR2Task {
            await task.value
            return
        }

        let task = Task { @MainActor in
            let r2 = await R2Core.create()
            self.r2 = r2

            await r2.registerIOPlugin(
                asyncProvider: ProcessMemoryIOProvider(processNode: self),
                uriSchemes: ["frida-mem://"]
            )

            await r2.setColorLimit(.mode16M)

            await r2.config.set("scr.utf8", bool: true)
            await r2.config.set("scr.color", colorMode: .mode16M)
            await r2.config.set("cfg.json.num", string: "hex")
            await r2.config.set("asm.emu", bool: true)
            await r2.config.set("emu.str", bool: true)
            await r2.config.set("anal.cc", string: "cdecl")

            let info = self.sessionRecord.processInfo!
            await r2.config.set("asm.os", string: info.platform)
            await r2.config.set("asm.arch", string: Self.r2Arch(fromFridaArch: info.arch))
            await r2.config.set("asm.bits", int: info.pointerSize * 8)

            let uri = "frida-mem://0x0"
            await r2.openFile(uri: uri)
            await r2.cmd("=!")
            await r2.binLoad(uri: uri)
        }

        openR2Task = task
        await task.value
    }

    static func r2Arch(fromFridaArch arch: String) -> String {
        switch arch {
        case "ia32", "x64":
            return "x86"
        case "arm64":
            return "arm"
        default:
            return arch
        }
    }

    func applyR2Theme(_ name: String) async {
        await ensureR2Opened()
        await r2.applyTheme(name)
    }

    func r2Cmd(_ command: String) async -> String {
        await ensureR2Opened()
        return await r2.cmd(command)
    }

    // MARK: - Persistence Helpers

    func updateSession(_ mutate: (inout LumaCore.ProcessSession) -> Void) {
        guard var s = try? store.fetchSession(id: sessionID) else { return }
        mutate(&s)
        try? store.save(s)
    }
}
