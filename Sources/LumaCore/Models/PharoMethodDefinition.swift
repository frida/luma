import Foundation
import GRDB

public struct PharoMethodDefinition: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pharo_method"

    public var className: String
    public var side: String
    public var selector: String
    public var category: String
    public var source: String
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case className = "class_name"
        case side
        case selector
        case category
        case source
        case updatedAt = "updated_at"
    }

    public init(className: String, side: String, selector: String, category: String, source: String, updatedAt: Date = .now) {
        self.className = className
        self.side = side
        self.selector = selector
        self.category = category
        self.source = source
        self.updatedAt = updatedAt
    }
}
