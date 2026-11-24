import Foundation
import GRDB

public struct ObjectChatToolCall: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "object_chat_tool_call"

    public enum Status: String, Codable, Sendable {
        case proposed
        case running
        case succeeded
        case failed
        case rejected
    }

    public var id: UUID
    public var chatID: UUID
    public var messageID: UUID
    public var replyTo: UUID
    public var offset: Int
    public var index: Int
    public var toolCallID: String
    public var tool: String
    public var args: [String: JSONValue]
    public var askedBy: Author?
    public var executor: Author?
    public var status: Status
    public var summary: String?
    public var result: String?
    public var error: String?
    public var errorPosition: Int?
    public var objectID: String?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case chatID = "chat_id"
        case messageID = "message_id"
        case replyTo = "reply_to"
        case offset
        case index
        case toolCallID = "tool_call_id"
        case tool
        case args
        case askedBy = "asked_by"
        case executor
        case status
        case summary
        case result
        case error
        case errorPosition = "error_position"
        case objectID = "object_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func precedes(_ a: ObjectChatToolCall, _ b: ObjectChatToolCall) -> Bool {
        (a.wireSecond, a.messageID.uuidString, a.index, a.id.uuidString) < (b.wireSecond, b.messageID.uuidString, b.index, b.id.uuidString)
    }

    private var wireSecond: Int64 {
        Int64(createdAt.timeIntervalSince1970.rounded(.down))
    }

    public init(
        chatID: UUID,
        messageID: UUID,
        replyTo: UUID,
        offset: Int,
        index: Int,
        toolCallID: String,
        tool: String,
        args: [String: JSONValue],
        askedBy: Author?,
        executor: Author?,
        status: Status
    ) {
        let now = Date()
        self.id = UUID()
        self.chatID = chatID
        self.messageID = messageID
        self.replyTo = replyTo
        self.offset = offset
        self.index = index
        self.toolCallID = toolCallID
        self.tool = tool
        self.args = args
        self.askedBy = askedBy
        self.executor = executor
        self.status = status
        self.createdAt = now
        self.updatedAt = now
    }

    public var isSettled: Bool {
        switch status {
        case .succeeded, .failed, .rejected: true
        case .proposed, .running: false
        }
    }
}
