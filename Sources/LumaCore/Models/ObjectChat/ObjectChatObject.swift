import Foundation
import GRDB

public struct ObjectChatObject: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "object_chat_object"

    public var chatID: UUID
    public var objectID: String
    public var name: String?
    public var className: String
    public var printString: String
    public var snapshot: PharoSnapshot?
    public var producedBy: UUID?
    public var standsFor: String?
    public var addedBy: Author?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { objectID }

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case objectID = "object_id"
        case name
        case className = "class_name"
        case printString = "print_string"
        case snapshot
        case producedBy = "produced_by"
        case standsFor = "stands_for"
        case addedBy = "added_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        chatID: UUID,
        objectID: String,
        name: String?,
        className: String,
        printString: String,
        snapshot: PharoSnapshot?,
        producedBy: UUID?,
        standsFor: String?,
        addedBy: Author?
    ) {
        let now = Date()
        self.chatID = chatID
        self.objectID = objectID
        self.name = name
        self.className = className
        self.printString = printString
        self.snapshot = snapshot
        self.producedBy = producedBy
        self.standsFor = standsFor
        self.addedBy = addedBy
        self.createdAt = now
        self.updatedAt = now
    }
}
