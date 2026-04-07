import Foundation

public enum NavigationTarget: Sendable, Hashable {
    case instrumentComponent(sessionID: UUID, instrumentID: UUID, componentID: UUID)
}

public struct AddressAction: Identifiable, Sendable {
    public enum Role: Sendable {
        case normal
        case destructive
    }

    public let id: UUID
    public let title: String
    public let systemImage: String?
    public let role: Role
    public let perform: @MainActor @Sendable () async -> NavigationTarget?

    public init(
        id: UUID = UUID(),
        title: String,
        systemImage: String? = nil,
        role: Role = .normal,
        perform: @escaping @MainActor @Sendable () async -> NavigationTarget?
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.perform = perform
    }
}

public typealias AddressActionProvider = @MainActor @Sendable (_ sessionID: UUID, _ address: UInt64) -> [AddressAction]
