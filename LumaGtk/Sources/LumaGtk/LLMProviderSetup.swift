import Foundation
import LumaCore
import Observation

@MainActor
@Observable
final class LLMProviderSetup {
    enum Models: Equatable {
        case loading
        case failed(String)
        case loaded([LLMModelInfo])
    }

    private(set) var providerID: String
    private(set) var modelID: String
    private(set) var baseURL: String
    private(set) var apiKey = ""
    private(set) var hasStoredAPIKey = false
    private(set) var checkingAPIKey = false
    private(set) var models = Models.loading
    private(set) var clearsTypedKey = 0

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var apiKeyDebounce: Task<Void, Never>?
    @ObservationIgnored private var baseURLDebounce: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(engine: Engine, providerID: String, modelID: String) {
        self.engine = engine
        let ids = engine.llmRegistry.descriptors().map(\.id)
        let chosen = ids.contains(providerID) ? providerID : ids.first ?? providerID
        self.providerID = chosen
        self.modelID = modelID
        baseURL = LumaAppState.shared.providerBaseURL(providerID: chosen) ?? ""
        reload(checkingStoredKey: true)
    }

    var providers: [LLMProviderDescriptor] {
        engine.llmRegistry.descriptors()
    }

    var descriptor: LLMProviderDescriptor? {
        engine.llmRegistry.provider(id: providerID)?.descriptor
    }

    var supportsCustomBaseURL: Bool {
        descriptor?.capabilities.supports(.customBaseURL) ?? false
    }

    var requiresKey: Bool {
        descriptor?.capabilities.supports(.apiKey) ?? false
    }

    var supportsKey: Bool {
        requiresKey || (descriptor?.capabilities.supports(.optionalAPIKey) ?? false)
    }

    var loadedModels: [LLMModelInfo] {
        if case .loaded(let models) = models { return models }
        return []
    }

    var isReady: Bool {
        guard !loadedModels.isEmpty else { return false }
        return !requiresKey || hasStoredAPIKey || !apiKey.isEmpty
    }

    func selectProvider(_ id: String) {
        guard id != providerID else { return }
        providerID = id
        apiKey = ""
        clearsTypedKey += 1
        baseURL = LumaAppState.shared.providerBaseURL(providerID: id) ?? ""
        baseURLDebounce?.cancel()
        reload(checkingStoredKey: true)
    }

    func selectModel(_ id: String) {
        guard id != modelID else { return }
        modelID = id
    }

    func type(apiKey text: String) {
        apiKey = text.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyDebounce?.cancel()
        guard apiKey.isEmpty || apiKey.count >= 16 else { return }
        apiKeyDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            self?.reload(checkingStoredKey: false, storingTypedKey: true)
        }
    }

    func type(baseURL text: String) {
        baseURL = text
        baseURLDebounce?.cancel()
        baseURLDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            guard let self else { return }
            LumaAppState.shared.setProviderBaseURL(self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), providerID: self.providerID)
            self.reload(checkingStoredKey: false)
        }
    }

    func save() async {
        if supportsKey, !hasStoredAPIKey, !apiKey.isEmpty {
            try? await engine.llmCredentials.setAPIKey(apiKey, providerID: providerID)
        }
        if supportsCustomBaseURL {
            LumaAppState.shared.setProviderBaseURL(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), providerID: providerID)
        }
    }

    private func reload(checkingStoredKey: Bool, storingTypedKey: Bool = false) {
        guard let provider = engine.llmRegistry.provider(id: providerID) else { return }
        let descriptor = provider.descriptor
        let providerID = providerID
        let typedKey = apiKey
        let configuredBaseURL = effectiveBaseURL
        let credentials = engine.llmCredentials
        let storesTypedKey = storingTypedKey || checkingStoredKey
        models = .loading
        if checkingStoredKey {
            hasStoredAPIKey = false
            checkingAPIKey = supportsKey
        }
        generation += 1
        let generation = generation
        Task { @MainActor [weak self] in
            let storedKey = (try? await credentials.apiKey(providerID: providerID)) ?? nil
            guard let self, self.generation == generation else { return }
            if checkingStoredKey {
                self.checkingAPIKey = false
                self.hasStoredAPIKey = self.supportsKey && storedKey?.isEmpty == false
            }
            let effectiveKey = !typedKey.isEmpty ? typedKey : storedKey
            do {
                let loaded = try await provider.suggestedModels(apiKey: effectiveKey, baseURL: configuredBaseURL)
                guard self.generation == generation else { return }
                self.install(loaded, descriptor: descriptor)
                if storesTypedKey, !typedKey.isEmpty, !self.hasStoredAPIKey {
                    try? await credentials.setAPIKey(typedKey, providerID: providerID)
                    guard self.generation == generation else { return }
                    self.hasStoredAPIKey = true
                    self.apiKey = ""
                    self.clearsTypedKey += 1
                    self.apiKeyDebounce?.cancel()
                }
            } catch {
                guard self.generation == generation else { return }
                let hadKey = effectiveKey?.isEmpty == false
                self.models = .failed(
                    descriptor.capabilities.supports(.apiKey) && !hadKey
                        ? "Enter API key to load models"
                        : describeModelFetchError(error, baseURL: configuredBaseURL ?? descriptor.defaultBaseURL))
            }
        }
    }

    private func install(_ loaded: [LLMModelInfo], descriptor: LLMProviderDescriptor) {
        if !loaded.contains(where: { $0.id == modelID }) {
            modelID = loaded.first { $0.id == descriptor.defaultModelID }?.id ?? loaded.first?.id ?? modelID
        }
        models = .loaded(loaded)
    }

    private var effectiveBaseURL: URL? {
        guard supportsCustomBaseURL else { return nil }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }
}
