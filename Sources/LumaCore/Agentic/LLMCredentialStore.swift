import Foundation

public struct LLMCredentialStore: Sendable {
    public let backing: TokenStore

    public init(backing: TokenStore) {
        self.backing = backing
    }

    public func apiKey(providerID: String, account: String = "default") async throws -> String? {
        try await backing.get(service: serviceName(for: providerID), account: account)
    }

    public func setAPIKey(_ key: String, providerID: String, account: String = "default") async throws {
        try await backing.set(service: serviceName(for: providerID), account: account, token: key)
    }

    public func deleteAPIKey(providerID: String, account: String = "default") async throws {
        try await backing.delete(service: serviceName(for: providerID), account: account)
    }

    private func serviceName(for providerID: String) -> String {
        "luma.llm.\(providerID)"
    }
}
