import LumaCore
import Observation
import SwiftUI

struct LLMProviderSetupSection: View {
    @Bindable var setup: LLMProviderSetup

    var body: some View {
        Section("Model") {
            Picker("Provider", selection: $setup.providerID) {
                ForEach(setup.providers, id: \.id) { d in
                    Text(d.displayName).tag(d.id)
                }
            }
            .task(id: setup.providerID) { await setup.refreshForProvider() }
            .onChange(of: setup.hasStoredAPIKey) { _, _ in Task { await setup.refreshModels() } }
            .onChange(of: setup.apiKey) { _, _ in setup.scheduleAPIKeyRefresh() }
            .onChange(of: setup.providerID) { _, _ in setup.useDefaultModel() }

            if setup.supportsCustomBaseURL {
                TextField(setup.baseURLPlaceholder, text: $setup.baseURLInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await setup.refreshModels() } }
            }

            LabeledContent("Model") {
                if setup.modelsLoading {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                } else if setup.modelsErrorIsMissingKey {
                    Text("Enter an API key to load models")
                        .foregroundStyle(.secondary)
                } else if let modelsError = setup.modelsError {
                    Label(modelsError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Picker("", selection: $setup.shownModelID) {
                        ForEach(setup.availableModels, id: \.id) { m in
                            Text(m.displayName).tag(m.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            if setup.supportsKey {
                if setup.checkingAPIKey {
                    HStack { ProgressView().scaleEffect(0.7); Text("Checking saved API key…").foregroundStyle(.secondary) }
                } else if !setup.hasStoredAPIKey {
                    SecureField(setup.apiKeyPrompt, text: $setup.apiKey)
                        .textFieldStyle(.roundedBorder)
                    Text("Stored under the app's data directory. Never written to the project document.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("API key on file", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
        }
    }
}

@MainActor
@Observable
final class LLMProviderSetup {
    var providerID: String
    var modelID: String
    var baseURLInput: String
    var apiKey = ""
    private(set) var hasStoredAPIKey = false
    private(set) var checkingAPIKey = true
    private(set) var availableModels: [LLMModelInfo] = []
    private(set) var modelsLoading = false
    private(set) var modelsError: String?
    private(set) var modelsErrorIsMissingKey = false

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var apiKeyDebounce: Task<Void, Never>?

    init(engine: Engine, providerID: String, modelID: String) {
        self.engine = engine
        self.providerID = providerID
        self.modelID = modelID
        baseURLInput = LumaAppState.shared.providerBaseURL(providerID: providerID) ?? ""
    }

    var providers: [LLMProviderDescriptor] {
        engine.llmRegistry.descriptors()
    }

    var provider: LLMProviderDescriptor? {
        engine.llmRegistry.provider(id: providerID)?.descriptor
    }

    var shownModelID: String {
        get {
            if availableModels.contains(where: { $0.id == modelID }) { return modelID }
            return availableModels.first?.id ?? modelID
        }
        set { modelID = newValue }
    }

    var isReady: Bool {
        guard !modelsLoading, !availableModels.isEmpty else { return false }
        if requiresKey {
            return hasStoredAPIKey || !apiKey.isEmpty
        }
        return true
    }

    var supportsCustomBaseURL: Bool {
        provider?.capabilities.supports(.customBaseURL) ?? false
    }

    var baseURLPlaceholder: String {
        "Base URL (default: \(provider?.defaultBaseURL.absoluteString ?? ""))"
    }

    var supportsKey: Bool {
        guard let capabilities = provider?.capabilities else { return false }
        return capabilities.supports(.apiKey) || capabilities.supports(.optionalAPIKey)
    }

    var apiKeyPrompt: String {
        if requiresKey {
            return "API key for \(displayName)"
        }
        return "API key for \(displayName) (optional)"
    }

    private var requiresKey: Bool {
        provider?.capabilities.supports(.apiKey) ?? false
    }

    private var displayName: String {
        provider?.displayName ?? providerID
    }

    func useDefaultModel() {
        modelID = provider?.defaultModelID ?? modelID
    }

    func refreshForProvider() async {
        baseURLInput = LumaAppState.shared.providerBaseURL(providerID: providerID) ?? ""
        await refreshAPIKeyStatus()
        await refreshModels()
    }

    func scheduleAPIKeyRefresh() {
        apiKeyDebounce?.cancel()
        guard apiKey.isEmpty || apiKeyLooksPlausible else { return }
        apiKeyDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await refreshModels()
        }
    }

    func refreshModels() async {
        guard let provider = engine.llmRegistry.provider(id: providerID) else {
            availableModels = []
            modelsError = nil
            modelsErrorIsMissingKey = false
            return
        }
        let providerID = providerID
        modelsLoading = true
        modelsError = nil
        modelsErrorIsMissingKey = false
        defer { modelsLoading = false }
        do {
            let storedKey = (try? await engine.llmCredentials.apiKey(providerID: providerID)) ?? nil
            let typedKey = apiKey
            let effectiveKey = !typedKey.isEmpty ? typedKey : storedKey
            let models = try await provider.suggestedModels(apiKey: effectiveKey, baseURL: effectiveBaseURL)
            guard self.providerID == providerID else { return }
            availableModels = models
            if !models.contains(where: { $0.id == modelID }) {
                modelID = provider.descriptor.defaultModelID ?? models.first?.id ?? modelID
            }
            if !typedKey.isEmpty, !hasStoredAPIKey {
                try? await engine.llmCredentials.setAPIKey(typedKey, providerID: providerID)
                guard self.providerID == providerID else { return }
                hasStoredAPIKey = true
                apiKey = ""
            }
        } catch {
            guard self.providerID == providerID else { return }
            availableModels = []
            let typedKey = apiKey
            let hadKey = !typedKey.isEmpty || hasStoredAPIKey
            if requiresKey, !hadKey {
                modelsErrorIsMissingKey = true
                modelsError = nil
            } else {
                modelsErrorIsMissingKey = false
                modelsError = describeModelFetchError(error, baseURL: effectiveBaseURL ?? provider.descriptor.defaultBaseURL)
            }
        }
    }

    func save() async {
        if !hasStoredAPIKey, !apiKey.isEmpty {
            try? await engine.llmCredentials.setAPIKey(apiKey, providerID: providerID)
        }
        if supportsCustomBaseURL {
            LumaAppState.shared.setProviderBaseURL(baseURLInput, providerID: providerID)
        }
    }

    private func refreshAPIKeyStatus() async {
        guard supportsKey else {
            hasStoredAPIKey = false
            checkingAPIKey = false
            return
        }
        checkingAPIKey = true
        defer { checkingAPIKey = false }
        do {
            let stored = try await engine.llmCredentials.apiKey(providerID: providerID)
            hasStoredAPIKey = (stored?.isEmpty == false)
        } catch {
            hasStoredAPIKey = false
        }
    }

    private var apiKeyLooksPlausible: Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16
    }

    private var effectiveBaseURL: URL? {
        let trimmed = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }
}
