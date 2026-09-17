import Foundation
import Frida
import LumaCore

// Drives the whole Android-emulator path end to end: launch an AVD through the backend, hand its
// reported stub to frida-core, inject the barebone agent, and run one script. Env:
//   LUMA_BAREBONE_AGENT  (required) path to the linux-arm64 barebone agent binary
//   LUMA_EMULATOR_AVD    (optional) AVD name; defaults to the first discovered
//   LUMA_EMULATOR_SCRIPT (optional) agent source; defaults to send(1 + 1)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("[check] \(message)\n".utf8))
}

@MainActor
func checkDisplay(_ machine: any VirtualMachine) async throws {
    guard case .frames(let source)? = machine.display else { fail("machine published no frame source") }

    let deadline = Date().addingTimeInterval(60)
    while source.revision == 0, Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
    }
    guard let frame = source.frame, source.revision > 0 else {
        fail("no frame arrived within 60s")
    }
    note("first frame \(frame.width)x\(frame.height) stride \(frame.stride)")

    let settled = source.revision
    try await Task.sleep(for: .seconds(3))
    guard source.revision > settled else { fail("the stream stalled after its first frame") }
    note("OK — \(source.revision - settled) further frames in 3s")
}

@MainActor
func run() async throws {
    let env = ProcessInfo.processInfo.environment
    let displayOnly = env["LUMA_EMULATOR_DISPLAY_ONLY"] != nil
    guard let agentPath = env["LUMA_BAREBONE_AGENT"] ?? (displayOnly ? "" : nil) else {
        fail("set LUMA_BAREBONE_AGENT to the barebone agent binary")
    }
    let code = env["LUMA_EMULATOR_SCRIPT"] ?? "send(1 + 1);"

    func avds(of template: VirtualMachineTemplate) -> [String] {
        guard case .choice(let options, _) = template.parameters.first?.kind else { return [] }
        return options.map(\.id)
    }

    let backend = AndroidEmulatorBackend()
    let templates = backend.templates
    let wanted = env["LUMA_EMULATOR_AVD"]
    guard let template = templates.first(where: { wanted.map(avds(of:)($0).contains) ?? false })
            ?? templates.first
    else { fail("no Android emulator template") }
    let availability = backend.availability(for: template)
    guard availability.isAvailable else { fail(availability.reason ?? "backend unavailable") }

    let avdName = wanted ?? avds(of: template).first ?? ""
    guard !avdName.isEmpty else { fail("no AVD to launch") }

    note("launching AVD \(avdName) (\(template.architecture.rawValue))…")
    let request = VirtualMachineLaunchRequest(
        id: UUID(),
        template: template,
        name: "emulator-check",
        parameters: [AndroidEmulatorBackend.avdParameterID: .text(avdName)],
        agentPath: nil,
        storageDirectory: FileManager.default.temporaryDirectory,
        resumesFromReadySnapshot: false
    )
    let machine = try await backend.launch(request)
    note("emulator launched; stub reported")

    if displayOnly {
        try await checkDisplay(machine)
        await machine.shutDown()
        return
    }

    do {
        guard case .androidEmulator(let host, let port, let pid)? = machine.debugStub else { fail("machine did not report an androidEmulator stub") }
        guard let kernel = machine.kernelImage else { fail("machine has no kernel image") }
        let transport: BareboneInjectingTransportConfig
        switch machine.agentTransport {
        case .pipeVsock(let socketPath)?:
            transport = BareboneVsockPipeTransportConfig(socketPath: socketPath.path)
            note("transport pipe-vsock")
        case .hostlink(let qmp, let bus, let fabric)?:
            let fabricConfig: Frida.BareboneHostlinkFabric
            switch fabric {
            case .ports: fabricConfig = BareboneHostlinkPortsFabric()
            case .ecam(let base): fabricConfig = BareboneHostlinkEcamFabric(ecam: base)
            case .mmio: fabricConfig = BareboneHostlinkMmioFabric()
            }
            transport = BareboneHostlinkTransportConfig(qmp: qmp, bus: bus, fabric: fabricConfig)
            note("transport hostlink virtio-pci")
        default:
            fail("machine did not report a supported transport")
        }
        note("stub host=\(host) port=\(port) pid=\(pid)")
        note("kernel \(kernel.path)")

        let agentData = try Data(contentsOf: URL(fileURLWithPath: agentPath))
        let kernelSymbols = try LinuxKernelImage.open(path: kernel.path)
        note("kernel names vsock: \(kernelSymbols.hasSymbol(name: "vsock"))")
        let config = BareboneConfig(
            connection: BareboneConnectionConfig(host: host, port: UInt(port), pid: pid, flavor: .androidEmulator),
            agent: BareboneInjectedAgentConfig(
                image: [UInt8](agentData),
                transport: transport
            ),
            image: BareboneLinuxKernelConfig(kernel: kernelSymbols),
            kernel: .linux
        )

        note("connecting frida-core (parse kallsyms + instrument + inject)…")
        let manager = DeviceManager()
        let device = try await manager.addBareboneDevice(config: config, id: "emulator-check", name: "emulator-check")
        let session = try await device.attach(pid: 0)
        let script = try await session.createScript(source: code)
        // Subscribe before load: the script's send() fires as it loads, so a consumer started
        // afterwards can miss it. A detached task begins draining events first, then load runs.
        let firstMessage = Task { () -> String? in
            for await event in script.events {
                if case .message(let message, _) = event {
                    return "\(message)"
                }
            }
            return nil
        }
        note("loading script…")
        try await script.load()

        let timeout = Task { () -> String? in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            firstMessage.cancel()
            return nil
        }
        let message = await firstMessage.value
        timeout.cancel()
        note("MESSAGE \(message ?? "<none — timed out>")")

        try? await script.unload()
        try? await manager.close()
        note("OK — end to end works")
    }

    await machine.shutDown()
}

do {
    try await run()
} catch {
    if ProcessInfo.processInfo.environment["FRIDA_BAREBONE_DUMP_TMO"] != nil {
        try? await Task.sleep(nanoseconds: 6_000_000_000)
    }
    fail("\(error)")
}
