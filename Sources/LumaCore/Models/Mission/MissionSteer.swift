import Foundation
import GRDB

public struct MissionSteer: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mission_steer"

    public var id: UUID
    public var missionID: UUID
    public var author: Author?
    public var text: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case missionID = "mission_id"
        case author
        case text
        case createdAt = "created_at"
    }

    public static func precedes(_ a: MissionSteer, _ b: MissionSteer) -> Bool {
        (a.createdAt, a.id.uuidString) < (b.createdAt, b.id.uuidString)
    }

    public init(id: UUID = UUID(), missionID: UUID, author: Author?, text: String) {
        self.id = id
        self.missionID = missionID
        self.author = author
        self.text = text
        self.createdAt = Date()
    }

    public func toWireJSON() -> [String: Any]? {
        encodeRow(self)
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> MissionSteer? {
        decodeRow(obj)
    }
}
