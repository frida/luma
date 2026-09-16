import Foundation

#if os(Windows)
import WinSDK
#endif

#if os(macOS) || os(Linux) || os(Windows)

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

    var kernelImage: URL? {
        avd.kernelImage
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
    private var qmpHandle: HANDLE?
    #endif

    private static let readySnapshotName = "frida-ready"

    /// QEMU has no UNIX sockets on Windows, so QMP is carried over a named pipe there instead.
    /// The backend adopts the handle already connected above rather than opening its own, which
    /// QEMU would no longer answer.
    private func qmpTransportAddress(socket: URL) -> String {
        #if os(Windows)
        "handle:\(UInt(bitPattern: qmpHandle.map { Int(bitPattern: $0) } ?? 0))"
        #else
        "unix:\(socket.path)"
        #endif
    }

    #if os(Windows)
    /// QEMU creates the pipe as it starts and then waits, so this retries until it is there.
    private static func connectToPipe(named name: String) throws -> HANDLE {
        let path = "\\\\.\\pipe\\" + name
        let deadline = Date().addingTimeInterval(pipeConnectSeconds)

        while Date() < deadline {
            let handle = path.withCString(encodedAs: UTF16.self) { wide in
                CreateFileW(
                    wide,
                    DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                    0,
                    nil,
                    DWORD(OPEN_EXISTING),
                    DWORD(FILE_ATTRIBUTE_NORMAL),
                    nil)
            }
            if let handle, handle != INVALID_HANDLE_VALUE {
                return handle
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        throw VirtualMachineError.launchFailed(
            reason: "The emulator never opened its QMP pipe at \(path)")
    }

    private static let pipeConnectSeconds: TimeInterval = 20
    #endif

    private static func qmpArgument(socket: URL, pipe: String) -> String {
        #if os(Windows)
        "pipe:\(pipe)"
        #else
        "unix:\(socket.path),server,nowait"
        #endif
    }

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

        // Old guest kernels lack vsock, so they are reached over a virtio-serial hostlink and
        // launched single-core. Inflating and scanning the kernel image is off the main thread.
        let kernelImage = avd.kernelImage
        let hasVsock = await Task.detached { Self.kernelSupportsVsock(kernelImage) }.value

        // The emulator bridges a guest's vsock to a host UNIX socket, which it has none of on
        // Windows, so the guest is reached over the virtio-serial hostlink there whatever its
        // kernel offers.
        #if os(Windows)
        let usesVsock = false
        #else
        let usesVsock = hasVsock
        #endif
        let qmpPipe = "frida-qmp-" + Foundation.UUID().uuidString.prefix(8).lowercased()

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
                "-qmp", Self.qmpArgument(socket: qmpSocketPath, pipe: qmpPipe),
                "-device", "virtio-serial-pci,id=\(Self.hostlinkController)",
            ]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            state = .failed(reason: error.localizedDescription)
            throw VirtualMachineError.launchFailed(reason: error.localizedDescription)
        }

        // QEMU holds the machine still until its QMP pipe is connected to, and gives the pipe up
        // for good once that connection goes, so it is opened here, before the guest is waited on,
        // and held for the backend to adopt.
        #if os(Windows)
        if !usesVsock {
            do {
                qmpHandle = try Self.connectToPipe(named: qmpPipe)
            } catch {
                await shutDown()
                let reason = (error as? VirtualMachineError)?.reason ?? error.localizedDescription
                state = .failed(reason: reason)
                throw VirtualMachineError.launchFailed(reason: reason)
            }
        }
        #endif

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

    private func waitForDevice(serial: String) async throws {
        let adb = self.adb
        let ok = await Task.detached {
            AndroidEmulatorSDK.run(adb, ["-s", serial, "wait-for-device"]) != nil
        }.value
        if !ok {
            throw VirtualMachineError.launchFailed(reason: "The emulator did not finish booting")
        }
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
        #if os(Windows)
        if let qmpHandle { CloseHandle(qmpHandle) }
        qmpHandle = nil
        #endif
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
    /// hostlink instead. Distributions ship the image wrapped -- gzipped on arm64, a self-extracting
    /// PE on x86 -- and the symbol is only in the payload, so it is unwrapped before searching.
    private nonisolated static func kernelSupportsVsock(_ url: URL?) -> Bool {
        guard let url, let packed = try? Data(contentsOf: url) else { return true }
        return LinuxKernelImage.names("vsock", in: packed)
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
