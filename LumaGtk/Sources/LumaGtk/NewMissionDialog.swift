import Adw
import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class NewMissionDialog {
    typealias OnCreated = (Mission) -> Void

    private let dialog: Adw.Dialog
    private let parentWindow: Gtk.Window
    private weak var engine: Engine?
    private let onCreated: OnCreated

    private let goalView: TextView
    private let goalScroll: ScrolledWindow
    private let providerDropdown: DropDown
    private let modelDropdown: DropDown
    private let inputBudgetSpin: SpinButton
    private let outputBudgetSpin: SpinButton
    private let thinkingSwitch: Switch
    private let thinkingBudgetSpin: SpinButton
    private let thinkingBudgetRow: Box
    private let thinkingSection: Box
    private let reasoningDropdown: DropDown
    private let reasoningRow: Box
    private let apiKeyEntry: Entry
    private let apiKeyRow: Box
    private let apiKeyChecking: Box
    private let apiKeyOnFile: Box
    private let baseURLEntry: Entry
    private let baseURLRow: Box
    private let startButton: Button
    private let cancelButton: Button
    private let footerError: Label

    private var providerIDs: [String] = []
    private var modelsForProvider: [LLMModelInfo] = []
    private var selectedProviderID: String
    private var selectedModelID: String
    private var hasStoredAPIKey: Bool = false
    private var checkingAPIKey: Bool = false
    private var isStarting: Bool = false
    private var apiKeyDebounce: Task<Void, Never>?
    private var baseURLDebounce: Task<Void, Never>?
    private var modelsLoadGeneration = 0
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
        selectedProviderID = defaults.providerID
        selectedModelID = defaults.modelID
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

        providerDropdown = NewMissionDialog.makeStringDropdown(labels: [], selected: 0)
        modelDropdown = NewMissionDialog.makeStringDropdown(labels: [], selected: 0)

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

        reasoningDropdown = NewMissionDialog.makeStringDropdown(labels: [], selected: 0)
        reasoningRow = Box(orientation: .horizontal, spacing: 12)

        apiKeyEntry = Entry()
        apiKeyEntry.hexpand = true
        apiKeyEntry.placeholderText = "API key"
        apiKeyEntry.visibility = false
        apiKeyEntry.add(cssClass: "monospace")

        apiKeyRow = Box(orientation: .vertical, spacing: 4)
        apiKeyChecking = Box(orientation: .horizontal, spacing: 8)
        apiKeyOnFile = Box(orientation: .horizontal, spacing: 8)

        baseURLEntry = Entry()
        baseURLEntry.hexpand = true
        baseURLEntry.text = LumaAppState.shared.providerBaseURL(providerID: selectedProviderID) ?? ""
        baseURLRow = Box(orientation: .vertical, spacing: 4)

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

        populateProviders()
        applyProviderSelection(animatePicker: false)

        providerDropdown.onNotifySelected { [weak self] dropdown, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let idx = Int(dropdown.selected)
                guard idx >= 0, idx < self.providerIDs.count else { return }
                self.selectedProviderID = self.providerIDs[idx]
                self.apiKeyEntry.text = ""
                self.baseURLEntry.text = LumaAppState.shared.providerBaseURL(providerID: self.selectedProviderID) ?? ""
                self.baseURLDebounce?.cancel()
                self.applyProviderSelection(animatePicker: true)
            }
        }
        modelDropdown.onNotifySelected { [weak self] dropdown, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let idx = Int(dropdown.selected)
                guard idx >= 0, idx < self.modelsForProvider.count else { return }
                self.selectedModelID = self.modelsForProvider[idx].id
                self.refreshStartSensitivity()
            }
        }
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
        apiKeyEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStartSensitivity()
                self?.scheduleAPIKeyRefresh()
            }
        }
        baseURLEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleBaseURLRefresh() }
        }
        if let buffer = goalView.buffer {
            buffer.onChanged { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStartSensitivity() }
            }
        }
        thinkingBudgetRow.visible = thinkingSwitch.active
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

        let modelGroup = Box(orientation: .vertical, spacing: 8)
        modelGroup.append(child: formRow(title: "Provider", control: providerDropdown))
        baseURLRow.append(child: formRow(title: "Base URL", control: baseURLEntry))
        modelGroup.append(child: baseURLRow)
        baseURLRow.visible = false
        modelGroup.append(child: formRow(title: "Model", control: modelDropdown))
        let apiKeyHint = Label(
            str: "Stored under the app's data directory. Never written to the project document."
        )
        apiKeyHint.halign = .start
        apiKeyHint.wrap = true
        apiKeyHint.xalign = 0
        apiKeyHint.add(cssClass: "caption")
        apiKeyHint.add(cssClass: "dim-label")

        apiKeyHint.marginStart = 122
        apiKeyRow.append(child: formRow(title: "API key", control: apiKeyEntry))
        apiKeyRow.append(child: apiKeyHint)

        let checkingSpinner = Gtk.Spinner()
        checkingSpinner.spinning = true
        apiKeyChecking.append(child: checkingSpinner)
        let checkingLabel = Label(str: "Checking saved API key…")
        checkingLabel.halign = .start
        checkingLabel.add(cssClass: "dim-label")
        apiKeyChecking.append(child: checkingLabel)
        apiKeyChecking.marginTop = 4

        let onFileIcon = Gtk.Image(iconName: "object-select-symbolic")
        onFileIcon.pixelSize = 14
        onFileIcon.add(cssClass: "success")
        apiKeyOnFile.append(child: onFileIcon)
        let onFileLabel = Label(str: "API key on file")
        onFileLabel.halign = .start
        onFileLabel.add(cssClass: "success")
        apiKeyOnFile.append(child: onFileLabel)
        apiKeyOnFile.marginTop = 4
        apiKeyOnFile.marginStart = 4

        modelGroup.append(child: apiKeyRow)
        modelGroup.append(child: apiKeyChecking)
        modelGroup.append(child: apiKeyOnFile)
        apiKeyRow.visible = false
        apiKeyChecking.visible = false
        apiKeyOnFile.visible = false

        outer.append(child: section(title: "Model", child: modelGroup, hint: nil))

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
        thinkingTitle.setSizeRequest(width: 140, height: -1)
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
        let row = Box(orientation: .horizontal, spacing: 12)
        let label = Label(str: title)
        label.halign = .start
        label.setSizeRequest(width: 110, height: -1)
        row.append(child: label)
        control.hexpand = true
        if let entry = control as? Entry {
            entry.halign = .fill
        }
        if let dropdown = control as? DropDown {
            dropdown.halign = .fill
        }
        if let spin = control as? SpinButton {
            spin.halign = .end
        }
        row.append(child: control)
        return row
    }

    private static func makeStringDropdown(labels: [String], selected: Int) -> DropDown {
        let cStrings = labels.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        ptrs.append(nil)
        let widgetPtr = ptrs.withUnsafeBufferPointer { buf in
            gtk_drop_down_new_from_strings(buf.baseAddress)
        }!
        g_object_ref_sink(UnsafeMutableRawPointer(widgetPtr))
        let dropdown = DropDown(raw: UnsafeMutableRawPointer(widgetPtr))
        if selected >= 0, selected < labels.count {
            dropdown.selected = selected
        }
        return dropdown
    }

    private func setDropdownLabels(
        _ dropdown: DropDown,
        labels: [String],
        selectedIndex: Int
    ) {
        let cStrings = labels.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        ptrs.append(nil)
        ptrs.withUnsafeBufferPointer { buf in
            let stringList = StringList(strings: buf.baseAddress)
            dropdown.set(model: stringList)
        }
        if selectedIndex >= 0, selectedIndex < labels.count {
            dropdown.selected = selectedIndex
        }
    }

    private func populateProviders() {
        guard let engine else { return }
        let descriptors = engine.llmRegistry.descriptors()
        providerIDs = descriptors.map(\.id)
        let labels = descriptors.map(\.displayName)
        let initial = max(0, providerIDs.firstIndex(of: selectedProviderID) ?? 0)
        if initial < providerIDs.count {
            selectedProviderID = providerIDs[initial]
        }
        setDropdownLabels(providerDropdown, labels: labels, selectedIndex: initial)
    }

    private func applyProviderSelection(animatePicker: Bool) {
        guard let engine, let provider = engine.llmRegistry.provider(id: selectedProviderID) else {
            return
        }
        let descriptor = provider.descriptor

        let supportsCustomBaseURL = descriptor.capabilities.supports(.customBaseURL)
        baseURLRow.visible = supportsCustomBaseURL
        if supportsCustomBaseURL {
            baseURLEntry.placeholderText = descriptor.defaultBaseURL.absoluteString
        }
        let configuredBaseURL = effectiveBaseURL()
        let requiresKey = descriptor.capabilities.supports(.apiKey)
        let supportsKey = requiresKey || descriptor.capabilities.supports(.optionalAPIKey)
        let typedKey = trimmedAPIKey

        reasoningEffortOptions = descriptor.capabilities.reasoningEffortOptions
        let hasReasoningOptions = !reasoningEffortOptions.isEmpty
        reasoningRow.visible = hasReasoningOptions
        if hasReasoningOptions {
            if !reasoningEffortOptions.contains(selectedReasoningEffort) {
                selectedReasoningEffort = descriptor.capabilities.defaultReasoningEffort ?? reasoningEffortOptions.first ?? "auto"
            }
            let idx = reasoningEffortOptions.firstIndex(of: selectedReasoningEffort) ?? 0
            setDropdownLabels(reasoningDropdown, labels: reasoningEffortOptions, selectedIndex: idx)
        }
        apiKeyEntry.placeholderText =
            requiresKey
            ? "API key for \(descriptor.displayName)"
            : "API key for \(descriptor.displayName) (optional)"

        thinkingSection.visible = !hasReasoningOptions && descriptor.capabilities.supports(.thinking)
        if !thinkingSection.visible {
            thinkingBudgetRow.visible = false
        } else {
            thinkingBudgetRow.visible = thinkingSwitch.active
        }

        modelsForProvider = []
        hasStoredAPIKey = false
        apiKeyOnFile.visible = false
        apiKeyRow.visible = false

        if supportsKey {
            checkingAPIKey = true
            apiKeyChecking.visible = true
        } else {
            apiKeyChecking.visible = false
        }
        setDropdownLabels(modelDropdown, labels: ["Loading…"], selectedIndex: 0)

        let providerID = selectedProviderID
        let credentials = engine.llmCredentials
        modelsLoadGeneration += 1
        let generation = modelsLoadGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let storedKey = (try? await credentials.apiKey(providerID: providerID)) ?? nil
            let hasStored = (storedKey?.isEmpty == false)
            guard self.modelsLoadGeneration == generation else { return }
            self.applyAPIKeyStatus(supportsKey: supportsKey, hasStored: hasStored)

            let effectiveKey = !typedKey.isEmpty ? typedKey : storedKey
            let models: [LLMModelInfo]
            do {
                models = try await provider.suggestedModels(apiKey: effectiveKey, baseURL: configuredBaseURL)
            } catch {
                guard self.modelsLoadGeneration == generation else { return }
                let hadKey = effectiveKey?.isEmpty == false
                let label: String
                if requiresKey && !hadKey {
                    label = "Enter API key to load models"
                } else {
                    label = describeModelFetchError(error, baseURL: configuredBaseURL ?? provider.descriptor.defaultBaseURL)
                }
                self.setDropdownLabels(self.modelDropdown, labels: [label], selectedIndex: 0)
                self.refreshStartSensitivity()
                return
            }
            guard self.modelsLoadGeneration == generation else { return }
            self.installModels(models, descriptor: descriptor)
            if !typedKey.isEmpty, !hasStored {
                try? await credentials.setAPIKey(typedKey, providerID: providerID)
                guard self.modelsLoadGeneration == generation else { return }
                self.applyAPIKeyStatus(supportsKey: supportsKey, hasStored: true)
                self.apiKeyEntry.text = ""
                self.apiKeyDebounce?.cancel()
            }
            self.refreshStartSensitivity()
        }

        refreshStartSensitivity()
    }

    private func scheduleAPIKeyRefresh() {
        apiKeyDebounce?.cancel()
        let key = trimmedAPIKey
        guard key.isEmpty || key.count >= 16 else { return }
        apiKeyDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            self?.reloadModels(persistTypedKeyOnSuccess: true)
        }
    }

    private func scheduleBaseURLRefresh() {
        baseURLDebounce?.cancel()
        baseURLDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            guard let self else { return }
            let text = (self.baseURLEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            LumaAppState.shared.setProviderBaseURL(text, providerID: self.selectedProviderID)
            self.reloadModels()
        }
    }

    private func reloadModels(persistTypedKeyOnSuccess: Bool = false) {
        guard let engine, let provider = engine.llmRegistry.provider(id: selectedProviderID) else {
            return
        }
        let descriptor = provider.descriptor
        let configuredBaseURL = effectiveBaseURL()
        let requiresKey = descriptor.capabilities.supports(.apiKey)
        let typedKey = trimmedAPIKey

        modelsForProvider = []
        setDropdownLabels(modelDropdown, labels: ["Loading…"], selectedIndex: 0)

        let providerID = selectedProviderID
        let credentials = engine.llmCredentials
        modelsLoadGeneration += 1
        let generation = modelsLoadGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let storedKey = (try? await credentials.apiKey(providerID: providerID)) ?? nil
            let effectiveKey = !typedKey.isEmpty ? typedKey : storedKey
            do {
                let models = try await provider.suggestedModels(apiKey: effectiveKey, baseURL: configuredBaseURL)
                guard self.modelsLoadGeneration == generation else { return }
                self.installModels(models, descriptor: descriptor)
                if persistTypedKeyOnSuccess, !typedKey.isEmpty {
                    try? await credentials.setAPIKey(typedKey, providerID: providerID)
                    guard self.modelsLoadGeneration == generation else { return }
                    self.applyAPIKeyStatus(supportsKey: true, hasStored: true)
                    self.apiKeyEntry.text = ""
                    self.apiKeyDebounce?.cancel()
                }
            } catch {
                guard self.modelsLoadGeneration == generation else { return }
                let hadKey = effectiveKey?.isEmpty == false
                let label =
                    requiresKey && !hadKey
                    ? "Enter API key to load models"
                    : describeModelFetchError(error, baseURL: configuredBaseURL ?? descriptor.defaultBaseURL)
                self.setDropdownLabels(self.modelDropdown, labels: [label], selectedIndex: 0)
            }
            self.refreshStartSensitivity()
        }
    }

    private func applyAPIKeyStatus(supportsKey: Bool, hasStored: Bool) {
        checkingAPIKey = false
        apiKeyChecking.visible = false
        guard supportsKey else {
            apiKeyRow.visible = false
            apiKeyOnFile.visible = false
            hasStoredAPIKey = false
            return
        }
        hasStoredAPIKey = hasStored
        apiKeyOnFile.visible = hasStored
        apiKeyRow.visible = !hasStored
    }

    private func installModels(_ models: [LLMModelInfo], descriptor: LLMProviderDescriptor) {
        modelsForProvider = models
        let labels = models.map(\.displayName)
        var index = models.firstIndex(where: { $0.id == selectedModelID }) ?? -1
        if index < 0 {
            if let defaultID = descriptor.defaultModelID,
                let i = models.firstIndex(where: { $0.id == defaultID })
            {
                index = i
            } else if !models.isEmpty {
                index = 0
            }
        }
        if index >= 0, index < models.count {
            selectedModelID = models[index].id
        }
        setDropdownLabels(modelDropdown, labels: labels.isEmpty ? ["(no models)"] : labels, selectedIndex: max(0, index))
    }

    private func refreshStartSensitivity() {
        let hasGoal = !trimmedGoal.isEmpty
        let providerOK: Bool
        if currentProviderRequiresKey {
            providerOK = hasStoredAPIKey || !trimmedAPIKey.isEmpty
        } else {
            providerOK = true
        }
        startButton.sensitive = !isStarting && hasGoal && providerOK && !modelsForProvider.isEmpty
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

    private var trimmedAPIKey: String {
        (apiKeyEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentProviderSupportsCustomBaseURL: Bool {
        engine?.llmRegistry.provider(id: selectedProviderID)?.descriptor.capabilities.supports(.customBaseURL)
            ?? false
    }

    private func effectiveBaseURL() -> URL? {
        guard currentProviderSupportsCustomBaseURL else { return nil }
        let trimmed = (baseURLEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private var currentProviderRequiresKey: Bool {
        engine?.llmRegistry.provider(id: selectedProviderID)?.descriptor.capabilities.supports(.apiKey)
            ?? false
    }

    private var currentProviderSupportsKey: Bool {
        guard let capabilities = engine?.llmRegistry.provider(id: selectedProviderID)?.descriptor.capabilities else {
            return false
        }
        return capabilities.supports(.apiKey) || capabilities.supports(.optionalAPIKey)
    }

    private func start() {
        guard let engine else { return }
        let goal = trimmedGoal
        guard !goal.isEmpty else { return }

        let providerID = selectedProviderID
        let modelID = selectedModelID
        let inputBudget = Int(inputBudgetSpin.value)
        let outputBudget = Int(outputBudgetSpin.value)
        let thinkingEnabled = thinkingSwitch.active
        let thinkingBudget = Int(thinkingBudgetSpin.value)
        let baseURLText = (baseURLEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let supportsCustomBaseURL = currentProviderSupportsCustomBaseURL
        let reasoningEffort = reasoningEffortOptions.isEmpty ? nil : selectedReasoningEffort

        isStarting = true
        startButton.sensitive = false
        startButton.label = "Starting…"

        let onCreated = self.onCreated
        let parent = self.parentWindow
        _ = parent
        let dialog = self.dialog
        let needsKey = currentProviderSupportsKey && !hasStoredAPIKey
        let providedKey = trimmedAPIKey

        Task { @MainActor in
            if needsKey, !providedKey.isEmpty {
                try? await engine.llmCredentials.setAPIKey(providedKey, providerID: providerID)
            }

            LumaAppState.shared.missionDefaults = .init(
                providerID: providerID,
                modelID: modelID,
                tokenBudgetInput: inputBudget,
                tokenBudgetOutput: outputBudget,
                thinkingEnabled: thinkingEnabled,
                thinkingBudget: thinkingBudget,
                reasoningEffort: reasoningEffort
            )
            if supportsCustomBaseURL {
                LumaAppState.shared.setProviderBaseURL(baseURLText, providerID: providerID)
            }

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

