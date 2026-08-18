import Foundation

@MainActor
public protocol VirtualMachineBackend: AnyObject {
    var id: String { get }
    var name: String { get }
    var templates: [VirtualMachineTemplate] { get }

    func availability(for template: VirtualMachineTemplate) -> VirtualMachineAvailability
    func launch(_ request: VirtualMachineLaunchRequest) async throws -> any VirtualMachine
}

public enum VirtualMachineAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        self == .available
    }

    public var reason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

public struct VirtualMachineLaunchRequest: Sendable {
    public let id: UUID
    public let template: VirtualMachineTemplate
    public let name: String
    public let parameters: [String: VirtualMachineParameterValue]
    public let agentPath: URL?
    public let storageDirectory: URL
    public let resumesFromReadySnapshot: Bool

    public init(
        id: UUID,
        template: VirtualMachineTemplate,
        name: String,
        parameters: [String: VirtualMachineParameterValue],
        agentPath: URL?,
        storageDirectory: URL,
        resumesFromReadySnapshot: Bool
    ) {
        self.id = id
        self.template = template
        self.name = name
        self.parameters = parameters
        self.agentPath = agentPath
        self.storageDirectory = storageDirectory
        self.resumesFromReadySnapshot = resumesFromReadySnapshot
    }

    public func text(_ id: String) -> String? {
        parameters[id]?.text
    }

    public func number(_ id: String) -> Int? {
        parameters[id]?.number
    }

    public func toggle(_ id: String) -> Bool? {
        parameters[id]?.toggle
    }
}

public enum VirtualMachineError: Swift.Error, LocalizedError {
    case launchFailed(reason: String)
    case snapshotFailed(reason: String)
    case displayUnavailable(reason: String)

    /// An error that already says it could not start the machine is passed on
    /// as it is, rather than being wrapped in the same words twice.
    static func launchFailure(_ reason: String, from error: Swift.Error) -> VirtualMachineError {
        (error as? VirtualMachineError) ?? .launchFailed(reason: reason)
    }

    public var reason: String {
        switch self {
        case .launchFailed(let reason), .snapshotFailed(let reason), .displayUnavailable(let reason):
            return reason
        }
    }

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Unable to start the machine: \(reason)"
        case .snapshotFailed(let reason):
            return "Unable to snapshot the machine: \(reason)"
        case .displayUnavailable(let reason):
            return "Unable to show the machine's display: \(reason)"
        }
    }
}
