import LumaCore
import SwiftUI

struct NewMissionSheet: View {
    let engine: Engine
    @Binding var isPresented: Bool
    var onCreated: (Mission) -> Void

    @State private var goalText: String = ""
    @State private var setup: LLMProviderSetup
    @State private var tokenBudgetInput: Int
    @State private var tokenBudgetOutput: Int
    @State private var thinkingEnabled: Bool
    @State private var thinkingBudget: Int
    @State private var reasoningEffort: String
    @State private var isStarting = false

    init(engine: Engine, isPresented: Binding<Bool>, onCreated: @escaping (Mission) -> Void) {
        self.engine = engine
        self._isPresented = isPresented
        self.onCreated = onCreated
        let defaults = LumaAppState.shared.missionDefaults
        self._setup = State(initialValue: LLMProviderSetup(engine: engine, providerID: defaults.providerID, modelID: defaults.modelID))
        self._tokenBudgetInput = State(initialValue: defaults.tokenBudgetInput)
        self._tokenBudgetOutput = State(initialValue: defaults.tokenBudgetOutput)
        self._thinkingEnabled = State(initialValue: defaults.thinkingEnabled)
        self._thinkingBudget = State(initialValue: defaults.thinkingBudget)
        self._reasoningEffort = State(initialValue: defaults.reasoningEffort ?? "auto")
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
            .onChange(of: setup.providerID) { _, _ in keepReasoningEffortValid() }
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
        .onChange(of: setup.providerID) { _, _ in keepReasoningEffortValid() }
    }

    private var formContent: some View {
        Form {
                Section("Goal") {
                    TextEditor(text: $goalText)
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                }

                LLMProviderSetupSection(setup: setup)

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

    private var currentProviderSupportsThinking: Bool {
        setup.provider?.capabilities.supports(.thinking) ?? false
    }

    private var reasoningEffortOptions: [String] {
        setup.provider?.capabilities.reasoningEffortOptions ?? []
    }

    private var canStart: Bool {
        !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStarting && setup.isReady
    }

    private func keepReasoningEffortValid() {
        if let options = setup.provider?.capabilities.reasoningEffortOptions, !options.contains(reasoningEffort) {
            reasoningEffort = setup.provider?.capabilities.defaultReasoningEffort ?? options.first ?? "auto"
        }
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }

        await setup.save()
        rememberDefaults()

        let mission = engine.startMission(
            goal: goalText,
            providerID: setup.providerID,
            modelID: setup.modelID,
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
            providerID: setup.providerID,
            modelID: setup.modelID,
            tokenBudgetInput: tokenBudgetInput,
            tokenBudgetOutput: tokenBudgetOutput,
            thinkingEnabled: thinkingEnabled,
            thinkingBudget: thinkingBudget,
            reasoningEffort: reasoningEffortOptions.isEmpty ? nil : reasoningEffort
        )
    }
}
