import LumaCore
import SwiftUI

struct NewMissionSheet: View {
    let engine: Engine
    @Binding var isPresented: Bool
    var onCreated: (Mission) -> Void

    @State private var goalText: String = ""
    @State private var selectedProviderID: String
    @State private var selectedModelID: String
    @State private var tokenBudgetInput: Int
    @State private var tokenBudgetOutput: Int
    @State private var thinkingEnabled: Bool
    @State private var thinkingBudget: Int
    @State private var reasoningEffort: String
    @State private var baseURLInput: String = ""
    @State private var apiKey: String = ""
    @State private var hasStoredAPIKey: Bool = false
    @State private var checkingAPIKey: Bool = true
    @State private var isStarting = false
    @State private var availableModels: [LLMModelInfo] = []
    @State private var modelsLoading = false
    @State private var modelsError: String?
    @State private var modelsErrorIsMissingKey = false
    @State private var apiKeyDebounce: Task<Void, Never>?

    init(engine: Engine, isPresented: Binding<Bool>, onCreated: @escaping (Mission) -> Void) {
        self.engine = engine
        self._isPresented = isPresented
        self.onCreated = onCreated
        let defaults = LumaAppState.shared.missionDefaults
        self._selectedProviderID = State(initialValue: defaults.providerID)
        self._selectedModelID = State(initialValue: defaults.modelID)
        self._tokenBudgetInput = State(initialValue: defaults.tokenBudgetInput)
        self._tokenBudgetOutput = State(initialValue: defaults.tokenBudgetOutput)
        self._thinkingEnabled = State(initialValue: defaults.thinkingEnabled)
        self._thinkingBudget = State(initialValue: defaults.thinkingBudget)
        self._reasoningEffort = State(initialValue: defaults.reasoningEffort ?? "auto")
        self._baseURLInput = State(initialValue: LumaAppState.shared.providerBaseURL(providerID: defaults.providerID) ?? "")
    }

    var body: some View {
        #if os(macOS)
        desktopLayout
        #else
        NavigationStack { compactLayout }
        #endif
    }

