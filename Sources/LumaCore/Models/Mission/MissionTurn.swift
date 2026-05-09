import Foundation
import GRDB

public struct MissionTurn: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mission_turn"

    public var id: UUID
    public var missionID: UUID
    public var index: Int
    public var createdAt: Date
    public var role: MissionTurnRole
    public var contentJSON: String
    public var modelID: String?
    public var stopReason: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreateTokens: Int

    enum CodingKeys: String, CodingKey {
        case id
        case missionID = "mission_id"
        case index
        case createdAt = "created_at"
        case role
        case contentJSON = "content_json"
        case modelID = "model_id"
        case stopReason = "stop_reason"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheCreateTokens = "cache_create_tokens"
    }

    public init(
        id: UUID = UUID(),
        missionID: UUID,
        index: Int,
        role: MissionTurnRole,
        contentJSON: String,
        modelID: String? = nil,
        stopReason: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreateTokens: Int = 0
    ) {
        self.id = id
        self.missionID = missionID
        self.index = index
        self.createdAt = Date()
        self.role = role
        self.contentJSON = contentJSON
        self.modelID = modelID
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreateTokens = cacheCreateTokens
    }
}
