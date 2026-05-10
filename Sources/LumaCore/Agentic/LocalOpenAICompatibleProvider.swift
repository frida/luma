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
                supportsStreaming: true,
                supportsPromptCaching: false,
                supportsThinking: false,
                supportsToolUse: true,
                requiresAPIKey: false,
                supportsCustomBaseURL: true
            ),
            defaultModelID: "gpt-oss:20b",
            summarizationModelID: "llama3.2:3b",
            defaultBaseURL: baseURL
        )
    }

    public func suggestedModels() -> [LLMModelInfo] {
        [
            LLMModelInfo(id: "gpt-oss:20b", displayName: "gpt-oss 20B", contextWindow: 128_000, maxOutput: 16_384, supportsCaching: false, supportsThinking: false),
            LLMModelInfo(id: "qwen2.5-coder:14b", displayName: "Qwen 2.5 Coder 14B", contextWindow: 128_000, maxOutput: 16_384, supportsCaching: false, supportsThinking: false),
            LLMModelInfo(id: "llama3.2:3b", displayName: "Llama 3.2 3B", contextWindow: 128_000, maxOutput: 8_192, supportsCaching: false, supportsThinking: false),
            LLMModelInfo(id: "mannix/jan-nano", displayName: "Jan Nano", contextWindow: 32_768, maxOutput: 8_192, supportsCaching: false, supportsThinking: false),
        ]
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
            requiresAPIKey: descriptor.capabilities.requiresAPIKey
        )
    }
}
