import Foundation

public struct LLMProviderCapabilities: Sendable, Hashable {
    public var supportsStreaming: Bool
    public var supportsPromptCaching: Bool
    public var supportsThinking: Bool
    public var supportsToolUse: Bool
    public var requiresAPIKey: Bool
    public var supportsCustomBaseURL: Bool

    public init(
        supportsStreaming: Bool,
        supportsPromptCaching: Bool,
        supportsThinking: Bool,
        supportsToolUse: Bool,
        requiresAPIKey: Bool,
        supportsCustomBaseURL: Bool
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsPromptCaching = supportsPromptCaching
        self.supportsThinking = supportsThinking
        self.supportsToolUse = supportsToolUse
        self.requiresAPIKey = requiresAPIKey
        self.supportsCustomBaseURL = supportsCustomBaseURL
    }
}

public struct LLMProviderDescriptor: Sendable, Hashable {
    public var id: String
    public var displayName: String
    public var capabilities: LLMProviderCapabilities
    public var defaultModelID: String?
    public var summarizationModelID: String?
    public var defaultBaseURL: URL

    public init(
        id: String,
        displayName: String,
        capabilities: LLMProviderCapabilities,
        defaultModelID: String?,
        summarizationModelID: String? = nil,
        defaultBaseURL: URL
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.defaultModelID = defaultModelID
        self.summarizationModelID = summarizationModelID
        self.defaultBaseURL = defaultBaseURL
    }
}

public protocol LLMProvider: Sendable {
    var descriptor: LLMProviderDescriptor { get }

    func streamTurn(
        _ request: LLMTurnRequest,
        apiKey: String?,
        baseURL: URL?
    ) -> AsyncThrowingStream<LLMTurnEvent, Error>

    func suggestedModels() -> [LLMModelInfo]
}

@MainActor
public final class LLMProviderRegistry {
    private var providersByID: [String: any LLMProvider] = [:]
    private var orderedIDs: [String] = []

    public init() {}

    public func register(_ provider: any LLMProvider) {
        let id = provider.descriptor.id
        if providersByID[id] == nil {
            orderedIDs.append(id)
        }
        providersByID[id] = provider
    }

    public func provider(id: String) -> (any LLMProvider)? {
        providersByID[id]
    }

    public func providers() -> [any LLMProvider] {
        orderedIDs.compactMap { providersByID[$0] }
    }

    public func descriptors() -> [LLMProviderDescriptor] {
        providers().map(\.descriptor)
    }
}
