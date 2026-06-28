import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LocalOpenAICompatibleProvider: LLMProvider {
    public static let providerID = "local"
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!

    public let descriptor: LLMProviderDescriptor
    private let session: URLSession

    public init(session: URLSession = .shared, baseURL: URL = LocalOpenAICompatibleProvider.defaultBaseURL) {
        self.session = session
        self.descriptor = LLMProviderDescriptor(
            id: Self.providerID,
            displayName: "Local (OpenAI-compatible)",
            capabilities: LLMProviderCapabilities(
                supported: [.streaming, .toolUse, .customBaseURL, .optionalAPIKey]
            ),
            defaultModelID: nil,
            summarizationModelID: nil,
            defaultBaseURL: baseURL
        )
    }

    public func suggestedModels(apiKey: String?, baseURL: URL?) async throws -> [LLMModelInfo] {
        try await fetchOpenAICompatibleModels(
            session: session,
            baseURL: baseURL ?? descriptor.defaultBaseURL,
            apiKey: apiKey
        )
    }

    public func streamTurn(
        _ request: LLMTurnRequest,
        apiKey: String?,
        baseURL: URL?
    ) -> AsyncThrowingStream<LLMTurnEvent, Error> {
        runOpenAICompatibleStream(
            request: request,
            apiKey: apiKey,
            baseURL: baseURL ?? descriptor.defaultBaseURL,
            session: session,
            requiresAPIKey: descriptor.capabilities.supports(.apiKey)
        )
    }
}

public struct OpenAICompatibleURLProvider: LLMProvider {
    public static let providerID = "openai-compatible"
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!

    public let descriptor: LLMProviderDescriptor
    private let session: URLSession

    public init(session: URLSession = .shared, baseURL: URL = OpenAICompatibleURLProvider.defaultBaseURL) {
        self.session = session
        self.descriptor = LLMProviderDescriptor(
            id: Self.providerID,
            displayName: "OpenAI-compatible URL",
            capabilities: LLMProviderCapabilities(
                supported: [.streaming, .toolUse, .customBaseURL, .optionalAPIKey]
            ),
            defaultModelID: nil,
            summarizationModelID: nil,
            defaultBaseURL: baseURL
        )
    }

    public func suggestedModels(apiKey: String?, baseURL: URL?) async throws -> [LLMModelInfo] {
        try await fetchOpenAICompatibleModels(
            session: session,
            baseURL: baseURL ?? descriptor.defaultBaseURL,
            apiKey: apiKey
        )
    }

    public func streamTurn(
        _ request: LLMTurnRequest,
        apiKey: String?,
        baseURL: URL?
    ) -> AsyncThrowingStream<LLMTurnEvent, Error> {
        runOpenAICompatibleStream(
            request: request,
            apiKey: apiKey,
            baseURL: baseURL ?? descriptor.defaultBaseURL,
            session: session,
            requiresAPIKey: descriptor.capabilities.supports(.apiKey)
        )
    }
}
