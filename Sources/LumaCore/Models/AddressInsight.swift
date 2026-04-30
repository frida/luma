import Foundation
import GRDB

public struct AddressInsight: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "address_insight"

    public var id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    public var title: String
    public var kind: Kind
    public var anchor: AddressAnchor
    public var byteCount: Int
    public var lastResolvedAddress: UInt64?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case createdAt = "created_at"
        case title
        case kind
        case anchor
        case byteCount = "byte_count"
        case lastResolvedAddress = "last_resolved_address"
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        title: String,
        kind: Kind,
        anchor: AddressAnchor,
        byteCount: Int = 0x200
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = Date()
        self.title = title
        self.kind = kind
        self.anchor = anchor
        self.byteCount = byteCount
    }

    public enum Kind: Int, Codable, Sendable {
        case memory
        case disassembly
    }

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
