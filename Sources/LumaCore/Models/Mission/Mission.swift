import Foundation
import GRDB

public struct Mission: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mission"

    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var goalText: String
    public var status: MissionStatus
    public var providerID: String
    public var modelID: String
    public var systemPromptHash: String?
    public var tokenBudgetInput: Int
    public var tokenBudgetOutput: Int
    public var tokensUsedInput: Int
    public var tokensUsedOutput: Int
    public var cacheReadTokens: Int
    public var cacheCreateTokens: Int
    public var thinkingBudget: Int
    public var temperature: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case goalText = "goal_text"
        case status
        case providerID = "provider_id"
        case modelID = "model_id"
        case systemPromptHash = "system_prompt_hash"
        case tokenBudgetInput = "token_budget_input"
        case tokenBudgetOutput = "token_budget_output"
        case tokensUsedInput = "tokens_used_input"
        case tokensUsedOutput = "tokens_used_output"
        case cacheReadTokens = "cache_read_tokens"
        case cacheCreateTokens = "cache_create_tokens"
        case thinkingBudget = "thinking_budget"
        case temperature
    }

    public init(
        id: UUID = UUID(),
        goalText: String,
        providerID: String,
        modelID: String,
        tokenBudgetInput: Int,
        tokenBudgetOutput: Int,
        thinkingBudget: Int = 0,
        temperature: Double? = nil
    ) {
        let now = Date()
        self.id = id
        self.createdAt = now
        self.updatedAt = now
        self.goalText = goalText
        self.status = .drafting
        self.providerID = providerID
        self.modelID = modelID
        self.systemPromptHash = nil
        self.tokenBudgetInput = tokenBudgetInput
        self.tokenBudgetOutput = tokenBudgetOutput
        self.tokensUsedInput = 0
        self.tokensUsedOutput = 0
        self.cacheReadTokens = 0
        self.cacheCreateTokens = 0
        self.thinkingBudget = thinkingBudget
        self.temperature = temperature
    }
}
