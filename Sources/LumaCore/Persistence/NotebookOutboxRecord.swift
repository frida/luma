import Foundation
import GRDB

/// Row in `notebook_outbox`. Backs ProjectStore's pending-ops queue: each
/// row is a serialized NotebookOp awaiting delivery to the server.
struct NotebookOutboxRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notebook_outbox"

    var opID: String
    var kind: String
    var entryID: String
    var payloadJSON: String
    var binaryData: Data?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case kind
        case entryID = "entry_id"
        case payloadJSON = "payload_json"
        case binaryData = "binary_data"
        case createdAt = "created_at"
    }

    func toOp() -> NotebookOp? {
        guard let data = payloadJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let bin = binaryData.map { Array<UInt8>($0) }
        return NotebookOp.fromJSON(obj, binaryData: bin)
    }
}
