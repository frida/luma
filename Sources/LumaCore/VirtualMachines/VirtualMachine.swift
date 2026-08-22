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
    case hostlink(qmpSocket: URL, bus: String?, ecam: UInt64?)
    case vsock(socketPath: URL, port: UInt)
}

public enum BareboneDebugStub: Sendable, Equatable {
    case gdbRemote(host: String, port: UInt16)
    case virtualization(pid: UInt)
}
