import Foundation
import GRDB

public struct AddressInsight: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "address_insight"

    public var id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    public var userTitle: String?
    public var kind: Kind
    public var anchor: AddressAnchor
    public var byteCount: Int
    public var lastResolvedAddress: UInt64?
    public var parentInsightID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case createdAt = "created_at"
        case userTitle = "user_title"
        case kind
        case anchor
        case byteCount = "byte_count"
        case lastResolvedAddress = "last_resolved_address"
        case parentInsightID = "parent_insight_id"
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        userTitle: String? = nil,
        kind: Kind,
        anchor: AddressAnchor,
        byteCount: Int = 0x200,
        parentInsightID: UUID? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = Date()
        self.userTitle = userTitle
        self.kind = kind
        self.anchor = anchor
        self.byteCount = byteCount
        self.parentInsightID = parentInsightID
    }

    public enum Kind: Int, Codable, Sendable, DatabaseValueConvertible {
        case memory
        case disassembly
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["session_id"] = sessionID
        container["created_at"] = createdAt
        container["user_title"] = userTitle
        container["kind"] = kind
        container["anchor"] = try Self.anchorEncoder.encode(anchor)
        container["byte_count"] = byteCount
        container["last_resolved_address"] = lastResolvedAddress.map(Int64.init(bitPattern:))
        container["parent_insight_id"] = parentInsightID
    }

    public init(row: Row) throws {
        id = row["id"]
        sessionID = row["session_id"]
        createdAt = row["created_at"]
        userTitle = row["user_title"]
        kind = row["kind"]
        anchor = try Self.anchorDecoder.decode(AddressAnchor.self, from: row["anchor"])
        byteCount = row["byte_count"]
        let storedAddress: Int64? = row["last_resolved_address"]
        lastResolvedAddress = storedAddress.map(UInt64.init(bitPattern:))
        parentInsightID = row["parent_insight_id"]
    }

    private static let anchorEncoder = JSONEncoder()

    private static let anchorDecoder = JSONDecoder()

    private static let wireEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let wireDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func toWireJSON() -> [String: Any]? {
        guard let data = try? Self.wireEncoder.encode(self),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> AddressInsight? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
            let insight = try? wireDecoder.decode(AddressInsight.self, from: data)
        else { return nil }
        return insight
    }
}
