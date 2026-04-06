import Combine
import Foundation
import Frida
import LumaCore
import SwiftData
import SwiftyR2

@MainActor
final class ProcessNodeViewModel: ObservableObject, Identifiable {
    let core: LumaCore.ProcessNode

    let sessionRecord: ProcessSession

    @Published var modules: [ProcessModule] = []
    @Published var instruments: [InstrumentRuntime] = []

    var r2: R2Core!
    private var openR2Task: Task<Void, Never>?

    private let modelContext: ModelContext

    var onDestroyed: ((ProcessNodeViewModel, SessionDetachReason) -> Void)?
    var onModulesSnapshotReady: ((ProcessNodeViewModel) -> Void)?
    var eventSink: ((LumaCore.RuntimeEvent) -> Void)?

    var id: UUID { core.id }
    var device: Device { core.device }
    var process: ProcessDetails { core.process }
    var session: Session { core.session }
    var script: Script { core.script }
    var loadedPackageNames: Set<String> {
        get { core.loadedPackageNames }
        set { core.loadedPackageNames = newValue }
    }

    init(
        core: LumaCore.ProcessNode,
        sessionRecord: ProcessSession,
        modelContext: ModelContext
    ) {
        self.core = core
        self.sessionRecord = sessionRecord
        self.modelContext = modelContext

        self.instruments = sessionRecord.instruments.map {
            InstrumentRuntime(instance: $0, processNode: self)
        }

        subscribeToStreams()
    }

    private func subscribeToStreams() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await modules in self.core.moduleSnapshots {
                self.modules = modules
                self.persistModules()
                self.onModulesSnapshotReady?(self)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for await reason in self.core.detachEvents {
                self.persistModules()
                self.sessionRecord.detachReason = reason
                self.onDestroyed?(self, reason)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.core.events {
                self.eventSink?(event)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for await result in self.core.replResults {
                self.appendREPLCell(result)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for await capture in self.core.captures {
                self.persistCapture(capture)
            }
        }
    }

    func stop() {
        core.stop()
    }

    func markSessionBoundary() {
        let cell = REPLCell(
            code: "New process attached",
            result: .text(""),
            timestamp: Date(),
            isSessionBoundary: true
        )
        cell.session = sessionRecord
        modelContext.insert(cell)
    }

    func fetchAndPersistProcessInfoIfNeeded() async {
        guard sessionRecord.processInfo == nil else { return }

        if let info = await core.fetchProcessInfo() {
            sessionRecord.processInfo = ProcessSession.ProcessInfo(
                platform: info.platform,
                arch: info.arch,
                pointerSize: info.pointerSize
            )
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

    // MARK: - Persistence

    private func appendREPLCell(_ result: REPLResult) {
        let resultValue: REPLCell.Result
        switch result.value {
        case .js(let v):
            resultValue = .js(v)
        case .text(let t):
            resultValue = .text(t)
        }

        let cell = REPLCell(
            code: result.code,
            result: resultValue,
            timestamp: result.timestamp
        )
        cell.session = sessionRecord
        modelContext.insert(cell)
    }

    private func persistCapture(_ capture: CapturedITrace) {
        let itraceCapture = ITraceCapture(
            hookID: capture.hookID,
            callIndex: capture.callIndex,
            displayName: capture.displayName,
            traceData: capture.traceData,
            metadataJSON: capture.metadataJSON,
            lost: capture.lost
        )
        itraceCapture.session = sessionRecord
        modelContext.insert(itraceCapture)
    }

    private func persistModules() {
        sessionRecord.lastKnownModules = modules.map {
            ProcessSession.PersistedModule(name: $0.name, base: $0.base, size: $0.size)
        }
    }
}
