import Foundation
import Observation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

@Observable
@MainActor
final class QemuMachine: VirtualMachine {
    let id: Foundation.UUID
    let name: String
    let template: VirtualMachineTemplate
    private(set) var state: VirtualMachineState = .starting
    private(set) var display: VirtualMachineDisplay?
    private(set) var debugStub: BareboneDebugStub?

    var capabilities: VirtualMachineCapabilities {
        [.snapshot, .liveDisplay, .input]
    }

    var agentTransport: BareboneAgentTransport? {
        .hostlink(qmpSocket: agentQmpSocketPath, bus: QemuIdentifier.hostlinkBus, ecam: guest.ecam)
    }

    /// What the guest booted, which for a kernel the host has the map of is that map.
    var kernelImage: URL? {
        request.text(QemuParameter.symbols).map { URL(fileURLWithPath: $0) }
    }

    private let guest: QemuGuest
    private let executable: URL
    private let request: VirtualMachineLaunchRequest
    private let process = Process()
    private let runtimeDirectory: URL
    private var monitor: QemuMonitor?
    private var displayConnection: QemuDisplayConnection?
    private var hasReadySnapshot: Bool

    init(guest: QemuGuest, executable: URL, request: VirtualMachineLaunchRequest) {
        self.guest = guest
        self.executable = executable
        self.request = request
        self.id = request.id
        self.name = request.name
        self.template = request.template
        self.hasReadySnapshot = request.resumesFromReadySnapshot
        self.runtimeDirectory = GuestSocketDirectory.make()
    }

    private var complaints: [String] = []

