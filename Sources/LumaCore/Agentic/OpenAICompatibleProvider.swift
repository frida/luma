import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAICompatibleProvider: LLMProvider {
    public let descriptor: LLMProviderDescriptor
    private let session: URLSession

    public init(id: String, displayName: String, baseURL: URL, session: URLSession = .shared) {
        self.session = session
        self.descriptor = LLMProviderDescriptor(
            id: id,
            displayName: displayName,
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

extension OpenAICompatibleProvider {
    private static let ollamaBaseURL = URL(string: "http://localhost:11434")!

    public static func local(session: URLSession = .shared) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            id: "local",
            displayName: "Local (OpenAI-compatible)",
            baseURL: ollamaBaseURL,
            session: session
        )
    }

    public static func remote(session: URLSession = .shared) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            id: "openai-compatible",
            displayName: "OpenAI-compatible URL",
            baseURL: ollamaBaseURL,
            session: session
        )
    }
}
