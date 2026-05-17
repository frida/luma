import Foundation
import GRDB

public struct AddressNoteMessage: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "address_note_message"

    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    public var id: UUID
    public var noteID: UUID
    public var index: Int
    public var role: Role
    public var author: Author?
    public var bodyMarkdown: String
    public var providerID: String?
    public var modelID: String?
    public var actionID: UUID?
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case noteID = "note_id"
        case index
        case role
        case author
        case bodyMarkdown = "body_markdown"
        case providerID = "provider_id"
        case modelID = "model_id"
        case actionID = "action_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID = UUID(),
        noteID: UUID,
        index: Int,
        role: Role,
        author: Author? = nil,
        bodyMarkdown: String,
        providerID: String? = nil,
        modelID: String? = nil,
        actionID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.noteID = noteID
        self.index = index
        self.role = role
        self.author = author
        self.bodyMarkdown = bodyMarkdown
        self.providerID = providerID
        self.modelID = modelID
        self.actionID = actionID
        self.createdAt = createdAt
    }
}
