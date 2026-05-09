import LumaCore
import SwiftUI

struct NewMissionSheet: View {
    @ObservedObject var workspace: Workspace
    @Binding var isPresented: Bool
    var onCreated: (Mission) -> Void

    @State private var goalText: String = ""
    @State private var selectedProviderID: String = AnthropicProvider.providerID
    @State private var selectedModelID: String = "claude-sonnet-4-6"
    @State private var tokenBudgetInput: Int = 250_000
    @State private var tokenBudgetOutput: Int = 32_000
    @State private var thinkingEnabled: Bool = false
    @State private var thinkingBudget: Int = 4_096
    @State private var apiKey: String = ""
    @State private var hasStoredAPIKey: Bool = false
    @State private var checkingAPIKey: Bool = true
    @State private var isStarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Mission")
                .font(.title2.bold())
                .padding(.horizontal)
                .padding(.top)

            Form {
                Section("Goal") {
                    TextEditor(text: $goalText)
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                }

                Section("Model") {
                    Picker("Provider", selection: $selectedProviderID) {
                        ForEach(workspace.engine.llmRegistry.descriptors(), id: \.id) { d in
                            Text(d.displayName).tag(d.id)
                        }
                    }

                    Picker("Model", selection: resolvedModelBinding) {
                        ForEach(modelsForCurrentProvider(), id: \.id) { m in
                            Text(m.displayName).tag(m.id)
                        }
                    }

                    if currentProviderRequiresKey {
                        if checkingAPIKey {
                            HStack { ProgressView().scaleEffect(0.7); Text("Checking saved API key…").foregroundStyle(.secondary) }
                        } else if !hasStoredAPIKey {
                            SecureField("API key for \(selectedProviderID)", text: $apiKey)
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
                    Toggle("Extended thinking", isOn: $thinkingEnabled)
                    if thinkingEnabled {
                        Stepper("Thinking budget: \(thinkingBudget)", value: $thinkingBudget, in: 1_024...32_000, step: 1_024)
                    }
                }
            }
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
        .task(id: selectedProviderID) { await refreshAPIKeyStatus() }
        .onChange(of: selectedProviderID) { _, _ in
            selectedModelID = workspace.engine.llmRegistry.provider(id: selectedProviderID)?.descriptor.defaultModelID ?? selectedModelID
        }
    }

    private var canStart: Bool {
        guard !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !isStarting
        else { return false }
        if currentProviderRequiresKey {
            return hasStoredAPIKey || !apiKey.isEmpty
        }
        return true
    }

    private var currentProviderRequiresKey: Bool {
        workspace.engine.llmRegistry.provider(id: selectedProviderID)?
            .descriptor.capabilities.requiresAPIKey ?? false
    }

    private func modelsForCurrentProvider() -> [LLMModelInfo] {
        workspace.engine.llmRegistry.provider(id: selectedProviderID)?.suggestedModels() ?? []
    }

    private var resolvedModelBinding: Binding<String> {
        Binding(
            get: {
                let models = modelsForCurrentProvider()
                if models.contains(where: { $0.id == selectedModelID }) { return selectedModelID }
                return models.first?.id ?? selectedModelID
            },
            set: { selectedModelID = $0 }
        )
    }

    private func refreshAPIKeyStatus() async {
        guard currentProviderRequiresKey else {
            hasStoredAPIKey = false
            checkingAPIKey = false
            return
        }
        checkingAPIKey = true
        defer { checkingAPIKey = false }
        do {
            let stored = try await workspace.engine.llmCredentials.apiKey(providerID: selectedProviderID)
            hasStoredAPIKey = (stored?.isEmpty == false)
        } catch {
            hasStoredAPIKey = false
        }
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }

        if !hasStoredAPIKey, !apiKey.isEmpty {
            try? await workspace.engine.llmCredentials.setAPIKey(apiKey, providerID: selectedProviderID)
        }

        let mission = workspace.engine.startMission(
            goal: goalText,
            providerID: selectedProviderID,
            modelID: selectedModelID,
            tokenBudgetInput: tokenBudgetInput,
            tokenBudgetOutput: tokenBudgetOutput,
            thinkingBudget: thinkingEnabled ? thinkingBudget : 0
        )
        if let mission {
            onCreated(mission)
            isPresented = false
        }
    }
}

