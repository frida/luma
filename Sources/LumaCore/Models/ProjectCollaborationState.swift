import Foundation
import GRDB

public struct ProjectCollaborationState: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_collaboration_state"

    public var id: UUID
    public var labID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case labID = "lab_id"
    }

    public init(id: UUID = UUID(), labID: String? = nil) {
        self.id = id
        self.labID = labID
    }
}
