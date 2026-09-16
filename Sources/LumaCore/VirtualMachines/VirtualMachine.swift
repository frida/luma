import Foundation

@MainActor
public protocol VirtualMachine: AnyObject, Identifiable {
    var id: UUID { get }
    var name: String { get }
    var template: VirtualMachineTemplate { get }
    var state: VirtualMachineState { get }
    var capabilities: VirtualMachineCapabilities { get }
    var display: VirtualMachineDisplay? { get }
    var debugStub: BareboneDebugStub? { get }
    var agentTransport: BareboneAgentTransport? { get }
    /// The image the guest booted, which carries the kernel's symbols.
    var kernelImage: URL? { get }

    func captureReadySnapshot() async throws
    func restoreReadySnapshot() async throws
    func discardReadySnapshot() async throws
    func shutDown() async
}

extension VirtualMachine {
    public var kernelImage: URL? {
        nil
    }
}

public enum VirtualMachineState: Sendable, Equatable {
    case starting
    case installing(fraction: Double)
    case running
    case capturingSnapshot
    case restoringSnapshot
    case stopped
    case failed(reason: String)
}

public struct VirtualMachineCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public static let snapshot = VirtualMachineCapabilities(rawValue: 1 << 0)
    public static let liveDisplay = VirtualMachineCapabilities(rawValue: 1 << 1)
    public static let input = VirtualMachineCapabilities(rawValue: 1 << 2)

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public enum BareboneAgentTransport: Sendable, Equatable {
    case hostlink(qmp: String, bus: String?, fabric: BareboneHostlinkFabric)
    case vsock(socketPath: URL, port: UInt)
    /// The guest dials out over vsock and the emulator bridges it to this host UNIX socket; the
    /// path is whitelisted in the emulator by the barebone backend's instrumentation.
    case pipeVsock(socketPath: URL)
}

public enum BareboneHostlinkFabric: Sendable, Equatable {
    case ports
    case ecam(base: UInt64)
    case mmio
}

public enum BareboneDebugStub: Sendable, Equatable {
    case gdbRemote(host: String, port: UInt16)
    case virtualization(pid: UInt)
    /// The Android emulator's gdbstub, reachable over host/port but unusable until the backend
    /// instruments the hosting qemu process at `pid`.
    case androidEmulator(host: String, port: UInt16, pid: UInt)
}
