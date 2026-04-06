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
}
