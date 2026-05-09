import Foundation
import GRDB

public struct MissionTarget: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mission_target"

    public var missionID: UUID
    public var sessionID: UUID

    enum CodingKeys: String, CodingKey {
        case missionID = "mission_id"
        case sessionID = "session_id"
    }

    public init(missionID: UUID, sessionID: UUID) {
        self.missionID = missionID
        self.sessionID = sessionID
    }
}
