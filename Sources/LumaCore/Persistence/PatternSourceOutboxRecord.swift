import Foundation
import GRDB

struct PatternSourceOutboxRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pattern_source_outbox"

    var opID: String
    var kind: String
    var sourceID: String
    var payloadJSON: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case kind
        case sourceID = "source_id"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }

    init(_ op: PatternSourceOp) throws {
        let data = try JSONSerialization.data(withJSONObject: op.toJSON(), options: [.sortedKeys])
        opID = op.opID.uuidString
        kind = op.kind
        sourceID = op.sourceID.uuidString
        payloadJSON = String(decoding: data, as: UTF8.self)
        createdAt = Date()
    }

    func toOp() -> PatternSourceOp? {
        guard let data = payloadJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return PatternSourceOp.fromJSON(obj)
    }
}
