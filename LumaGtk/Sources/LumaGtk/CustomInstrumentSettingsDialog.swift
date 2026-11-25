import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentSettingsDialog {
    private let engine: Engine
    private let def: CustomInstrumentDef
    private var draftSettings: [CustomInstrumentDef.Setting]
    private let dialog: Adw.Dialog
    private let listBox: Box
    private let addRowBox: Box
    private let toggleAddButton: Button
    private let idEntry: Entry
    private let nameEntry: Entry
    private let addButton = Button(label: "Add")
    private var addKindDropdown: DropDown?
    private var draftKind: SchemaKind = .boolean
    private var nameAutoFilled: Bool = true
    private var suppressIDChange: Bool = false
    private var suppressNameChange: Bool = false
    private var expandedSettingID: String? = nil
    private var settingSchemaEditors: [CustomInstrumentSchemaEditor] = []
    private var settingBodies: [String: (body: Box, chevron: Button)] = [:]

    init(engine: Engine, def: CustomInstrumentDef) {
        self.engine = engine
        self.def = def
        self.draftSettings = def.settings

        dialog = Adw.Dialog()
        dialog.set(title: "Settings")
        dialog.set(followsContentSize: true)

        listBox = Box(orientation: .vertical, spacing: 4)
        addRowBox = Box(orientation: .horizontal, spacing: 8)
        addRowBox.visible = false
        toggleAddButton = CustomInstrumentEditorChrome.addToggle("Add Setting", isAdding: false)

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
        dialog.own(self)
        dialog.present(parent: parent)
    }

    private func layout() {
        let scrollContent = Box(orientation: .vertical, spacing: 12)
        scrollContent.marginStart = 16
        scrollContent.marginEnd = 16
        scrollContent.marginTop = 16
        scrollContent.marginBottom = 16
        scrollContent.setSizeRequest(width: 560, height: -1)

        let intro = Label(str: "Per-session knobs the user can configure. Each has a typed schema (boolean, number, string, regex, combo, object, array, …). Agent code reads `config.settings.<id>` directly; optional settings may be undefined when the user has disabled them.")
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

        let header = CustomInstrumentEditorChrome.header(
            onCancel: { [weak self] in self?.close() },
            onSave: { [weak self] in self?.commit() }
        )

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
        addKindDropdown = kindDropdown
        addRowBox.append(child: kindDropdown)
        addButton.sensitive = false
        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.appendSetting() }
        }
        idEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.appendSetting() }
        }
        nameEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.appendSetting() }
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
        refreshAddEnabled()
    }

    private func handleNameChanged() {
        refreshAddEnabled()
        guard !suppressNameChange else { return }
        if (nameEntry.text ?? "") != CamelCase.humanized(idEntry.text ?? "") {
            nameAutoFilled = false
        }
    }

    private func refreshAddEnabled() {
        let id = (idEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        let name = (nameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        addButton.sensitive = !id.isEmpty && !name.isEmpty
    }

    private func toggleAdding() {
        let nowVisible = !addRowBox.visible
        if !nowVisible {
            appendSetting()
        }
        addRowBox.visible = nowVisible
        CustomInstrumentEditorChrome.setAddToggle(toggleAddButton, label: "Add Setting", isAdding: nowVisible)
        if nowVisible {
            applyExpansion(to: nil)
            _ = idEntry.grabFocus()
        } else {
            resetDraft()
            resetKind()
        }
    }

    private func appendSetting() {
        let id = (idEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        let name = (nameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !draftSettings.contains(where: { $0.id == id }) else { return }
        let kindHasChildren = draftKind.hasChildren
        draftSettings.append(
            .init(
                id: id,
                name: name,
                schema: draftKind.defaultSchema(),
                optional: false
            )
        )
        expandedSettingID = kindHasChildren ? id : nil
        resetDraft()
        rebuildList()
        if kindHasChildren {
            addRowBox.visible = false
            CustomInstrumentEditorChrome.setAddToggle(toggleAddButton, label: "Add Setting", isAdding: false)
            resetKind()
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

    private func resetKind() {
        addKindDropdown?.selected = SchemaKind.boolean.index
    }

    private func commit() {
        if addRowBox.visible {
            appendSetting()
        }
        let settings = draftSettings
        engine.updateCustomInstrument(def.id) { $0.settings = settings }
        close()
    }

    private func close() {
        _ = dialog.close()
    }

    private func rebuildList() {
        while let child = listBox.firstChild {
            listBox.remove(child: child)
        }
        settingSchemaEditors.removeAll()
        settingBodies.removeAll()
        if draftSettings.isEmpty {
            let empty = Label(str: "No settings defined.")
            empty.add(cssClass: "dim-label")
            empty.halign = .start
            listBox.append(child: empty)
            return
        }
        for (index, setting) in draftSettings.enumerated() {
            listBox.append(child: settingRow(setting: setting, index: index))
        }
    }

    private func settingRow(setting: CustomInstrumentDef.Setting, index: Int) -> Box {
        let card = Box(orientation: .vertical, spacing: 0)
        card.add(cssClass: "card")

        let column = Box(orientation: .vertical, spacing: 6)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12
        card.append(child: column)

        let booleanSetting = isBoolean(setting.schema)
        let isExpanded = expandedSettingID == setting.id
        let settingID = setting.id

        let chevronButton = Button()
        chevronButton.add(cssClass: "flat")
        chevronButton.set(iconName: isExpanded ? "pan-down-symbolic" : "pan-end-symbolic")
        chevronButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let newID: String? = (self.expandedSettingID == settingID) ? nil : settingID
                self.applyExpansion(to: newID)
            }
        }

        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: chevronButton)

        let idLabel = Label(str: setting.id)
        idLabel.halign = .start
        header.append(child: idLabel)

        let dash = Label(str: "—")
        dash.add(cssClass: "dim-label")
        header.append(child: dash)

        let nameLabel = Label(str: setting.name)
        nameLabel.halign = .start
        nameLabel.hexpand = true
        header.append(child: nameLabel)

        let kindDropdown = makeKindDropdown(initial: SchemaKind(from: setting.schema)) { [weak self] kind in
            guard let self, index < self.draftSettings.count else { return }
            let newSchema = kind.defaultSchema()
            self.draftSettings[index].schema = newSchema
            if self.isBoolean(newSchema), self.draftSettings[index].optional {
                self.draftSettings[index].optional = false
            }
            self.expandedSettingID = self.draftSettings[index].id
            self.rebuildList()
        }
        header.append(child: kindDropdown)

        let removeButton = CustomInstrumentEditorChrome.iconButton("list-remove-symbolic", tooltip: "Remove")
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.draftSettings.count else { return }
                let removedID = self.draftSettings[index].id
                self.draftSettings.remove(at: index)
                if self.expandedSettingID == removedID { self.expandedSettingID = nil }
                self.rebuildList()
            }
        }
        header.append(child: removeButton)
        column.append(child: header)

        let body = Box(orientation: .vertical, spacing: 6)
        body.visible = isExpanded

        let optionalRow = Box(orientation: .horizontal, spacing: 8)
        let optionalToggle = Switch()
        optionalToggle.active = setting.optional
        optionalToggle.valign = .center
        optionalRow.append(child: optionalToggle)
        let optionalLabel = Label(str: "Optional (user can disable)")
        optionalLabel.halign = .start
        optionalRow.append(child: optionalLabel)
        optionalRow.visible = !booleanSetting

        let enabledRow = Box(orientation: .horizontal, spacing: 8)
        let enabledToggle = Switch()
        enabledToggle.active = setting.enabledByDefault
        enabledToggle.valign = .center
        enabledRow.append(child: enabledToggle)
        let enabledLabel = Label(str: "Enabled by default")
        enabledLabel.halign = .start
        enabledRow.append(child: enabledLabel)
        enabledRow.visible = !booleanSetting && setting.optional

        let editor = CustomInstrumentSchemaEditor(schema: setting.schema) { [weak self] updated in
            MainActor.assumeIsolated {
                guard let self, index < self.draftSettings.count else { return }
                self.draftSettings[index].schema = updated
            }
        }
        settingSchemaEditors.append(editor)

        optionalToggle.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                guard let self, index < self.draftSettings.count else { return false }
                self.draftSettings[index].optional = state
                enabledRow.visible = state
                return false
            }
        }
        enabledToggle.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                guard let self, index < self.draftSettings.count else { return false }
                self.draftSettings[index].enabledByDefault = state
                return false
            }
        }

        body.append(child: optionalRow)
        body.append(child: enabledRow)
        body.append(child: editor.widget)
        column.append(child: body)

        settingBodies[settingID] = (body, chevronButton)

        return card
    }

    private func isBoolean(_ schema: SettingSchema) -> Bool {
        if case .boolean = schema { return true }
        return false
    }

    private func applyExpansion(to newID: String?) {
        expandedSettingID = newID
        for (rowID, entry) in settingBodies {
            let shouldExpand = newID == rowID
            entry.body.visible = shouldExpand
            entry.chevron.set(iconName: shouldExpand ? "pan-down-symbolic" : "pan-end-symbolic")
        }
    }

}
