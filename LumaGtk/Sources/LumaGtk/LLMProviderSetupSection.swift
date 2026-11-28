import CGtk
import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class LLMProviderSetupSection {
    let widget = Box(orientation: .vertical, spacing: 8)

    private let setup: LLMProviderSetup
    private let providerDropdown = LLMProviderSetupSection.makeStringDropdown(labels: [], selected: 0)
    private let modelDropdown = LLMProviderSetupSection.makeStringDropdown(labels: [], selected: 0)
    private let baseURLEntry = Entry()
    private let baseURLRow = Box(orientation: .vertical, spacing: 4)
    private let apiKeyEntry = Entry()
    private let apiKeyRow = Box(orientation: .vertical, spacing: 4)
    private let apiKeyChecking = Box(orientation: .horizontal, spacing: 8)
    private let apiKeyOnFile = Box(orientation: .horizontal, spacing: 8)
    private var shownProviderIDs: [String] = []
    private var shownModels: LLMProviderSetup.Models?
    private var clearedTypedKey = 0
    private var isRendering = false

    init(setup: LLMProviderSetup, labels: SizeGroup) {
        self.setup = setup

        baseURLEntry.hexpand = true
        apiKeyEntry.hexpand = true
        apiKeyEntry.placeholderText = "API key"
        apiKeyEntry.visibility = false
        apiKeyEntry.add(cssClass: "monospace")

        widget.append(child: Self.formRow(title: "Provider", control: providerDropdown, labels: labels))
        baseURLRow.append(child: Self.formRow(title: "Base URL", control: baseURLEntry, labels: labels))
        widget.append(child: baseURLRow)
        widget.append(child: Self.formRow(title: "Model", control: modelDropdown, labels: labels))

        let apiKeyHint = Label(str: "Stored under the app's data directory. Never written to the project document.")
        apiKeyHint.halign = .start
        apiKeyHint.wrap = true
        apiKeyHint.xalign = 0
        apiKeyHint.add(cssClass: "caption")
        apiKeyHint.add(cssClass: "dim-label")
        apiKeyHint.marginStart = 122
        apiKeyRow.append(child: Self.formRow(title: "API key", control: apiKeyEntry, labels: labels))
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

        widget.append(child: apiKeyRow)
        widget.append(child: apiKeyChecking)
        widget.append(child: apiKeyOnFile)

        providerDropdown.onNotifySelected { [weak self] dropdown, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRendering else { return }
                let index = Int(dropdown.selected)
                guard index >= 0, index < self.shownProviderIDs.count else { return }
                self.setup.selectProvider(self.shownProviderIDs[index])
            }
        }
        modelDropdown.onNotifySelected { [weak self] dropdown, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRendering else { return }
                let index = Int(dropdown.selected)
                let models = self.setup.loadedModels
                guard index >= 0, index < models.count else { return }
                self.setup.selectModel(models[index].id)
            }
        }
        apiKeyEntry.onChanged { [weak self] entry in
            MainActor.assumeIsolated {
                guard let self, !self.isRendering else { return }
                self.setup.type(apiKey: entry.text ?? "")
            }
        }
        baseURLEntry.onChanged { [weak self] entry in
            MainActor.assumeIsolated {
                guard let self, !self.isRendering else { return }
                self.setup.type(baseURL: entry.text ?? "")
            }
        }
        follow()
    }

    static func formRow(title: String, control: Widget, labels: SizeGroup) -> Box {
        let row = Box(orientation: .horizontal, spacing: 12)
        let label = Label(str: title)
        label.halign = .start
        label.xalign = 0
        labels.add(widget: label)
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

    static func makeStringDropdown(labels: [String], selected: Int) -> DropDown {
        let dropdown = DropDown.listing(labels)
        if selected >= 0, selected < labels.count {
            dropdown.selected = selected
        }
        return dropdown
    }

    static func setDropdownLabels(_ dropdown: DropDown, labels: [String], selectedIndex: Int) {
        dropdown.set(model: StringList.listing(labels))
        if selectedIndex >= 0, selectedIndex < labels.count {
            dropdown.selected = selectedIndex
        }
    }

    private func follow() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func render() {
        isRendering = true
        defer { isRendering = false }

        let providers = setup.providers
        let providerIDs = providers.map(\.id)
        let providerIndex = max(0, providerIDs.firstIndex(of: setup.providerID) ?? 0)
        if providerIDs != shownProviderIDs {
            shownProviderIDs = providerIDs
            Self.setDropdownLabels(providerDropdown, labels: providers.map(\.displayName), selectedIndex: providerIndex)
        } else if Int(providerDropdown.selected) != providerIndex {
            providerDropdown.selected = providerIndex
        }

        let descriptor = setup.descriptor
        baseURLRow.visible = setup.supportsCustomBaseURL
        if setup.supportsCustomBaseURL {
            baseURLEntry.placeholderText = descriptor?.defaultBaseURL.absoluteString
        }
        if (baseURLEntry.text ?? "") != setup.baseURL {
            baseURLEntry.text = setup.baseURL
        }

        let name = descriptor?.displayName ?? setup.providerID
        apiKeyEntry.placeholderText = setup.requiresKey ? "API key for \(name)" : "API key for \(name) (optional)"
        if setup.clearsTypedKey != clearedTypedKey {
            clearedTypedKey = setup.clearsTypedKey
            apiKeyEntry.text = ""
        }
        apiKeyChecking.visible = setup.checkingAPIKey
        apiKeyOnFile.visible = !setup.checkingAPIKey && setup.supportsKey && setup.hasStoredAPIKey
        apiKeyRow.visible = !setup.checkingAPIKey && setup.supportsKey && !setup.hasStoredAPIKey

        let models = setup.models
        let modelIndex = max(0, setup.loadedModels.firstIndex { $0.id == setup.modelID } ?? 0)
        if models != shownModels {
            shownModels = models
            switch models {
            case .loading:
                Self.setDropdownLabels(modelDropdown, labels: ["Loading…"], selectedIndex: 0)
            case .failed(let label):
                Self.setDropdownLabels(modelDropdown, labels: [label], selectedIndex: 0)
            case .loaded(let loaded):
                Self.setDropdownLabels(modelDropdown, labels: loaded.isEmpty ? ["(no models)"] : loaded.map(\.displayName), selectedIndex: modelIndex)
            }
        } else if Int(modelDropdown.selected) != modelIndex, !setup.loadedModels.isEmpty {
            modelDropdown.selected = modelIndex
        }
    }
}
