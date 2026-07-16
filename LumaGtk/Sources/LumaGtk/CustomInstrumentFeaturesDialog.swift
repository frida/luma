import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentFeaturesDialog {
    private let engine: Engine
    private var def: CustomInstrumentDef
    private var draftFeatures: [CustomInstrumentDef.Feature]
    private let dialog: Adw.Dialog
    private let listBox: Box
    private let addRowBox: Box
    private let toggleAddButton: Button
    private let idEntry: Entry
    private let nameEntry: Entry
    private var draftKind: SchemaKind = .boolean
    private var nameAutoFilled: Bool = true
    private var suppressIDChange: Bool = false
    private var suppressNameChange: Bool = false
    private var expandedFeatureID: String? = nil
    private var featureSchemaEditors: [CustomInstrumentSchemaEditor] = []
    private var featureBodies: [String: (body: Box, chevron: Button)] = [:]

    init(engine: Engine, def: CustomInstrumentDef) {
        self.engine = engine
        self.def = def
        self.draftFeatures = def.features

        dialog = Adw.Dialog()
        dialog.set(title: "Features")
        dialog.set(followsContentSize: true)

        listBox = Box(orientation: .vertical, spacing: 4)
        addRowBox = Box(orientation: .horizontal, spacing: 8)
        addRowBox.visible = false
        toggleAddButton = Button(label: "+ Add Feature")
        toggleAddButton.halign = .start

        idEntry = Entry()
        idEntry.placeholderText = "id"
        idEntry.setSizeRequest(width: 140, height: -1)

        nameEntry = Entry()
        nameEntry.placeholderText = "Name"
        nameEntry.hexpand = true

        layout()
        rebuildList()
    }

    func present(parent: Gtk.Window) {
        Self.retain(self, dialog: dialog)
        dialog.present(parent: parent)
    }

    private func layout() {
        let scrollContent = Box(orientation: .vertical, spacing: 12)
        scrollContent.marginStart = 16
        scrollContent.marginEnd = 16
        scrollContent.marginTop = 16
        scrollContent.marginBottom = 16
        scrollContent.setSizeRequest(width: 560, height: -1)

        let intro = Label(str: "Per-session knobs the user can configure. Each has a typed schema (boolean, number, string, regex, combo, object, array, …). Agent code reads `config.features.<id>` directly; optional features may be undefined when the user has disabled them.")
        intro.add(cssClass: "dim-label")
        intro.wrap = true
        intro.xalign = 0
        intro.maxWidthChars = 60
        scrollContent.append(child: intro)

        scrollContent.append(child: listBox)
        populateAddRow()
        scrollContent.append(child: addRowBox)
        toggleAddButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleAdding() }
        }
        scrollContent.append(child: toggleAddButton)

        let scroll = ScrolledWindow()
        scroll.set(child: scrollContent)
        scroll.propagateNaturalHeight = true
        scroll.propagateNaturalWidth = true
        scroll.maxContentHeight = 600
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)

        let header = Adw.HeaderBar()
        let saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
        header.packEnd(child: saveButton)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: scroll)

        dialog.set(child: toolbarView)
    }

    private func populateAddRow() {
        addRowBox.append(child: idEntry)
        addRowBox.append(child: nameEntry)
        let kindDropdown = makeKindDropdown(initial: draftKind) { [weak self] kind in
            self?.draftKind = kind
        }
        addRowBox.append(child: kindDropdown)
        let addButton = Button(label: "Add")
        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.appendFeature() }
        }
        idEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.appendFeature() }
        }
        nameEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.appendFeature() }
        }
        idEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleIDChanged() }
        }
        nameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleNameChanged() }
        }
        addRowBox.append(child: addButton)
    }

    private func handleIDChanged() {
        guard !suppressIDChange else { return }
        let raw = idEntry.text ?? ""
        let lowered = CamelCase.sanitized(raw)
        if lowered != raw {
            suppressIDChange = true
            idEntry.text = lowered
            suppressIDChange = false
            return
        }
        if nameAutoFilled {
            suppressNameChange = true
            nameEntry.text = CamelCase.humanized(lowered)
            suppressNameChange = false
        }
    }

    private func handleNameChanged() {
        guard !suppressNameChange else { return }
        if (nameEntry.text ?? "") != CamelCase.humanized(idEntry.text ?? "") {
            nameAutoFilled = false
        }
    }

    private func toggleAdding() {
        let nowVisible = !addRowBox.visible
        if !nowVisible {
            appendFeature()
        }
        addRowBox.visible = nowVisible
        toggleAddButton.label = nowVisible ? "Done Adding" : "+ Add Feature"
        if nowVisible {
            applyExpansion(to: nil)
            _ = idEntry.grabFocus()
        } else {
            resetDraft()
        }
    }

    private func appendFeature() {
        let id = (idEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        let name = (nameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !draftFeatures.contains(where: { $0.id == id }) else { return }
        let kindHasChildren = draftKind.hasChildren
        draftFeatures.append(
            .init(
                id: id,
                name: name,
                schema: draftKind.defaultSchema(),
                optional: false
            )
        )
        expandedFeatureID = kindHasChildren ? id : nil
        resetDraft()
        rebuildList()
        if kindHasChildren {
            addRowBox.visible = false
            toggleAddButton.label = "+ Add Feature"
        } else {
            _ = idEntry.grabFocus()
        }
    }

    private func resetDraft() {
        suppressIDChange = true
        idEntry.text = ""
        suppressIDChange = false
        suppressNameChange = true
        nameEntry.text = ""
        suppressNameChange = false
        nameAutoFilled = true
    }

    private func commit() {
        if addRowBox.visible {
            appendFeature()
        }
        var updated = def
        updated.features = draftFeatures
        let engine = self.engine
        let dialog = self.dialog
        Task { @MainActor in
            engine.updateCustomInstrument(updated)
            _ = dialog.close()
        }
    }

    private func rebuildList() {
        while let child = listBox.firstChild {
            listBox.remove(child: child)
        }
        featureSchemaEditors.removeAll()
        featureBodies.removeAll()
        if draftFeatures.isEmpty {
            let empty = Label(str: "No features defined.")
            empty.add(cssClass: "dim-label")
            empty.halign = .start
            listBox.append(child: empty)
            return
        }
        for (index, feature) in draftFeatures.enumerated() {
            listBox.append(child: featureRow(feature: feature, index: index))
        }
    }

    private func featureRow(feature: CustomInstrumentDef.Feature, index: Int) -> Box {
        let card = Box(orientation: .vertical, spacing: 0)
        card.add(cssClass: "card")

        let column = Box(orientation: .vertical, spacing: 6)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12
        card.append(child: column)

        let booleanFeature = isBoolean(feature.schema)
        let isExpanded = expandedFeatureID == feature.id
        let featureID = feature.id

        let chevronButton = Button()
        chevronButton.add(cssClass: "flat")
        chevronButton.set(iconName: isExpanded ? "pan-down-symbolic" : "pan-end-symbolic")
        chevronButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let newID: String? = (self.expandedFeatureID == featureID) ? nil : featureID
                self.applyExpansion(to: newID)
            }
        }

        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: chevronButton)

        let idLabel = Label(str: feature.id)
        idLabel.halign = .start
        header.append(child: idLabel)

        let dash = Label(str: "—")
        dash.add(cssClass: "dim-label")
        header.append(child: dash)

        let nameLabel = Label(str: feature.name)
        nameLabel.halign = .start
        nameLabel.hexpand = true
        header.append(child: nameLabel)

        let kindDropdown = makeKindDropdown(initial: SchemaKind(from: feature.schema)) { [weak self] kind in
            guard let self, index < self.draftFeatures.count else { return }
            let newSchema = kind.defaultSchema()
            self.draftFeatures[index].schema = newSchema
            if self.isBoolean(newSchema), self.draftFeatures[index].optional {
                self.draftFeatures[index].optional = false
            }
            self.expandedFeatureID = self.draftFeatures[index].id
            self.rebuildList()
        }
        header.append(child: kindDropdown)

        let removeButton = Button(label: "Remove")
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.draftFeatures.count else { return }
                let removedID = self.draftFeatures[index].id
                self.draftFeatures.remove(at: index)
                if self.expandedFeatureID == removedID { self.expandedFeatureID = nil }
                self.rebuildList()
            }
        }
        header.append(child: removeButton)
        column.append(child: header)

        let body = Box(orientation: .vertical, spacing: 6)
        body.visible = isExpanded

        let optionalRow = Box(orientation: .horizontal, spacing: 8)
        let optionalToggle = Switch()
        optionalToggle.active = feature.optional
        optionalToggle.valign = .center
        optionalRow.append(child: optionalToggle)
        let optionalLabel = Label(str: "Optional (user can disable)")
        optionalLabel.halign = .start
        optionalRow.append(child: optionalLabel)
        optionalRow.visible = !booleanFeature

        let enabledRow = Box(orientation: .horizontal, spacing: 8)
        let enabledToggle = Switch()
        enabledToggle.active = feature.enabledByDefault
        enabledToggle.valign = .center
        enabledRow.append(child: enabledToggle)
        let enabledLabel = Label(str: "Enabled by default")
        enabledLabel.halign = .start
        enabledRow.append(child: enabledLabel)
        enabledRow.visible = !booleanFeature && feature.optional

        let editor = CustomInstrumentSchemaEditor(schema: feature.schema) { [weak self] updated in
            MainActor.assumeIsolated {
                guard let self, index < self.draftFeatures.count else { return }
                self.draftFeatures[index].schema = updated
            }
        }
        featureSchemaEditors.append(editor)

        optionalToggle.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                guard let self, index < self.draftFeatures.count else { return false }
                self.draftFeatures[index].optional = state
                enabledRow.visible = state
                return false
            }
        }
        enabledToggle.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                guard let self, index < self.draftFeatures.count else { return false }
                self.draftFeatures[index].enabledByDefault = state
                return false
            }
        }

        body.append(child: optionalRow)
        body.append(child: enabledRow)
        body.append(child: editor.widget)
        column.append(child: body)

        featureBodies[featureID] = (body, chevronButton)

        return card
    }

    private func isBoolean(_ schema: FeatureSchema) -> Bool {
        if case .boolean = schema { return true }
        return false
    }

    private func applyExpansion(to newID: String?) {
        expandedFeatureID = newID
        for (rowID, entry) in featureBodies {
            let shouldExpand = newID == rowID
            entry.body.visible = shouldExpand
            entry.chevron.set(iconName: shouldExpand ? "pan-down-symbolic" : "pan-end-symbolic")
        }
    }

    private static func retain(_ owner: CustomInstrumentFeaturesDialog, dialog: Adw.Dialog) {
        let key = ObjectIdentifier(dialog)
        retained[key] = owner
        dialog.onClosed { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
        }
    }

    private static var retained: [ObjectIdentifier: CustomInstrumentFeaturesDialog] = [:]
}
