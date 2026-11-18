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

    public func toWireJSON() -> [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "kind": kind.rawValue,
            "text": text,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "updated_at": ISO8601DateFormatter().string(from: updatedAt),
        ]
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> PatternSourceRecord? {
        guard let id = (obj["id"] as? String).flatMap(UUID.init(uuidString:)),
            let name = obj["name"] as? String,
            let kind = (obj["kind"] as? String).flatMap(PatternSource.Kind.init(rawValue:)),
            let text = obj["text"] as? String
        else { return nil }
        let dates = ISO8601DateFormatter()
        let createdAt = (obj["created_at"] as? String).flatMap(dates.date(from:)) ?? Date()
        let updatedAt = (obj["updated_at"] as? String).flatMap(dates.date(from:)) ?? createdAt
        return PatternSourceRecord(id: id, name: name, kind: kind, text: text, createdAt: createdAt, updatedAt: updatedAt)
    }
}
