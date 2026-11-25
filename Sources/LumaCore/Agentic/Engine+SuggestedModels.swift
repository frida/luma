import Foundation

extension Engine {
    public func suggestedModels(providerID: String) async throws -> [LLMModelInfo] {
        let provider = llmRegistry.provider(id: providerID)!
        let apiKey = try? await llmCredentials.apiKey(providerID: providerID)
        let baseURL = LumaAppState.shared.providerBaseURL(providerID: providerID).flatMap(URL.init(string:))
        return try await provider.suggestedModels(apiKey: apiKey, baseURL: baseURL)
    }
}
