import Foundation
import GRDB

public struct ProjectCollaborationState: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_collaboration_state"

    private var id = 1
    public var labID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case labID = "lab_id"
    }

    public init(labID: String? = nil) {
        self.labID = labID
    }
}
