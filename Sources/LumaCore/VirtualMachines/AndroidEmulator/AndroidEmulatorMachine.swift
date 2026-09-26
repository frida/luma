import Foundation
import Frida

#if os(Windows)
import WinSDK
#endif

#if os(Windows) || os(macOS) || os(Linux)

@MainActor
final class AndroidEmulatorMachine: VirtualMachine {
    let id: Foundation.UUID
    let name: String
    let template: VirtualMachineTemplate
    private(set) var state: VirtualMachineState = .starting
    private(set) var display: VirtualMachineDisplay?
    private(set) var debugStub: BareboneDebugStub?
    private(set) var agentTransport: BareboneAgentTransport?

    var capabilities: VirtualMachineCapabilities {
        [.snapshot, .liveDisplay, .input]
    }

    var kernelSymbols: BareboneKernelSymbols? {
        .linuxImage(avd.kernelImage)
    }

    private let emulator: URL
    private let adb: URL
    private let avd: AndroidEmulatorSDK.AVD
    private let process = ChildProcess()
    private let runtimeDirectory: URL
    private let hasReadySnapshot: Bool
    private var controlEndpoint: EmulatorControlEndpoint?
    private var qemuPid: HostProcessID?
    private var displayConnection: EmulatorDisplayConnection?
    #if os(Windows)
    private var qmpPort: UInt16 = 0
    #endif

    private static let readySnapshotName = "frida-ready"

    init(emulator: URL, adb: URL, avd: AndroidEmulatorSDK.AVD, request: VirtualMachineLaunchRequest) {
        self.id = request.id
        self.name = request.name
        self.template = request.template
        self.emulator = emulator
        self.adb = adb
        self.avd = avd
        self.hasReadySnapshot = request.resumesFromReadySnapshot
        self.runtimeDirectory = GuestSocketDirectory.make()
    }

    private var pipeSocketPath: URL {
        runtimeDirectory.appendingPathComponent("hostlink.sock")
    }

    private var qmpSocketPath: URL {
        runtimeDirectory.appendingPathComponent("qmp.sock")
    }

    private static let hostlinkBus = "frida-vserial.0"
    private static let hostlinkController = "frida-vserial"
    private static let pcieEcamBase: UInt64 = 0x3f00_0000

    func start() async throws {
        let gdbPort = try Self.reserveGdbPort()
        let grpcPort = try Self.reserveGdbPort()
        let consolePort = try Self.reserveConsolePort()

        #if os(Windows)
        let usesVsock = false
        qmpPort = try Self.reserveGdbPort()
        #else
        // Old guest kernels lack vsock, so they are reached over a virtio-serial hostlink and
        // launched single-core. Inflating and scanning the kernel image is off the main thread.
        let kernelImage = avd.kernelImage
        let usesVsock = await Task.detached { Self.kernelSupportsVsock(kernelImage) }.value
        #endif

        // Boot from the ready snapshot when resuming, or from the one named in the environment for a
        // fast debug loop; either way never save on exit, so injection damage is discarded.
        let snapshot = hasReadySnapshot
            ? Self.readySnapshotName
            : ProcessInfo.processInfo.environment["FRIDA_EMULATOR_SNAPSHOT"]

        process.executableURL = emulator
        process.arguments = [
            "@\(avd.name)",
            "-no-window",
            "-no-audio",
            "-no-boot-anim",
            "-gpu", "swiftshader_indirect",
        ]
        if let snapshot {
            process.arguments! += ["-snapshot", snapshot, "-no-snapshot-save"]
        } else {
            process.arguments! += ["-no-snapshot"]
        }
        process.arguments! += [
            "-ports", "\(consolePort),\(consolePort + 1)",
            "-grpc", "\(grpcPort)",
            "-qemu",
            "-gdb", "tcp::\(gdbPort)",
        ]
        if !usesVsock {
            // The injected agent drives this controller itself over the guest's PCIe config space
            // at the ranchu ECAM base; the QMP channel opens the host end of its serial port.
            process.arguments! += [
                "-qmp", qmpArgument(socket: qmpSocketPath),
                "-device", "virtio-serial-pci,id=\(Self.hostlinkController)",
            ]
        }
        if let path = ProcessInfo.processInfo.environment["FRIDA_EMULATOR_KERNEL_LOG"] {
            process.arguments!.insert("-show-kernel", at: 1)
            FileManager.default.createFile(atPath: path, contents: nil)
            let sink = FileHandle(forWritingAtPath: path)!
            process.standardOutput = sink
            process.standardError = sink
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            state = .failed(reason: error.localizedDescription)
            throw VirtualMachineError.launchFailed(reason: error.localizedDescription)
        }

        do {
            // adb answering means the kernel is up and scheduling -- what Frida needs to walk it,
            // and proof its QEMU is running so its pid can be found.
            try await waitForDevice(serial: "emulator-\(consolePort)")

            guard let qemuPid = Self.qemuProcess(matchingGdbPort: gdbPort) else {
                throw VirtualMachineError.launchFailed(reason: "Unable to find the emulator's QEMU process")
            }

            self.qemuPid = qemuPid
            debugStub = .androidEmulator(host: "127.0.0.1", port: gdbPort, pid: UInt(qemuPid))
            agentTransport = usesVsock
                ? .pipeVsock(socketPath: pipeSocketPath)
                : .hostlink(
                    qmp: qmpTransportAddress(socket: qmpSocketPath),
                    bus: Self.hostlinkBus,
                    fabric: .ecam(base: Self.pcieEcamBase))

            let endpoint = EmulatorControlEndpoint.discover(
                launcherPID: process.processIdentifier, port: Int(grpcPort), gdbPort: gdbPort)
            controlEndpoint = endpoint
            displayConnection = EmulatorDisplayConnection(endpoint: endpoint)
            display = displayConnection.map { .frames($0) }
            state = .running
        } catch {
            await shutDown()
            let reason = (error as? VirtualMachineError)?.reason ?? error.localizedDescription
            state = .failed(reason: reason)
            throw VirtualMachineError.launchFailed(reason: reason)
        }
    }

