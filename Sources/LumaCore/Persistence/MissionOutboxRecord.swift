import Foundation
import GRDB

struct MissionOutboxRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mission_outbox"

    var opID: String
    var kind: String
    var missionID: String
    var payloadJSON: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case kind
        case missionID = "mission_id"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }

    func toOp() -> MissionOp? {
        guard let data = payloadJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return MissionOp.fromJSON(obj)
    }
}
