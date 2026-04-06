import Foundation
import GRDB

public struct ProjectCollaborationState: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_collaboration_state"

    public var id: UUID
    public var roomID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case roomID = "room_id"
    }

    public init(id: UUID = UUID(), roomID: String? = nil) {
        self.id = id
        self.roomID = roomID
    }
}
