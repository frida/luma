import Foundation
import GRDB

struct AddressNoteOutboxRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "address_note_outbox"

    var opID: String
    var kind: String
    var noteID: String
    var payloadJSON: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case kind
        case noteID = "note_id"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }

    func toOp() -> AddressNoteOp? {
        guard let data = payloadJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return AddressNoteOp.fromJSON(obj)
    }
}
