import Foundation
import GRDB

public struct ObjectChatMessage: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "object_chat_message"

    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public var id: UUID
    public var chatID: UUID
    public var index: Int
    public var role: Role
    public var author: Author?
    public var bodyMarkdown: String
    public var replyTo: UUID?
    public var asksAssistant: Bool
    public var providerID: String?
    public var modelID: String?
    public var error: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreateTokens: Int
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case chatID = "chat_id"
        case index
        case role
        case author
        case bodyMarkdown = "body_markdown"
        case replyTo = "reply_to"
        case asksAssistant = "asks_assistant"
        case providerID = "provider_id"
        case modelID = "model_id"
        case error
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheCreateTokens = "cache_create_tokens"
        case createdAt = "created_at"
    }

    public init(
        id: UUID = UUID(),
        chatID: UUID,
        index: Int,
        role: Role,
        author: Author?,
        bodyMarkdown: String,
        replyTo: UUID? = nil,
        asksAssistant: Bool = false,
        providerID: String? = nil,
        modelID: String? = nil,
        error: String? = nil,
        usage: LLMUsage = .zero
    ) {
        self.id = id
        self.chatID = chatID
        self.index = index
        self.role = role
        self.author = author
        self.bodyMarkdown = bodyMarkdown
        self.replyTo = replyTo
        self.asksAssistant = asksAssistant
        self.providerID = providerID
        self.modelID = modelID
        self.error = error
        self.inputTokens = usage.inputTokens
        self.outputTokens = usage.outputTokens
        self.cacheReadTokens = usage.cacheReadTokens
        self.cacheCreateTokens = usage.cacheCreateTokens
        self.createdAt = Date()
    }
}