    #if !os(macOS)
    private var compactLayout: some View {
        formContent
            .formStyle(.grouped)
            .navigationTitle("New Mission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStarting ? "Starting…" : "Start") {
                        Task { await start() }
                    }
                    .disabled(!canStart)
                }
            }
            .task(id: selectedProviderID) {
                baseURLInput = LumaAppState.shared.providerBaseURL(providerID: selectedProviderID) ?? ""
                await refreshAPIKeyStatus()
                await refreshModels()
            }
            .onChange(of: hasStoredAPIKey) { _, _ in Task { await refreshModels() } }
            .onChange(of: apiKey) { _, _ in scheduleAPIKeyRefresh() }
            .onChange(of: selectedProviderID) { _, _ in
                let descriptor = engine.llmRegistry.provider(id: selectedProviderID)?.descriptor
                selectedModelID = descriptor?.defaultModelID ?? selectedModelID
                if let options = descriptor?.capabilities.reasoningEffortOptions, !options.contains(reasoningEffort) {
                    reasoningEffort = descriptor?.capabilities.defaultReasoningEffort ?? options.first ?? "auto"
                }
            }
    }
    #endif

    private var desktopLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Mission")
                .font(.title2.bold())
                .padding(.horizontal)
                .padding(.top)

            formContent
                .formStyle(.grouped)

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button(isStarting ? "Starting…" : "Start Mission") {
                    Task { await start() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 600)
        .task(id: selectedProviderID) {
            baseURLInput = LumaAppState.shared.providerBaseURL(providerID: selectedProviderID) ?? ""
            await refreshAPIKeyStatus()
            await refreshModels()
        }
        .onChange(of: hasStoredAPIKey) { _, _ in Task { await refreshModels() } }
        .onChange(of: apiKey) { _, _ in scheduleAPIKeyRefresh() }
        .onChange(of: selectedProviderID) { _, _ in
            let descriptor = engine.llmRegistry.provider(id: selectedProviderID)?.descriptor
            selectedModelID = descriptor?.defaultModelID ?? selectedModelID
            if let options = descriptor?.capabilities.reasoningEffortOptions, !options.contains(reasoningEffort) {
                reasoningEffort = descriptor?.capabilities.defaultReasoningEffort ?? options.first ?? "auto"
            }
        }
    }

    private var formContent: some View {
        Form {
                Section("Goal") {
                    TextEditor(text: $goalText)
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                }

                Section("Model") {
                    Picker("Provider", selection: $selectedProviderID) {
                        ForEach(engine.llmRegistry.descriptors(), id: \.id) { d in
                            Text(d.displayName).tag(d.id)
                        }
                    }

                    if currentProviderSupportsCustomBaseURL {
                        TextField(baseURLPlaceholder, text: $baseURLInput)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await refreshModels() } }
                    }

                    LabeledContent("Model") {
                        if modelsLoading {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text("Loading…").foregroundStyle(.secondary)
                            }
                        } else if modelsErrorIsMissingKey {
                            Text("Enter an API key to load models")
                                .foregroundStyle(.secondary)
                        } else if let modelsError {
                            Label(modelsError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        } else {
                            Picker("", selection: resolvedModelBinding) {
                                ForEach(availableModels, id: \.id) { m in
                                    Text(m.displayName).tag(m.id)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    if currentProviderSupportsKey {
                        if checkingAPIKey {
                            HStack { ProgressView().scaleEffect(0.7); Text("Checking saved API key…").foregroundStyle(.secondary) }
                        } else if !hasStoredAPIKey {
                            SecureField(apiKeyPrompt, text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                            Text("Stored under the app's data directory. Never written to the project document.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("API key on file", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                    }
                }

                Section("Budget") {
                    Stepper("Input tokens: \(tokenBudgetInput)", value: $tokenBudgetInput, in: 10_000...2_000_000, step: 10_000)
                    Stepper("Output tokens: \(tokenBudgetOutput)", value: $tokenBudgetOutput, in: 1_000...64_000, step: 1_000)
                    if !reasoningEffortOptions.isEmpty {
                        Picker("Reasoning effort", selection: $reasoningEffort) {
                            ForEach(reasoningEffortOptions, id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                    } else if currentProviderSupportsThinking {
                        Toggle("Extended thinking", isOn: $thinkingEnabled)
                        if thinkingEnabled {
                            Stepper("Thinking budget: \(thinkingBudget)", value: $thinkingBudget, in: 1_024...32_000, step: 1_024)
                        }
                    }
                }
        }
    }

    private var currentProviderSupportsCustomBaseURL: Bool {
        engine.llmRegistry.provider(id: selectedProviderID)?
            .descriptor.capabilities.supports(.customBaseURL) ?? false
    }

    private var baseURLPlaceholder: String {
        let fallback = engine.llmRegistry.provider(id: selectedProviderID)?
            .descriptor.defaultBaseURL.absoluteString ?? ""
        return "Base URL (default: \(fallback))"
    }

    private var resolvedModelBinding: Binding<String> {
        Binding(
            get: {
                if availableModels.contains(where: { $0.id == selectedModelID }) { return selectedModelID }
                return availableModels.first?.id ?? selectedModelID
            },
            set: { selectedModelID = $0 }
        )
    }

    private var currentProviderDisplayName: String {
        engine.llmRegistry.provider(id: selectedProviderID)?
            .descriptor.displayName ?? selectedProviderID
    }

    private var currentProviderRequiresKey: Bool {
        engine.llmRegistry.provider(id: selectedProviderID)?
            .descriptor.capabilities.supports(.apiKey) ?? false
    }

    private var currentProviderSupportsKey: Bool {
        guard let capabilities = engine.llmRegistry.provider(id: selectedProviderID)?.descriptor.capabilities else {
            return false
        }
        return capabilities.supports(.apiKey) || capabilities.supports(.optionalAPIKey)
    }

    private var apiKeyPrompt: String {
        if currentProviderRequiresKey {
            return "API key for \(currentProviderDisplayName)"
        }
        return "API key for \(currentProviderDisplayName) (optional)"
    }

    private var currentProviderSupportsThinking: Bool {
        engine.llmRegistry.provider(id: selectedProviderID)?
            .descriptor.capabilities.supports(.thinking) ?? false
    }

    private var reasoningEffortOptions: [String] {
        engine.llmRegistry.provider(id: selectedProviderID)?
            .descriptor.capabilities.reasoningEffortOptions ?? []
    }

    private var apiKeyLooksPlausible: Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16
    }

    private var canStart: Bool {
        guard !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !isStarting,
            !modelsLoading,
            !availableModels.isEmpty
        else { return false }
        if currentProviderRequiresKey {
            return hasStoredAPIKey || !apiKey.isEmpty
        }
        return true
    }

    private func refreshAPIKeyStatus() async {
        guard currentProviderSupportsKey else {
            hasStoredAPIKey = false
            checkingAPIKey = false
            return
        }
        checkingAPIKey = true
        defer { checkingAPIKey = false }
        do {
            let stored = try await engine.llmCredentials.apiKey(providerID: selectedProviderID)
            hasStoredAPIKey = (stored?.isEmpty == false)
        } catch {
            hasStoredAPIKey = false
        }
    }

    private func scheduleAPIKeyRefresh() {
        apiKeyDebounce?.cancel()
        guard apiKey.isEmpty || apiKeyLooksPlausible else { return }
        apiKeyDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await refreshModels()
        }
    }

    private func refreshModels() async {
        guard let provider = engine.llmRegistry.provider(id: selectedProviderID) else {
            availableModels = []
            modelsError = nil
            modelsErrorIsMissingKey = false
            return
        }
        let providerID = selectedProviderID
        modelsLoading = true
        modelsError = nil
        modelsErrorIsMissingKey = false
        defer { modelsLoading = false }
        do {
            let storedKey = (try? await engine.llmCredentials.apiKey(providerID: providerID)) ?? nil
            let typedKey = apiKey
            let effectiveKey = !typedKey.isEmpty ? typedKey : storedKey
            let models = try await provider.suggestedModels(apiKey: effectiveKey, baseURL: effectiveBaseURL)
            guard selectedProviderID == providerID else { return }
            availableModels = models
            if !models.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = provider.descriptor.defaultModelID ?? models.first?.id ?? selectedModelID
            }
            if !typedKey.isEmpty, !hasStoredAPIKey {
                try? await engine.llmCredentials.setAPIKey(typedKey, providerID: providerID)
                guard selectedProviderID == providerID else { return }
                hasStoredAPIKey = true
                apiKey = ""
            }
        } catch {
            guard selectedProviderID == providerID else { return }
            availableModels = []
            let typedKey = apiKey
            let hadKey = !typedKey.isEmpty || hasStoredAPIKey
            if currentProviderRequiresKey, !hadKey {
                modelsErrorIsMissingKey = true
                modelsError = nil
            } else {
                modelsErrorIsMissingKey = false
                modelsError = describeModelFetchError(error, baseURL: effectiveBaseURL ?? provider.descriptor.defaultBaseURL)
            }
        }
    }

    private var effectiveBaseURL: URL? {
        let trimmed = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }

        if !hasStoredAPIKey, !apiKey.isEmpty {
            try? await engine.llmCredentials.setAPIKey(apiKey, providerID: selectedProviderID)
        }

        rememberDefaults()

        let mission = engine.startMission(
            goal: goalText,
            providerID: selectedProviderID,
            modelID: selectedModelID,
            tokenBudgetInput: tokenBudgetInput,
            tokenBudgetOutput: tokenBudgetOutput,
            thinkingBudget: thinkingEnabled ? thinkingBudget : 0,
            reasoningEffort: reasoningEffortOptions.isEmpty ? nil : reasoningEffort
        )
        if let mission {
            onCreated(mission)
            isPresented = false
        }
    }

    private func rememberDefaults() {
        LumaAppState.shared.missionDefaults = .init(
            providerID: selectedProviderID,
            modelID: selectedModelID,
            tokenBudgetInput: tokenBudgetInput,
            tokenBudgetOutput: tokenBudgetOutput,
            thinkingEnabled: thinkingEnabled,
            thinkingBudget: thinkingBudget,
            reasoningEffort: reasoningEffortOptions.isEmpty ? nil : reasoningEffort
        )
        if currentProviderSupportsCustomBaseURL {
            LumaAppState.shared.setProviderBaseURL(baseURLInput, providerID: selectedProviderID)
        }
    }
}