    private func qmpArgument(socket: URL) -> String {
        #if os(Windows)
        "tcp:127.0.0.1:\(qmpPort),server,nowait"
        #else
        "unix:\(socket.path),server,nowait"
        #endif
    }

    private func waitForDevice(serial: String) async throws {
        let adb = self.adb
        let ok = await Task.detached {
            AndroidEmulatorSDK.run(adb, ["-s", serial, "wait-for-device"]) != nil
        }.value
        if !ok {
            throw VirtualMachineError.launchFailed(reason: "The emulator did not finish booting")
        }
    }

    private func qmpTransportAddress(socket: URL) -> String {
        #if os(Windows)
        "tcp:127.0.0.1:\(qmpPort)"
        #else
        "unix:\(socket.path)"
        #endif
    }

    func captureReadySnapshot() async throws {
        try? await snapshot(.delete)
        try await snapshot(.save)
    }

    func restoreReadySnapshot() async throws {
        try await snapshot(.load)
    }

    func discardReadySnapshot() async throws {
        try? await snapshot(.delete)
    }

    private func snapshot(_ verb: EmulatorControlClient.SnapshotVerb) async throws {
        guard let controlEndpoint else {
            throw VirtualMachineError.snapshotFailed(reason: "The emulator is not running")
        }
        try await controlEndpoint.runSnapshot(verb, name: Self.readySnapshotName)
    }

    func shutDown() async {
        displayConnection?.close()
        displayConnection = nil
        display = nil
        await process.terminateAndWaitForExit()
        if let qemuPid { await Self.reap(qemuPid) }
        qemuPid = nil
        try? FileManager.default.removeItem(at: runtimeDirectory)
        controlEndpoint = nil
        debugStub = nil
        agentTransport = nil
        state = .stopped
    }

    /// The `emulator` launcher spawns `qemu-system-aarch64-headless` (and may reparent it), so the
    /// QEMU to instrument is not reliably a child of the launcher. It is found instead by the
    /// unique `tcp::<gdbPort>` this launch put on that QEMU's command line.
    private static func qemuProcess(matchingGdbPort gdbPort: UInt16) -> HostProcessID? {
        HostProcessLookup.firstProcess(named: "qemu-system", commandLineContaining: "tcp::\(gdbPort)")
    }

    private static func reap(_ id: HostProcessID) async {
        HostProcessLookup.terminate(id, force: false)
        let deadline = Date().addingTimeInterval(3)
        while HostProcessLookup.isAlive(id), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard HostProcessLookup.isAlive(id) else { return }
        HostProcessLookup.terminate(id, force: true)
        while HostProcessLookup.isAlive(id) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// vsock landed in ~4.8, so a guest kernel that names no vsock symbol needs the virtio-serial
    /// hostlink instead.
    private nonisolated static func kernelSupportsVsock(_ url: URL?) -> Bool {
        guard let url, let image = try? Frida.LinuxKernelImage.open(path: url.path) else { return true }
        return image.hasSymbol(name: "vsock")
    }

    private static func reserveGdbPort() throws -> UInt16 {
        guard let port = HostPort.reserveEphemeral() else {
            throw VirtualMachineError.launchFailed(reason: "No port was free for the debugger")
        }
        return port
    }

    /// adb only auto-discovers emulators whose console port is even and in the 5554..5584 band,
    /// so a free one there is claimed rather than an arbitrary ephemeral port.
    private static func reserveConsolePort() throws -> UInt16 {
        var port: UInt16 = 5554
        while port <= 5584 {
            if HostPort.isFree(port) && HostPort.isFree(port + 1) {
                return port
            }
            port += 2
        }
        throw VirtualMachineError.launchFailed(reason: "No console port was free for the emulator")
    }
}

#endif
