import Foundation
import GRDB

public struct LabMembership: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lab_membership"

    public var labID: String
    public var user: CollaborationSession.UserInfo
    public var role: CollaborationSession.Member.Role

    enum CodingKeys: String, CodingKey {
        case labID = "lab_id"
        case user
        case role
    }

    public init(labID: String, user: CollaborationSession.UserInfo, role: CollaborationSession.Member.Role) {
        self.labID = labID
        self.user = user
        self.role = role
    }
}
