import Foundation
import GRDB

/// Row in `session_outbox`. Backs ProjectStore's pending session-ops queue:
/// each row is a serialized SessionOp awaiting delivery to the server.
struct SessionOutboxRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session_outbox"

    var opID: String
    var kind: String
    var sessionID: String
    var payloadJSON: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case kind
        case sessionID = "session_id"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }

    func toOp() -> SessionOp? {
        guard let data = payloadJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sid = UUID(uuidString: sessionID)
        else { return nil }
        return SessionOp.fromJSON(obj, sessionID: sid)
    }
}
