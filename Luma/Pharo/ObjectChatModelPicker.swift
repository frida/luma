import LumaCore
import SwiftUI

struct ObjectChatModelPicker: View {
    let engine: Engine
    let chatID: UUID
    let onSetUp: () -> Void

    @State private var setup: LLMProviderSetup

    init(engine: Engine, chatID: UUID, onSetUp: @escaping () -> Void) {
        self.engine = engine
        self.chatID = chatID
        self.onSetUp = onSetUp
        let choice = engine.objectChats.modelChoice(in: chatID)
        _setup = State(initialValue: LLMProviderSetup(engine: engine, providerID: choice.providerID, modelID: choice.modelID))
    }

    var body: some View {
        Menu {
            Section("Provider") {
                ForEach(setup.providers, id: \.id) { provider in
                    Toggle(provider.displayName, isOn: chosen(choice.providerID == provider.id) { choose(provider) })
                }
            }
            Section("Model") {
                if setup.modelsErrorIsMissingKey {
                    Text("Enter an API key to load models")
                } else if let modelsError = setup.modelsError {
                    Text(modelsError)
                }
                ForEach(setup.availableModels, id: \.id) { model in
                    Toggle(model.displayName, isOn: chosen(choice.modelID == model.id) { choose(model) })
                }
            }
            Divider()
            Button("Set Up…", action: onSetUp)
        } label: {
            Text(label)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .help("The provider and model that answer your questions in this chat")
        .accessibilityIdentifier("conversation.model")
        .task(id: choice) { await follow(choice) }
    }

    private var chats: ObjectChats {
        engine.objectChats
    }

    private var choice: ObjectChatModelChoice {
        chats.modelChoice(in: chatID)
    }

    private var label: String {
        guard let provider = engine.llmRegistry.provider(id: choice.providerID)?.descriptor else { return choice.providerID }
        guard !choice.modelID.isEmpty, choice.modelID != provider.defaultModelID else { return provider.displayName }
        return setup.availableModels.first { $0.id == choice.modelID }?.displayName ?? choice.modelID
    }

    private func follow(_ choice: ObjectChatModelChoice) async {
        setup.providerID = choice.providerID
        setup.modelID = choice.modelID
        await setup.refreshForProvider()
        if choice.modelID.isEmpty, !setup.modelID.isEmpty {
            chats.setModelChoice(ObjectChatModelChoice(providerID: choice.providerID, modelID: setup.modelID), in: chatID)
        }
    }

    private func chosen(_ isChosen: Bool, _ choose: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isChosen }, set: { _ in choose() })
    }

    private func choose(_ provider: LLMProviderDescriptor) {
        chats.setModelChoice(ObjectChatModelChoice(providerID: provider.id, modelID: provider.defaultModelID ?? ""), in: chatID)
    }

    private func choose(_ model: LLMModelInfo) {
        chats.setModelChoice(ObjectChatModelChoice(providerID: choice.providerID, modelID: model.id), in: chatID)
    }
}

struct ObjectChatProviderSetupSheet: View {
    let engine: Engine
    let chatID: UUID
    let onDone: () -> Void

    @State private var setup: LLMProviderSetup
    @State private var isSaving = false

    @Environment(\.dismiss) private var dismiss

    init(engine: Engine, chatID: UUID, onDone: @escaping () -> Void) {
        self.engine = engine
        self.chatID = chatID
        self.onDone = onDone
        let choice = engine.objectChats.modelChoice(in: chatID)
        _setup = State(initialValue: LLMProviderSetup(engine: engine, providerID: choice.providerID, modelID: choice.modelID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Provider for This Chat")
                .font(.title2.bold())
                .padding(.horizontal)
                .padding(.top)
            Form {
                LLMProviderSetupSection(setup: setup)
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Done") { Task { await done() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !setup.isReady)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 340)
    }

    private func done() async {
        isSaving = true
        defer { isSaving = false }
        await setup.save()
        engine.objectChats.setModelChoice(ObjectChatModelChoice(providerID: setup.providerID, modelID: setup.modelID), in: chatID)
        onDone()
        dismiss()
    }
}
