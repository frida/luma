import Foundation

public struct ProjectCollaborationState: Codable, Identifiable, Sendable {
    public var id: UUID
    public var roomID: String?

    public init(id: UUID = UUID(), roomID: String? = nil) {
        self.id = id
        self.roomID = roomID
    }
}
