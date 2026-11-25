import Foundation

public enum ObjectChatSubjectPlace: Sendable, Equatable {
    case project
    case instruction(ObjectChatInstructionPlace)
    case object(origin: ObjectChat.Origin, label: String)
}

public struct ObjectChatInstructionPlace: Sendable, Equatable {
    public let sessionID: UUID
    public let anchor: AddressAnchor
    public let address: UInt64?
    public let sessionName: String?
    public let presence: SessionPresence

    public var unavailableReason: String? {
        if presence == .unknown {
            return "The session this instruction is in is not in the project."
        }
        if address == nil {
            return "The module of \(anchor.displayString) is not known in \(sessionName ?? "the session")."
        }
        return nil
    }
}
