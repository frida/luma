import Adw
import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class ObjectChatModelPicker {
    let widget = MenuButton()
    var onSetUp: () -> Void = {}

    private let engine: Engine
    private let chatID: UUID
    private let setup: LLMProviderSetup
    private let popover = Popover()
    private let menu = Box(orientation: .vertical, spacing: 0)
    private var shownMenu: MenuContent?

    private struct MenuContent: Equatable {
        let choice: ObjectChatModelChoice
        let providers: [String]
        let models: LLMProviderSetup.Models
    }

    init(engine: Engine, chatID: UUID) {
        self.engine = engine
        self.chatID = chatID
        let choice = engine.objectChats.modelChoice(in: chatID)
        setup = LLMProviderSetup(engine: engine, providerID: choice.providerID, modelID: choice.modelID)

        widget.add(cssClass: "flat")
        widget.add(cssClass: "caption")
        widget.tooltipText = "The provider and model that answer your questions in this chat"
        menu.marginTop = 4
        menu.marginBottom = 4
        menu.marginStart = 4
        menu.marginEnd = 4
        popover.set(child: menu)
        widget.set(popover: popover)
        follow()
    }

    private var chats: ObjectChats {
        engine.objectChats
    }

    private func follow() {
        withObservationTracking {
            show(chats.modelChoice(in: chatID))
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func show(_ choice: ObjectChatModelChoice) {
        setup.selectProvider(choice.providerID)
        if !choice.modelID.isEmpty {
            setup.selectModel(choice.modelID)
        } else if !setup.loadedModels.isEmpty {
            chats.setModelChoice(ObjectChatModelChoice(providerID: choice.providerID, modelID: setup.modelID), in: chatID)
        }
        widget.label = label(of: choice)
        rebuildMenu(choice)
    }

    private func label(of choice: ObjectChatModelChoice) -> String {
        guard let provider = engine.llmRegistry.provider(id: choice.providerID)?.descriptor else { return choice.providerID }
        guard !choice.modelID.isEmpty, choice.modelID != provider.defaultModelID else { return provider.displayName }
        return setup.loadedModels.first { $0.id == choice.modelID }?.displayName ?? choice.modelID
    }

    private func rebuildMenu(_ choice: ObjectChatModelChoice) {
        let content = MenuContent(choice: choice, providers: setup.providers.map(\.id), models: setup.models)
        guard content != shownMenu else { return }
        shownMenu = content
        while let child = menu.firstChild {
            menu.remove(child: child)
        }
        menu.append(child: heading("Provider"))
        for provider in setup.providers {
            menu.append(child: item(provider.displayName, isChosen: provider.id == choice.providerID) { [weak self] in
                self?.choose(ObjectChatModelChoice(providerID: provider.id, modelID: provider.defaultModelID ?? ""))
            })
        }
        menu.append(child: heading("Model"))
        if case .failed(let reason) = setup.models {
            let note = Label(str: reason)
            note.add(cssClass: "dim-label")
            note.add(cssClass: "caption")
            note.halign = .start
            note.wrap = true
            note.maxWidthChars = 32
            note.marginStart = 8
            note.marginEnd = 8
            note.marginBottom = 4
            menu.append(child: note)
        }
        for model in setup.loadedModels {
            menu.append(child: item(model.displayName, isChosen: model.id == choice.modelID) { [weak self] in
                self?.choose(ObjectChatModelChoice(providerID: choice.providerID, modelID: model.id))
            })
        }
        menu.append(child: Separator(orientation: .horizontal))
        menu.append(child: item("Set Up…", isChosen: false) { [weak self] in self?.onSetUp() })
    }

    private func heading(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "heading")
        label.add(cssClass: "caption")
        label.halign = .start
        label.marginStart = 8
        label.marginTop = 6
        label.marginBottom = 2
        return label
    }

    private func item(_ text: String, isChosen: Bool, _ action: @escaping () -> Void) -> Button {
        let check = Gtk.Image(iconName: "object-select-symbolic")
        check.opacity = isChosen ? 1 : 0
        let label = Label(str: text)
        label.halign = .start
        label.hexpand = true
        let content = Box(orientation: .horizontal, spacing: 6)
        content.append(child: check)
        content.append(child: label)
        let button = Button()
        button.set(child: content)
        button.add(cssClass: "flat")
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.popover.popdown()
                action()
            }
        }
        return button
    }

    private func choose(_ choice: ObjectChatModelChoice) {
        chats.setModelChoice(choice, in: chatID)
    }
}

@MainActor
final class ObjectChatProviderSetupDialog {
    private let dialog = Adw.Dialog()
    private let setup: LLMProviderSetup
    private let section: LLMProviderSetupSection
    private let doneButton = Button(label: "Done")

    static func present(engine: Engine, chatID: UUID, from parent: Widget, onDone: @escaping () -> Void) {
        let controller = ObjectChatProviderSetupDialog(engine: engine, chatID: chatID, onDone: onDone)
        controller.dialog.own(controller)
        controller.dialog.present(parent: parent)
    }

    private init(engine: Engine, chatID: UUID, onDone: @escaping () -> Void) {
        let choice = engine.objectChats.modelChoice(in: chatID)
        setup = LLMProviderSetup(engine: engine, providerID: choice.providerID, modelID: choice.modelID)
        section = LLMProviderSetupSection(setup: setup, labels: SizeGroup(mode: .horizontal))

        dialog.set(title: "Provider for This Chat")
        dialog.set(contentWidth: 520)

        let cancelButton = Button(label: "Cancel")
        cancelButton.add(cssClass: "flat")
        doneButton.add(cssClass: "suggested-action")
        let header = Adw.HeaderBar()
        header.packStart(child: cancelButton)
        header.packEnd(child: doneButton)

        section.widget.marginStart = 24
        section.widget.marginEnd = 24
        section.widget.marginTop = 16
        section.widget.marginBottom = 24
        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: section.widget)
        dialog.set(child: toolbarView)
        dialog.set(defaultWidget: doneButton)

        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.dialog.close() }
        }
        doneButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.doneButton.sensitive = false
                Task { @MainActor in
                    await self.setup.save()
                    engine.objectChats.setModelChoice(ObjectChatModelChoice(providerID: self.setup.providerID, modelID: self.setup.modelID), in: chatID)
                    onDone()
                    _ = self.dialog.close()
                }
            }
        }
        followReadiness()
    }

    private func followReadiness() {
        doneButton.sensitive = withObservationTracking {
            setup.isReady
        } onChange: { [weak self] in
            Task { @MainActor in self?.followReadiness() }
        }
    }
}
