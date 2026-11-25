import Foundation

public enum LLMCapability: String, Sendable, Hashable, CaseIterable, Codable {
    case streaming
    case promptCaching
    case thinking
    case toolUse
    case apiKey
    case optionalAPIKey
    case customBaseURL
}

public struct LLMProviderCapabilities: Sendable, Hashable {
    public var supported: Set<LLMCapability>
    public var reasoningEffortOptions: [String]
    public var defaultReasoningEffort: String?

    public init(
        supported: Set<LLMCapability> = [],
        reasoningEffortOptions: [String] = [],
        defaultReasoningEffort: String? = nil
    ) {
        self.supported = supported
        self.reasoningEffortOptions = reasoningEffortOptions
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    public func supports(_ capability: LLMCapability) -> Bool {
        supported.contains(capability)
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

    func suggestedModels(apiKey: String?, baseURL: URL?) async throws -> [LLMModelInfo]

    func unavailableReason() -> String?
}

extension LLMProvider {
    public func unavailableReason() -> String? {
        nil
    }
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
