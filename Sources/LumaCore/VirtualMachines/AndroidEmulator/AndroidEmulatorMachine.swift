import Foundation
import Darwin

#if os(macOS)

@MainActor
final class AndroidEmulatorMachine: VirtualMachine {
    let id: UUID
    let name: String
    let template: VirtualMachineTemplate
    private(set) var state: VirtualMachineState = .starting
    private(set) var display: VirtualMachineDisplay?
    private(set) var debugStub: BareboneDebugStub?
    private(set) var agentTransport: BareboneAgentTransport?

    var capabilities: VirtualMachineCapabilities {
        []
    }

    var kernelImage: URL? {
        avd.kernelImage
    }

    private let emulator: URL
    private let adb: URL
    private let avd: AndroidEmulatorSDK.AVD
    private let process = Process()
    private let runtimeDirectory: URL

    init(emulator: URL, adb: URL, avd: AndroidEmulatorSDK.AVD, request: VirtualMachineLaunchRequest) {
        self.id = request.id
        self.name = request.name
        self.template = request.template
        self.emulator = emulator
        self.adb = adb
        self.avd = avd
        self.runtimeDirectory = GuestSocketDirectory.make()
    }

    private var pipeSocketPath: URL {
        runtimeDirectory.appendingPathComponent("hostlink.sock")
    }

    func start() async throws {
        let gdbPort = try Self.reserveGdbPort()
        let consolePort = try Self.reserveConsolePort()

        process.executableURL = emulator
        process.arguments = [
            "@\(avd.name)",
            "-no-window",
            "-no-snapshot",
            "-no-audio",
            "-no-boot-anim",
            "-gpu", "swiftshader_indirect",
            "-ports", "\(consolePort),\(consolePort + 1)",
            "-qemu",
            "-gdb", "tcp::\(gdbPort)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            state = .failed(reason: error.localizedDescription)
            throw VirtualMachineError.launchFailed(reason: error.localizedDescription)
        }

        do {
            // adb answering means the kernel is up and scheduling -- what Frida needs to walk it,
            // and proof its QEMU is running so its pid can be found. The emulator's own transport
            // (pipe-over-vsock) and the direct instrumentation of that QEMU need no QMP channel.
            try await waitForDevice(serial: "emulator-\(consolePort)")

            guard let qemuPid = Self.qemuProcess(matchingGdbPort: gdbPort) else {
                throw VirtualMachineError.launchFailed(reason: "Unable to find the emulator's QEMU process")
            }

            debugStub = .androidEmulator(host: "127.0.0.1", port: gdbPort, pid: UInt(qemuPid))
            agentTransport = .pipeVsock(socketPath: pipeSocketPath)
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
        throw VirtualMachineError.snapshotFailed(reason: "An Android emulator guest cannot be snapshotted")
    }

    func restoreReadySnapshot() async throws {
        throw VirtualMachineError.snapshotFailed(reason: "An Android emulator guest cannot be snapshotted")
    }

    func discardReadySnapshot() async throws {
        throw VirtualMachineError.snapshotFailed(reason: "An Android emulator guest cannot be snapshotted")
    }

    func shutDown() async {
        await process.terminateAndWaitForExit()
        try? FileManager.default.removeItem(at: runtimeDirectory)
        debugStub = nil
        agentTransport = nil
        state = .stopped
    }

    /// The `emulator` launcher spawns `qemu-system-aarch64-headless` (and may reparent it), so the
    /// QEMU to instrument is not reliably a child of the launcher. It is found instead by the
    /// unique `tcp::<gdbPort>` this launch put on that QEMU's command line.
    private static func qemuProcess(matchingGdbPort gdbPort: UInt16) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&mib, 4, nil, &size, nil, 0) != 0 { return nil }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        if sysctl(&mib, 4, &procs, &size, nil, 0) != 0 { return nil }

        let needle = "tcp::\(gdbPort)"
        for var proc in procs {
            let command = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard command.hasPrefix("qemu-system") else { continue }
            let pid = proc.kp_proc.p_pid
            if let arguments = processArguments(of: pid), arguments.contains(needle) {
                return pid
            }
        }
        return nil
    }

    private static func processArguments(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 { return nil }
        // The buffer is argc, exec path, then NUL-separated argv/env; NULs become spaces so the
        // whole thing can be searched as one string.
        let bytes = buffer.prefix(size).map { $0 == 0 ? UInt8(ascii: " ") : $0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func reserveGdbPort() throws -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(handle) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(handle, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw VirtualMachineError.launchFailed(reason: "No port was free for the debugger")
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getsockname(handle, address, &length)
            }
        }
        return UInt16(bigEndian: assigned.sin_port)
    }

    /// adb only auto-discovers emulators whose console port is even and in the 5554..5584 band,
    /// so a free one there is claimed rather than an arbitrary ephemeral port.
    private static func reserveConsolePort() throws -> UInt16 {
        var port: UInt16 = 5554
        while port <= 5584 {
            if portIsFree(port) && portIsFree(port + 1) {
                return port
            }
            port += 2
        }
        throw VirtualMachineError.launchFailed(reason: "No console port was free for the emulator")
    }

    private static func portIsFree(_ port: UInt16) -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        if handle < 0 { return false }
        defer { close(handle) }
        var reuse: Int32 = 0
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(handle, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

#endif
