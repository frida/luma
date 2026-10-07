import Foundation
import GRDB

public struct PatternSourceRecord: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pattern_source"

    public var id: UUID
    public var name: String
    public var kind: PatternSource.Kind
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case text
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(id: UUID = UUID(), name: String, kind: PatternSource.Kind, text: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var fileName: String {
        name + "." + kind.fileExtension
    }
}
