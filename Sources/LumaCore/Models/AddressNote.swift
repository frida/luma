import Foundation
import GRDB

public struct AddressNote: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "address_note"

    public var id: UUID
    public var sessionID: UUID
    public var anchor: AddressAnchor
    public var title: String?
    public var editors: [Author]
    public var createdAt: Date
    public var updatedAt: Date

    public var author: Author? { editors.first }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case anchor
        case title
        case editors
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        anchor: AddressAnchor,
        title: String? = nil,
        editors: [Author] = []
    ) {
        let now = Date()
        self.id = id
        self.sessionID = sessionID
        self.anchor = anchor
        self.title = title
        self.editors = editors
        self.createdAt = now
        self.updatedAt = now
    }
}