    func start() async throws {
        let gdbPort = try Self.reserveGdbPort()
        let snapshotDisk = try createSnapshotDisk()

        let complaints = Pipe()
        process.standardError = complaints
        process.standardOutput = FileHandle.nullDevice
        collectComplaints(from: complaints.fileHandleForReading)

        process.executableURL = executable
        process.arguments = try guest.arguments(
            for: request,
            gdbPort: gdbPort,
            qmpPath: qmpSocketPath,
            agentQmpPath: agentQmpSocketPath,
            snapshotDisk: snapshotDisk
        )

        do {
            try process.run()
        } catch {
            state = .failed(reason: error.localizedDescription)
            throw VirtualMachineError.launchFailed(reason: error.localizedDescription)
        }

        do {
            let monitor = try await QemuMonitor(socketPath: qmpSocketPath, deadline: Date().addingTimeInterval(10))
            self.monitor = monitor
            displayConnection = try await QemuDisplayConnection(
                monitor: monitor, pointerIsAbsolute: guest.pointer.isAbsolute,
                processID: process.processIdentifier)
            display = displayConnection.map { .frames($0) }
        } catch {
            await shutDown()
            let failure = VirtualMachineError.launchFailure(lastComplaint ?? error.localizedDescription, from: error)
            state = .failed(reason: failure.reason)
            throw failure
        }

        debugStub = .gdbRemote(host: "127.0.0.1", port: gdbPort)
        state = .running

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.noteUnexpectedExit()
            }
        }
    }

    private func noteUnexpectedExit() {
        switch state {
        case .running, .capturingSnapshot, .restoringSnapshot:
            state = .failed(reason: lastComplaint ?? "QEMU exited unexpectedly")
        default:
            break
        }
    }

    /// What QEMU itself said about a failed boot -- a locked disk image, an
    /// unreadable one -- beats any guess made from this side of the pipe.
    private func collectComplaints(from handle: FileHandle) {
        Task { [weak self] in
            for await line in handle.lines {
                guard let self else { return }
                complaints.append(line)
                complaints = complaints.suffix(Self.complaintsKept)
            }
        }
    }

    private var lastComplaint: String? {
        complaints.last { !$0.isEmpty }
    }

    private static let complaintsKept = 10

    func discardReadySnapshot() async throws {
        guard let monitor else { return }

        _ = try await monitor.monitor("delvm \(QemuIdentifier.readySnapshot)")
        hasReadySnapshot = false
    }

    func captureReadySnapshot() async throws {
        guard let monitor else { return }

        state = .capturingSnapshot
        defer { state = .running }

        try await removeHostlinkPort(using: monitor)

        try await monitor.execute("stop")
        _ = try await monitor.monitor("delvm \(QemuIdentifier.readySnapshot)")
        let failure = try await monitor.monitor("savevm \(QemuIdentifier.readySnapshot)")
        try await monitor.execute("cont")

        guard failure.isEmpty else {
            throw VirtualMachineError.snapshotFailed(reason: failure)
        }
        hasReadySnapshot = true
    }

    func restoreReadySnapshot() async throws {
        guard let monitor, hasReadySnapshot else { return }

        state = .restoringSnapshot
        defer { state = .running }

        try await removeHostlinkPort(using: monitor)

        let failure = try await monitor.monitor("loadvm \(QemuIdentifier.readySnapshot)")
        guard failure.isEmpty else {
            throw VirtualMachineError.snapshotFailed(reason: failure)
        }
        try await monitor.execute("cont")
    }

    func shutDown() async {
        process.terminationHandler = nil
        displayConnection?.close()
        displayConnection = nil
        display = nil

        monitor?.disconnect()
        monitor = nil

        await process.terminateAndWaitForExit()
        try? FileManager.default.removeItem(at: runtimeDirectory)
        debugStub = nil
        state = .stopped
    }

    private func removeHostlinkPort(using monitor: QemuMonitor) async throws {
        let deadline = Date().addingTimeInterval(Self.hostlinkRemovalSeconds)

        if try await monitor.peripherals().contains(QemuIdentifier.hostlinkPort) {
            _ = try await monitor.execute("device_del", arguments: ["id": .string(QemuIdentifier.hostlinkPort)])

            while try await monitor.peripherals().contains(QemuIdentifier.hostlinkPort) {
                try await settle(before: deadline, orGiveUpWith: "the hostlink port would not go away")
            }
        }

        // QEMU lets go of the chardev a moment after the port it fed is gone,
        // and calls it busy until it does.
        while try await monitor.chardevs().contains(QemuIdentifier.hostlinkChardev) {
            do {
                _ = try await monitor.execute("chardev-remove", arguments: ["id": .string(QemuIdentifier.hostlinkChardev)])
            } catch let error as QmpError where error.isBusy {
            }
            try await settle(before: deadline, orGiveUpWith: "the hostlink chardev would not go away")
        }
    }

    private func settle(before deadline: Date, orGiveUpWith reason: String) async throws {
        guard Date() < deadline else {
            throw VirtualMachineError.snapshotFailed(reason: reason)
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    private func createSnapshotDisk() throws -> URL {
        let disk = request.storageDirectory.appendingPathComponent("snapshots.qcow2")
        guard !FileManager.default.fileExists(atPath: disk.path) else { return disk }

        guard let qemuImage = QemuExecutable.path(for: "qemu-img") else {
            throw VirtualMachineError.launchFailed(reason: "qemu-img is not installed")
        }

        let creation = Process()
        creation.executableURL = qemuImage
        creation.arguments = ["create", "-f", "qcow2", disk.path, Self.snapshotDiskSize]
        creation.standardOutput = FileHandle.nullDevice
        let creationComplaints = Pipe()
        creation.standardError = creationComplaints
        try creation.run()
        let creationOutput = creationComplaints.fileHandleForReading.readDataToEndOfFile()
        creation.waitUntilExit()

        guard creation.terminationStatus == 0 else {
            let reason = String(decoding: creationOutput, as: UTF8.self)
                .split(separator: "\n").last.map(String.init)
            throw VirtualMachineError.launchFailed(reason: reason ?? "qemu-img could not make room for snapshots")
        }
        return disk
    }

    /// A QMP server hands its socket to one client at a time, and this one
    /// keeps its own for as long as the machine runs, so the agent's transport
    /// is given a monitor of its own to talk to.
    private var agentQmpSocketPath: URL {
        runtimeDirectory.appendingPathComponent("qmp-agent.sock")
    }

    private var qmpSocketPath: URL {
        runtimeDirectory.appendingPathComponent("qmp.sock")
    }

    private static let snapshotDiskSize = "8G"
    private static let hostlinkRemovalSeconds: TimeInterval = 5

    #if os(Windows)
    private static func reserveGdbPort() throws -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        defer { closesocket(handle) }

        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(handle, address, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw VirtualMachineError.launchFailed(reason: "No port was free for the debugger")
        }

        var assigned = sockaddr_in()
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getsockname(handle, address, &length)
            }
        }
        return UInt16(bigEndian: assigned.sin_port)
    }
    #else
    private static func reserveGdbPort() throws -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(handle) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
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
    #endif
}

