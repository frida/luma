import Adw
import CGtk
import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class NewMissionDialog {
    typealias OnCreated = (Mission) -> Void

    private let dialog: Adw.Dialog
    private let parentWindow: Gtk.Window
    private weak var engine: Engine?
    private let onCreated: OnCreated

    private let goalView: TextView
    private let goalScroll: ScrolledWindow
    private let setup: LLMProviderSetup
    private let providerSection: LLMProviderSetupSection
    private let inputBudgetSpin: SpinButton
    private let outputBudgetSpin: SpinButton
    private let thinkingSwitch: Switch
    private let thinkingBudgetSpin: SpinButton
    private let thinkingBudgetRow: Box
    private let thinkingSection: Box
    private let reasoningDropdown: DropDown
    private let reasoningRow: Box
    private let startButton: Button
    private let cancelButton: Button
    private let footerError: Label
    private let formLabels = SizeGroup(mode: .horizontal)

    private var isStarting: Bool = false
    private var shownProviderID: String?
    private var reasoningEffortOptions: [String] = []
    private var selectedReasoningEffort: String

    init(
        parent: Gtk.Window,
        engine: Engine,
        onCreated: @escaping OnCreated
    ) {
        self.parentWindow = parent
        self.engine = engine
        self.onCreated = onCreated

        let defaults = LumaAppState.shared.missionDefaults
        setup = LLMProviderSetup(engine: engine, providerID: defaults.providerID, modelID: defaults.modelID)
        providerSection = LLMProviderSetupSection(setup: setup, labels: formLabels)
        selectedReasoningEffort = defaults.reasoningEffort ?? "auto"

        dialog = Adw.Dialog()
        dialog.set(title: "New Mission")
        dialog.set(contentWidth: 600)
        dialog.set(contentHeight: 640)

        goalView = TextView()
        goalView.wrapMode = .word
        goalView.topMargin = 8
        goalView.bottomMargin = 8
        goalView.leftMargin = 8
        goalView.rightMargin = 8
        goalView.add(cssClass: "monospace")

        goalScroll = ScrolledWindow()
        goalScroll.hexpand = true
        goalScroll.vexpand = true
        goalScroll.setSizeRequest(width: -1, height: 120)
        goalScroll.add(cssClass: "card")
        goalScroll.set(child: goalView)

        inputBudgetSpin = SpinButton(
            range: 10_000,
            max: 2_000_000,
            step: 10_000
        )
        inputBudgetSpin.value = Double(defaults.tokenBudgetInput)

        outputBudgetSpin = SpinButton(
            range: 1_000,
            max: 64_000,
            step: 1_000
        )
        outputBudgetSpin.value = Double(defaults.tokenBudgetOutput)

        thinkingSwitch = Switch()
        thinkingSwitch.active = defaults.thinkingEnabled
        thinkingSwitch.valign = .center

        thinkingBudgetSpin = SpinButton(range: 1_024, max: 32_000, step: 1_024)
        thinkingBudgetSpin.value = Double(defaults.thinkingBudget)

        thinkingBudgetRow = Box(orientation: .horizontal, spacing: 12)
        thinkingSection = Box(orientation: .vertical, spacing: 8)

        reasoningDropdown = LLMProviderSetupSection.makeStringDropdown(labels: [], selected: 0)
        reasoningRow = Box(orientation: .horizontal, spacing: 12)

        startButton = Button(label: "Start Mission")
        startButton.add(cssClass: "suggested-action")
        startButton.sensitive = false

        cancelButton = Button(label: "Cancel")
        cancelButton.add(cssClass: "flat")

        footerError = Label(str: "")
        footerError.halign = .end
        footerError.hexpand = true
        footerError.xalign = 1
        footerError.add(cssClass: "error")
        footerError.add(cssClass: "caption")
        footerError.visible = false

        let header = Adw.HeaderBar()
        header.packEnd(child: startButton)
        header.packStart(child: cancelButton)

        let formBox = buildForm()

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: formBox)
        dialog.set(child: toolbarView)
        dialog.set(defaultWidget: startButton)

        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.dialog.close() }
        }
        startButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }

        followSetup()

        thinkingSwitch.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                self?.thinkingBudgetRow.visible = state
                return false
            }
        }
        reasoningDropdown.onNotifySelected { [weak self] dropdown, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let idx = Int(dropdown.selected)
                guard idx >= 0, idx < self.reasoningEffortOptions.count else { return }
                self.selectedReasoningEffort = self.reasoningEffortOptions[idx]
            }
        }
        if let buffer = goalView.buffer {
            buffer.onChanged { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStartSensitivity() }
            }
        }
        thinkingBudgetRow.visible = thinkingSwitch.active
        applyProviderSelection()
    }

    func present() {
        dialog.own(self)
        dialog.present(parent: parentWindow)
        Task { @MainActor in
            _ = self.goalView.grabFocus()
        }
    }

    private func buildForm() -> ScrolledWindow {
        let outer = Box(orientation: .vertical, spacing: 0)
        outer.hexpand = true
        outer.vexpand = true
        outer.marginStart = 24
        outer.marginEnd = 24
        outer.marginTop = 16
        outer.marginBottom = 16

        outer.append(child: section(title: "Goal", child: goalScroll, hint: "What should the agent investigate? Be specific."))

        outer.append(child: section(title: "Model", child: providerSection.widget, hint: nil))

        let budgetGroup = Box(orientation: .vertical, spacing: 8)
        budgetGroup.append(child: formRow(title: "Input tokens", control: inputBudgetSpin))
        budgetGroup.append(child: formRow(title: "Output tokens", control: outputBudgetSpin))

        let thinkingHeader = Box(orientation: .horizontal, spacing: 12)
        let thinkingLabel = Label(str: "Extended thinking")
        thinkingLabel.halign = .start
        thinkingLabel.hexpand = true
        thinkingHeader.append(child: thinkingLabel)
        thinkingHeader.append(child: thinkingSwitch)
        thinkingSection.append(child: thinkingHeader)

        let thinkingTitle = Label(str: "Thinking budget")
        thinkingTitle.halign = .start
        thinkingTitle.xalign = 0
        formLabels.add(widget: thinkingTitle)
        thinkingBudgetRow.append(child: thinkingTitle)
        thinkingBudgetSpin.hexpand = true
        thinkingBudgetSpin.halign = .end
        thinkingBudgetRow.append(child: thinkingBudgetSpin)
        thinkingSection.append(child: thinkingBudgetRow)
        budgetGroup.append(child: thinkingSection)

        reasoningRow.append(child: formRow(title: "Reasoning effort", control: reasoningDropdown))
        budgetGroup.append(child: reasoningRow)
        reasoningRow.visible = false

        outer.append(child: section(title: "Budget", child: budgetGroup, hint: nil))

        let footer = Box(orientation: .horizontal, spacing: 8)
        footer.marginTop = 12
        footer.append(child: footerError)
        outer.append(child: footer)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: outer)
        return scroll
    }

    private func section(title: String, child: Widget, hint: String?) -> Box {
        let column = Box(orientation: .vertical, spacing: 6)
        column.marginBottom = 16

        let header = Label(str: title)
        header.halign = .start
        header.add(cssClass: "heading")
        column.append(child: header)

        if let hint {
            let hintLabel = Label(str: hint)
            hintLabel.halign = .start
            hintLabel.wrap = true
            hintLabel.xalign = 0
            hintLabel.add(cssClass: "dim-label")
            hintLabel.add(cssClass: "caption")
            column.append(child: hintLabel)
        }

        column.append(child: child)
        return column
    }

    private func formRow(title: String, control: Widget) -> Box {
        LLMProviderSetupSection.formRow(title: title, control: control, labels: formLabels)
    }

    private func followSetup() {
        withObservationTracking {
            if setup.providerID != shownProviderID {
                shownProviderID = setup.providerID
                applyProviderSelection()
            }
            refreshStartSensitivity()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followSetup() }
        }
    }

    private func applyProviderSelection() {
        guard let descriptor = setup.descriptor else { return }
        reasoningEffortOptions = descriptor.capabilities.reasoningEffortOptions
        let hasReasoningOptions = !reasoningEffortOptions.isEmpty
        reasoningRow.visible = hasReasoningOptions
        if hasReasoningOptions {
            if !reasoningEffortOptions.contains(selectedReasoningEffort) {
                selectedReasoningEffort = descriptor.capabilities.defaultReasoningEffort ?? reasoningEffortOptions.first ?? "auto"
            }
            let idx = reasoningEffortOptions.firstIndex(of: selectedReasoningEffort) ?? 0
            LLMProviderSetupSection.setDropdownLabels(reasoningDropdown, labels: reasoningEffortOptions, selectedIndex: idx)
        }

        thinkingSection.visible = !hasReasoningOptions && descriptor.capabilities.supports(.thinking)
        if !thinkingSection.visible {
            thinkingBudgetRow.visible = false
        } else {
            thinkingBudgetRow.visible = thinkingSwitch.active
        }
    }

    private func refreshStartSensitivity() {
        startButton.sensitive = !isStarting && !trimmedGoal.isEmpty && setup.isReady
    }

    private var trimmedGoal: String {
        guard let buffer = goalView.buffer else { return "" }
        let startPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let endPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            startPtr.deallocate()
            endPtr.deallocate()
        }
        let start = TextIter(startPtr)
        let end = TextIter(endPtr)
        buffer.getStart(iter: start)
        buffer.getEnd(iter: end)
        let text = buffer.getText(start: start, end: end, includeHiddenChars: true) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func start() {
        guard let engine else { return }
        let goal = trimmedGoal
        guard !goal.isEmpty else { return }

        let providerID = setup.providerID
        let modelID = setup.modelID
        let inputBudget = Int(inputBudgetSpin.value)
        let outputBudget = Int(outputBudgetSpin.value)
        let thinkingEnabled = thinkingSwitch.active
        let thinkingBudget = Int(thinkingBudgetSpin.value)
        let reasoningEffort = reasoningEffortOptions.isEmpty ? nil : selectedReasoningEffort

        isStarting = true
        startButton.sensitive = false
        startButton.label = "Starting…"

        let onCreated = self.onCreated
        let parent = self.parentWindow
        _ = parent
        let dialog = self.dialog
        let setup = self.setup

        Task { @MainActor in
            await setup.save()

            LumaAppState.shared.missionDefaults = .init(
                providerID: providerID,
                modelID: modelID,
                tokenBudgetInput: inputBudget,
                tokenBudgetOutput: outputBudget,
                thinkingEnabled: thinkingEnabled,
                thinkingBudget: thinkingBudget,
                reasoningEffort: reasoningEffort
            )
            let mission = engine.startMission(
                goal: goal,
                providerID: providerID,
                modelID: modelID,
                tokenBudgetInput: inputBudget,
                tokenBudgetOutput: outputBudget,
                thinkingBudget: thinkingEnabled ? thinkingBudget : 0,
                reasoningEffort: reasoningEffort
            )
            if let mission {
                onCreated(mission)
                _ = dialog.close()
            } else {
                self.isStarting = false
                self.startButton.label = "Start Mission"
                self.footerError.label = "Failed to start mission."
                self.footerError.visible = true
                self.refreshStartSensitivity()
            }
        }
    }
}

