import Foundation

/// Body of a content block in our internal (provider-agnostic) representation.
/// The shape mirrors Anthropic's content blocks because it's the most
/// expressive of the three providers we support; OpenAI and OpenAI-compatible
/// adapters translate to/from this shape.
public struct LLMAttachment: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case image
    }

    public var kind: Kind
    public var mediaType: String
    public var base64: String

    public init(kind: Kind, mediaType: String, base64: String) {
        self.kind = kind
        self.mediaType = mediaType
        self.base64 = base64
    }
}

public enum LLMContent: Sendable, Codable, Hashable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseID: String, contentJSON: String, isError: Bool, attachments: [LLMAttachment])
    case thinking(text: String, signature: String)
    case redactedThinking(data: String)

    private enum Kind: String, Codable {
        case text
        case toolUse = "tool_use"
        case toolResult = "tool_result"
        case thinking
        case redactedThinking = "redacted_thinking"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case id
        case name
        case input = "input_json"
        case toolUseID = "tool_use_id"
        case content = "content_json"
        case isError = "is_error"
        case attachments
        case signature
        case data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                inputJSON: try c.decode(String.self, forKey: .input)
            )
        case .toolResult:
            self = .toolResult(
                toolUseID: try c.decode(String.self, forKey: .toolUseID),
                contentJSON: try c.decode(String.self, forKey: .content),
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
                attachments: try c.decodeIfPresent([LLMAttachment].self, forKey: .attachments) ?? []
            )
        case .thinking:
            self = .thinking(
                text: try c.decode(String.self, forKey: .text),
                signature: try c.decodeIfPresent(String.self, forKey: .signature) ?? ""
            )
        case .redactedThinking:
            self = .redactedThinking(data: try c.decode(String.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let id, let content, let isError, let attachments):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(id, forKey: .toolUseID)
            try c.encode(content, forKey: .content)
            if isError { try c.encode(true, forKey: .isError) }
            if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        case .thinking(let text, let signature):
            try c.encode(Kind.thinking, forKey: .kind)
            try c.encode(text, forKey: .text)
            if !signature.isEmpty { try c.encode(signature, forKey: .signature) }
        case .redactedThinking(let data):
            try c.encode(Kind.redactedThinking, forKey: .kind)
            try c.encode(data, forKey: .data)
        }
    }
}

public struct LLMContentBlock: Sendable, Codable, Hashable {
    public var content: LLMContent
    public var cacheBoundary: Bool

    public init(content: LLMContent, cacheBoundary: Bool = false) {
        self.content = content
        self.cacheBoundary = cacheBoundary
    }

    public static func text(_ text: String, cacheBoundary: Bool = false) -> LLMContentBlock {
        LLMContentBlock(content: .text(text), cacheBoundary: cacheBoundary)
    }
}

public enum LLMRole: String, Sendable, Codable {
    case user
    case assistant
}

public struct LLMMessage: Sendable, Codable, Hashable {
    public var role: LLMRole
    public var blocks: [LLMContentBlock]

    public init(role: LLMRole, blocks: [LLMContentBlock]) {
        self.role = role
        self.blocks = blocks
    }
}

public struct LLMToolSpec: Sendable, Codable, Hashable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
    public var cacheBoundary: Bool

    public init(name: String, description: String, inputSchemaJSON: String, cacheBoundary: Bool = false) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.cacheBoundary = cacheBoundary
    }
}

public struct LLMUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreateTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreateTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreateTokens = cacheCreateTokens
    }

    public static let zero = LLMUsage()
}

public enum LLMStopReason: String, Sendable, Codable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case toolUse = "tool_use"
    case stopSequence = "stop_sequence"
    case refusal
    case error
    case cancelled
}

public struct LLMTurnRequest: Sendable {
    public var modelID: String
    public var systemBlocks: [LLMContentBlock]
    public var messages: [LLMMessage]
    public var tools: [LLMToolSpec]
    public var maxOutputTokens: Int
    public var thinkingBudget: Int
    public var reasoningEffort: String?
    public var temperature: Double?
    public var mission: Mission?

    public init(
        modelID: String,
        systemBlocks: [LLMContentBlock],
        messages: [LLMMessage],
        tools: [LLMToolSpec],
        maxOutputTokens: Int,
        thinkingBudget: Int = 0,
        reasoningEffort: String? = nil,
        temperature: Double? = nil,
        mission: Mission? = nil
    ) {
        self.modelID = modelID
        self.systemBlocks = systemBlocks
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.thinkingBudget = thinkingBudget
        self.reasoningEffort = reasoningEffort
        self.temperature = temperature
        self.mission = mission
    }
}

public enum LLMTurnEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolUseStarted(id: String, name: String)
    case toolUseInputDelta(id: String, partialJSON: String)
    case toolUseCompleted(id: String, name: String, inputJSON: String)
    case usage(LLMUsage)
    case messageStop(LLMStopReason)
    case finalMessage(role: LLMRole, blocks: [LLMContentBlock])
    case liveTextCleared
}

public enum LLMProviderError: LocalizedError, Sendable {
    case missingAPIKey
    case requestFailed(status: Int, message: String)
    case decodingFailed(String)
    case streamInterrupted
    case capabilityUnsupported(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Provider requires an API key but none is configured."
        case .requestFailed(let status, let message):
            let trimmed = message.prefix(500)
            if status >= 0 {
                return "Provider request failed (status \(status)): \(trimmed)"
            }
            return "Provider request failed: \(trimmed)"
        case .decodingFailed(let detail):
            return "Provider response could not be decoded: \(detail)"
        case .streamInterrupted:
            return "Provider stream ended unexpectedly."
        case .capabilityUnsupported(let detail):
            return "Capability not supported: \(detail)"
        case .cancelled:
            return "Cancelled."
        }
    }
}

public struct LLMModelInfo: Sendable, Hashable, Codable {
    public var id: String
    public var displayName: String
    public var contextWindow: Int
    public var maxOutput: Int
    public var capabilities: Set<LLMCapability>

    public init(
        id: String,
        displayName: String,
        contextWindow: Int,
        maxOutput: Int,
        capabilities: Set<LLMCapability> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.capabilities = capabilities
    }

    public func supports(_ capability: LLMCapability) -> Bool {
        capabilities.contains(capability)
    }
}
