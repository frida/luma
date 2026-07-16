import Adw
import CGtk
import Foundation
import GLibObject
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentSchemaEditor {
    let widget: Box
    private(set) var schema: FeatureSchema
    private let onChanged: (FeatureSchema) -> Void
    private let fieldsBox: Box
    private var childEditors: [AnyObject] = []

    init(schema: FeatureSchema, onChanged: @escaping (FeatureSchema) -> Void) {
        self.schema = schema
        self.onChanged = onChanged

        widget = Box(orientation: .vertical, spacing: 6)
        widget.hexpand = true
        fieldsBox = Box(orientation: .vertical, spacing: 4)
        widget.append(child: fieldsBox)
        rebuildFields()
    }

    func updateSchema(_ newSchema: FeatureSchema) {
        guard schema != newSchema else { return }
        schema = newSchema
        rebuildFields()
    }

    fileprivate func handleArrayItemKindChanged(_ index: Int) {
        let kinds = ArrayItemKind.allCases
        guard index >= 0, index < kinds.count else { return }
        let newKind = kinds[index]
        if case .array(let item, _) = schema, ArrayItemKind(from: item) == newKind { return }
        schema = .array(item: newKind.defaultItemSchema(), default: [])
        rebuildFields()
        onChanged(schema)
    }

    fileprivate func handleComboDefaultChanged(_ index: Int) {
        guard case .combo(let choices, _) = schema else { return }
        let pick: String? = (index <= 0) ? nil : (index <= choices.count ? choices[index - 1].id : nil)
        schema = .combo(choices: choices, default: pick)
        onChanged(schema)
    }

    private func rebuildFields() {
        clearChildren(of: fieldsBox)
        childEditors.removeAll()

        switch schema {
        case .boolean(let d):
            fieldsBox.append(child: booleanDefaultRow(value: d))
        case .int, .uint, .double:
            appendNumericRows()
        case .string(let d):
            fieldsBox.append(child: textRow(label: "Default", value: d, monospaced: false) { [weak self] text in
                self?.applyStringDefault(text)
            })
        case .regex(let d):
            fieldsBox.append(child: textRow(label: "Default", value: d, monospaced: true) { [weak self] text in
                self?.applyRegexDefault(text)
            })
        case .combo(let choices, let def):
            appendComboFields(choices: choices, defaultChoice: def)
        case .object(let fields):
            appendObjectFields(fields: fields)
        case .array(let item, _):
            appendArrayFields(item: item)
        }
    }

    private func appendNumericRows() {
        fieldsBox.append(child: numericRow(label: "Default", initialText: numericDefaultText()) { [weak self] text in
            self?.applyNumericDefault(text)
        })
        fieldsBox.append(child: numericRow(label: "Min", initialText: numericMinText()) { [weak self] text in
            self?.applyNumericMin(text)
        })
        fieldsBox.append(child: numericRow(label: "Max", initialText: numericMaxText()) { [weak self] text in
            self?.applyNumericMax(text)
        })
    }

    private func booleanDefaultRow(value: Bool) -> Box {
        let row = labeledRow("Default")
        let toggle = Switch()
        toggle.active = value
        toggle.valign = .center
        toggle.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                self?.applyBooleanDefault(state)
                return false
            }
        }
        row.append(child: toggle)
        return row
    }

    private func applyBooleanDefault(_ value: Bool) {
        schema = .boolean(default: value)
        onChanged(schema)
    }

    private func numericRow(label labelText: String, initialText: String, onChange: @escaping (String) -> Void) -> Box {
        let row = labeledRow(labelText)
        let entry = Entry()
        entry.text = initialText
        entry.placeholderText = "(none)"
        entry.hexpand = true
        entry.onChanged { _ in
            MainActor.assumeIsolated {
                onChange(entry.text ?? "")
            }
        }
        row.append(child: entry)
        return row
    }

    private func textRow(label labelText: String, value: String, monospaced: Bool, onChange: @escaping (String) -> Void) -> Box {
        let row = labeledRow(labelText)
        let entry = Entry()
        entry.text = value
        entry.hexpand = true
        if monospaced { entry.add(cssClass: "monospace") }
        entry.onChanged { _ in
            MainActor.assumeIsolated {
                onChange(entry.text ?? "")
            }
        }
        row.append(child: entry)
        return row
    }

    private func appendComboFields(choices: [ComboChoice], defaultChoice: String?) {
        let header = Label(str: "Choices")
        header.halign = .start
        header.add(cssClass: "caption")
        fieldsBox.append(child: header)

        let editor = ChoicesEditor(choices: choices) { [weak self] newChoices in
            self?.applyComboChoices(newChoices)
        }
        childEditors.append(editor)
        fieldsBox.append(child: editor.widget)

        let defaultRow = labeledRow("Default")
        let labels = ["(first)"] + choices.map(\.name)
        let selectedIndex = defaultChoice.flatMap { id in
            choices.firstIndex(where: { $0.id == id }).map { $0 + 1 }
        } ?? 0
        let dropdown = makeStringDropdown(
            labels: labels,
            selectedIndex: selectedIndex,
            handler: comboDefaultDropdownChanged
        )
        dropdown.hexpand = true
        defaultRow.append(child: dropdown)
        fieldsBox.append(child: defaultRow)
    }

    private func appendObjectFields(fields: [ObjectField]) {
        let editor = ObjectFieldsEditor(fields: fields) { [weak self] newFields in
            self?.applyObjectFields(newFields)
        }
        childEditors.append(editor)
        fieldsBox.append(child: editor.widget)
    }

    private func appendArrayFields(item: ArrayItemSchema) {
        let row = labeledRow("Item Type")
        let dropdown = makeStringDropdown(
            labels: ArrayItemKind.allCases.map(\.label),
            selectedIndex: ArrayItemKind(from: item).index,
            handler: arrayItemDropdownChanged
        )
        dropdown.hexpand = true
        row.append(child: dropdown)
        fieldsBox.append(child: row)

        switch item {
        case .combo(let choices):
            let header = Label(str: "Item Choices")
            header.halign = .start
            header.add(cssClass: "caption")
            fieldsBox.append(child: header)
            let editor = ChoicesEditor(choices: choices) { [weak self] newChoices in
                self?.applyArrayComboChoices(newChoices)
            }
            childEditors.append(editor)
            fieldsBox.append(child: editor.widget)
        case .object(let fields):
            let editor = ObjectFieldsEditor(fields: fields) { [weak self] newFields in
                self?.applyArrayObjectFields(newFields)
            }
            childEditors.append(editor)
            fieldsBox.append(child: editor.widget)
        default:
            break
        }
    }

    private func labeledRow(_ text: String) -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        let label = Label(str: text)
        label.halign = .start
        label.setSizeRequest(width: 100, height: -1)
        row.append(child: label)
        return row
    }

    private func applyNumericDefault(_ text: String) {
        switch schema {
        case .int(_, let lo, let hi):
            schema = .int(default: parseInt64(text) ?? 0, min: lo, max: hi)
        case .uint(_, let lo, let hi):
            schema = .uint(default: parseUInt64(text) ?? 0, min: lo, max: hi)
        case .double(_, let lo, let hi):
            schema = .double(default: parseDouble(text) ?? 0, min: lo, max: hi)
        default:
            return
        }
        onChanged(schema)
    }

    private func applyNumericMin(_ text: String) {
        switch schema {
        case .int(let d, _, let hi):
            schema = .int(default: d, min: parseInt64(text), max: hi)
        case .uint(let d, _, let hi):
            schema = .uint(default: d, min: parseUInt64(text), max: hi)
        case .double(let d, _, let hi):
            schema = .double(default: d, min: parseDouble(text), max: hi)
        default:
            return
        }
        onChanged(schema)
    }

    private func applyNumericMax(_ text: String) {
        switch schema {
        case .int(let d, let lo, _):
            schema = .int(default: d, min: lo, max: parseInt64(text))
        case .uint(let d, let lo, _):
            schema = .uint(default: d, min: lo, max: parseUInt64(text))
        case .double(let d, let lo, _):
            schema = .double(default: d, min: lo, max: parseDouble(text))
        default:
            return
        }
        onChanged(schema)
    }

    private func applyStringDefault(_ text: String) {
        schema = .string(default: text)
        onChanged(schema)
    }

    private func applyRegexDefault(_ text: String) {
        schema = .regex(default: text)
        onChanged(schema)
    }

    private func applyComboChoices(_ newChoices: [ComboChoice]) {
        guard case .combo(_, let d) = schema else { return }
        let ids = Set(newChoices.map(\.id))
        let preservedDefault = d.flatMap { ids.contains($0) ? $0 : nil }
        schema = .combo(choices: newChoices, default: preservedDefault)
        rebuildFields()
        onChanged(schema)
    }

    private func applyArrayComboChoices(_ newChoices: [ComboChoice]) {
        schema = .array(item: .combo(choices: newChoices), default: [])
        onChanged(schema)
    }

    private func applyObjectFields(_ newFields: [ObjectField]) {
        schema = .object(fields: newFields)
        onChanged(schema)
    }

    private func applyArrayObjectFields(_ newFields: [ObjectField]) {
        schema = .array(item: .object(fields: newFields), default: [])
        onChanged(schema)
    }

    private func numericDefaultText() -> String {
        switch schema {
        case .int(let d, _, _): return String(d)
        case .uint(let d, _, _): return String(d)
        case .double(let d, _, _): return String(d)
        default: return ""
        }
    }

    private func numericMinText() -> String {
        switch schema {
        case .int(_, let lo, _): return lo.map { String($0) } ?? ""
        case .uint(_, let lo, _): return lo.map { String($0) } ?? ""
        case .double(_, let lo, _): return lo.map { String($0) } ?? ""
        default: return ""
        }
    }

    private func numericMaxText() -> String {
        switch schema {
        case .int(_, _, let hi): return hi.map { String($0) } ?? ""
        case .uint(_, _, let hi): return hi.map { String($0) } ?? ""
        case .double(_, _, let hi): return hi.map { String($0) } ?? ""
        default: return ""
        }
    }

    private func parseInt64(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Int64(trimmed)
    }

    private func parseUInt64(_ s: String) -> UInt64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : UInt64(trimmed)
    }

    private func parseDouble(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Double(trimmed)
    }

    private func clearChildren(of box: Box) {
        while let child = box.firstChild {
            box.remove(child: child)
        }
    }

    fileprivate func makeStringDropdown(
        labels: [String],
        selectedIndex: Int,
        handler: @convention(c) @escaping (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?
        ) -> Void
    ) -> DropDown {
        let cStrings = labels.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        ptrs.append(nil)
        let widgetPtr = ptrs.withUnsafeBufferPointer { buf in
            gtk_drop_down_new_from_strings(buf.baseAddress)
        }!
        g_object_ref_sink(UnsafeMutableRawPointer(widgetPtr))
        let dropdown = DropDown(raw: UnsafeMutableRawPointer(widgetPtr))
        if selectedIndex >= 0, selectedIndex < labels.count {
            dropdown.selected = selectedIndex
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        g_signal_connect_data(
            widgetPtr,
            "notify::selected",
            unsafeBitCast(handler, to: GCallback.self),
            context,
            nil,
            GConnectFlags(rawValue: 0)
        )
        return dropdown
    }
}

@MainActor
func makeKindDropdown(initial: SchemaKind, onChanged: @escaping (SchemaKind) -> Void) -> DropDown {
    let labels = SchemaKind.allCases.map(\.label)
    let cStrings = labels.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }
    var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
    ptrs.append(nil)
    let widgetPtr = ptrs.withUnsafeBufferPointer { buf in
        gtk_drop_down_new_from_strings(buf.baseAddress)
    }!
    g_object_ref_sink(UnsafeMutableRawPointer(widgetPtr))
    let dropdown = DropDown(raw: UnsafeMutableRawPointer(widgetPtr))
    dropdown.selected = initial.index
    dropdown.onNotifySelected { dd, _ in
        MainActor.assumeIsolated {
            let kinds = SchemaKind.allCases
            let index = Int(dd.selected)
            guard index >= 0, index < kinds.count else { return }
            onChanged(kinds[index])
        }
    }
    return dropdown
}

private let arrayItemDropdownChanged: @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?
) -> Void = { widget, _, userData in
    guard let userData else { return }
    let editorPtr = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: userData))!
    let widgetPtr = UnsafeMutablePointer<GtkDropDown>(OpaquePointer(bitPattern: UInt(bitPattern: widget))!)
    MainActor.assumeIsolated {
        let editor = Unmanaged<CustomInstrumentSchemaEditor>.fromOpaque(editorPtr).takeUnretainedValue()
        editor.handleArrayItemKindChanged(Int(gtk_drop_down_get_selected(widgetPtr)))
    }
}

private let comboDefaultDropdownChanged: @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?
) -> Void = { widget, _, userData in
    guard let userData else { return }
    let editorPtr = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: userData))!
    let widgetPtr = UnsafeMutablePointer<GtkDropDown>(OpaquePointer(bitPattern: UInt(bitPattern: widget))!)
    MainActor.assumeIsolated {
        let editor = Unmanaged<CustomInstrumentSchemaEditor>.fromOpaque(editorPtr).takeUnretainedValue()
        editor.handleComboDefaultChanged(Int(gtk_drop_down_get_selected(widgetPtr)))
    }
}

@MainActor
final class ObjectFieldsEditor {
    let widget: Box
    private var fields: [ObjectField]
    private let onChanged: ([ObjectField]) -> Void
    private let listBox: Box
    private let addRowBox: Box
    private let toggleAddButton: Button
    private let draftIDEntry: Entry
    private let draftNameEntry: Entry
    private var draftKind: SchemaKind = .boolean
    private var nameAutoFilled: Bool = true
    private var suppressIDChange: Bool = false
    private var suppressNameChange: Bool = false
    private var expandedFieldID: String? = nil
    private var fieldSchemaEditors: [CustomInstrumentSchemaEditor] = []
    private var fieldBodies: [String: (body: Box, chevron: Button)] = [:]

    init(fields: [ObjectField], onChanged: @escaping ([ObjectField]) -> Void) {
        self.fields = fields
        self.onChanged = onChanged
        widget = Box(orientation: .vertical, spacing: 4)
        listBox = Box(orientation: .vertical, spacing: 4)
        addRowBox = Box(orientation: .horizontal, spacing: 6)
        addRowBox.visible = fields.isEmpty
        toggleAddButton = Button(label: fields.isEmpty ? "Done Adding" : "+ Add Field")
        toggleAddButton.halign = .start
        toggleAddButton.add(cssClass: "flat")
        draftIDEntry = Entry()
        draftIDEntry.placeholderText = "id"
        draftIDEntry.setSizeRequest(width: 140, height: -1)
        draftNameEntry = Entry()
        draftNameEntry.placeholderText = "Name"
        draftNameEntry.hexpand = true

        layout()
        rebuildList()

        if fields.isEmpty {
            Task { @MainActor in _ = draftIDEntry.grabFocus() }
        }
    }

    private func layout() {
        widget.append(child: listBox)
        populateAddRow()
        widget.append(child: addRowBox)
        toggleAddButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleAdding() }
        }
        widget.append(child: toggleAddButton)
    }

    private func populateAddRow() {
        addRowBox.append(child: draftIDEntry)
        addRowBox.append(child: draftNameEntry)
        let kindDropdown = makeKindDropdown(initial: draftKind) { [weak self] kind in
            self?.draftKind = kind
        }
        addRowBox.append(child: kindDropdown)
        let addButton = Button(label: "+")
        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.appendDraft() }
        }
        let onActivate: (Gtk.EntryRef) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.appendDraft() }
        }
        draftIDEntry.onActivate(handler: onActivate)
        draftNameEntry.onActivate(handler: onActivate)
        draftIDEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleIDChanged() }
        }
        draftNameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleNameChanged() }
        }
        addRowBox.append(child: addButton)
    }

    private func handleIDChanged() {
        guard !suppressIDChange else { return }
        let raw = draftIDEntry.text ?? ""
        let lowered = CamelCase.sanitized(raw)
        if lowered != raw {
            suppressIDChange = true
            draftIDEntry.text = lowered
            suppressIDChange = false
            return
        }
        if nameAutoFilled {
            suppressNameChange = true
            draftNameEntry.text = CamelCase.humanized(lowered)
            suppressNameChange = false
        }
    }

    private func handleNameChanged() {
        guard !suppressNameChange else { return }
        if (draftNameEntry.text ?? "") != CamelCase.humanized(draftIDEntry.text ?? "") {
            nameAutoFilled = false
        }
    }

    private func toggleAdding() {
        let nowVisible = !addRowBox.visible
        if !nowVisible {
            appendDraft()
        }
        addRowBox.visible = nowVisible
        toggleAddButton.label = nowVisible ? "Done Adding" : "+ Add Field"
        if nowVisible {
            applyExpansion(to: nil)
            _ = draftIDEntry.grabFocus()
        } else {
            resetDraft()
        }
    }

    private func resetDraft() {
        suppressIDChange = true
        draftIDEntry.text = ""
        suppressIDChange = false
        suppressNameChange = true
        draftNameEntry.text = ""
        suppressNameChange = false
        nameAutoFilled = true
    }

    private func rebuildList() {
        while let child = listBox.firstChild {
            listBox.remove(child: child)
        }
        fieldSchemaEditors.removeAll()
        fieldBodies.removeAll()
        if fields.isEmpty {
            let empty = Label(str: "No fields defined.")
            empty.add(cssClass: "dim-label")
            empty.halign = .start
            listBox.append(child: empty)
            return
        }
        for (index, field) in fields.enumerated() {
            listBox.append(child: fieldRow(field: field, index: index))
        }
    }

    private func fieldRow(field: ObjectField, index: Int) -> Box {
        let card = Box(orientation: .vertical, spacing: 0)
        card.add(cssClass: "card")

        let column = Box(orientation: .vertical, spacing: 4)
        column.marginStart = 10
        column.marginEnd = 10
        column.marginTop = 10
        column.marginBottom = 10
        card.append(child: column)

        let booleanField = isBoolean(field.schema)
        let isExpanded = expandedFieldID == field.id
        let initialID = field.id

        let chevronButton = Button()
        chevronButton.add(cssClass: "flat")
        chevronButton.set(iconName: isExpanded ? "pan-down-symbolic" : "pan-end-symbolic")
        chevronButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.fields.count else { return }
                let currentID = self.fields[index].id
                let newID: String? = (self.expandedFieldID == currentID) ? nil : currentID
                self.applyExpansion(to: newID)
            }
        }

        let header = Box(orientation: .horizontal, spacing: 6)
        header.append(child: chevronButton)

        let idEntry = Entry()
        idEntry.text = field.id
        idEntry.placeholderText = "id"
        idEntry.setSizeRequest(width: 140, height: -1)
        idEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.fields.count else { return }
                let oldID = self.fields[index].id
                let newID = idEntry.text ?? ""
                guard oldID != newID else { return }
                if let entry = self.fieldBodies.removeValue(forKey: oldID) {
                    self.fieldBodies[newID] = entry
                }
                if self.expandedFieldID == oldID {
                    self.expandedFieldID = newID
                }
                self.fields[index].id = newID
                self.onChanged(self.fields)
            }
        }
        header.append(child: idEntry)

        let nameEntry = Entry()
        nameEntry.text = field.name
        nameEntry.placeholderText = "Name"
        nameEntry.hexpand = true
        nameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.fields.count else { return }
                self.fields[index].name = nameEntry.text ?? ""
                self.onChanged(self.fields)
            }
        }
        header.append(child: nameEntry)

        let kindDropdown = makeKindDropdown(initial: SchemaKind(from: field.schema)) { [weak self] kind in
            guard let self, index < self.fields.count else { return }
            let newSchema = kind.defaultSchema()
            self.fields[index].schema = newSchema
            if self.isBoolean(newSchema), self.fields[index].optional {
                self.fields[index].optional = false
            }
            self.expandedFieldID = self.fields[index].id
            self.rebuildList()
            self.onChanged(self.fields)
        }
        header.append(child: kindDropdown)

        let removeButton = Button(label: "−")
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.fields.count else { return }
                let removedID = self.fields[index].id
                self.fields.remove(at: index)
                if self.expandedFieldID == removedID { self.expandedFieldID = nil }
                self.rebuildList()
                self.onChanged(self.fields)
            }
        }
        header.append(child: removeButton)
        column.append(child: header)

        let body = Box(orientation: .vertical, spacing: 4)
        body.visible = isExpanded

        let optionalRow = Box(orientation: .horizontal, spacing: 8)
        let optionalToggle = Switch()
        optionalToggle.active = field.optional
        optionalToggle.valign = .center
        optionalRow.append(child: optionalToggle)
        let optionalLabel = Label(str: "Optional")
        optionalLabel.halign = .start
        optionalRow.append(child: optionalLabel)
        optionalRow.visible = !booleanField

        let enabledRow = Box(orientation: .horizontal, spacing: 8)
        let enabledToggle = Switch()
        enabledToggle.active = field.enabledByDefault
        enabledToggle.valign = .center
        enabledRow.append(child: enabledToggle)
        let enabledLabel = Label(str: "Enabled by default")
        enabledLabel.halign = .start
        enabledRow.append(child: enabledLabel)
        enabledRow.visible = !booleanField && field.optional

        let editor = CustomInstrumentSchemaEditor(schema: field.schema) { [weak self] updated in
            MainActor.assumeIsolated {
                guard let self, index < self.fields.count else { return }
                self.fields[index].schema = updated
                self.onChanged(self.fields)
            }
        }
        fieldSchemaEditors.append(editor)

        optionalToggle.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                guard let self, index < self.fields.count else { return false }
                self.fields[index].optional = state
                enabledRow.visible = state
                self.onChanged(self.fields)
                return false
            }
        }
        enabledToggle.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                guard let self, index < self.fields.count else { return false }
                self.fields[index].enabledByDefault = state
                self.onChanged(self.fields)
                return false
            }
        }

        body.append(child: optionalRow)
        body.append(child: enabledRow)
        body.append(child: editor.widget)
        column.append(child: body)

        fieldBodies[initialID] = (body, chevronButton)

        return card
    }

    private func isBoolean(_ schema: FeatureSchema) -> Bool {
        if case .boolean = schema { return true }
        return false
    }

    private func appendDraft() {
        let id = (draftIDEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        let name = (draftNameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !fields.contains(where: { $0.id == id }) else { return }
        let kindHasChildren = draftKind.hasChildren
        fields.append(
            ObjectField(
                id: id,
                name: name,
                schema: draftKind.defaultSchema(),
                optional: false
            )
        )
        expandedFieldID = kindHasChildren ? id : nil
        resetDraft()
        rebuildList()
        onChanged(fields)
        if kindHasChildren {
            addRowBox.visible = false
            toggleAddButton.label = "+ Add Field"
        } else {
            _ = draftIDEntry.grabFocus()
        }
    }

    private func applyExpansion(to newID: String?) {
        expandedFieldID = newID
        for (rowID, entry) in fieldBodies {
            let shouldExpand = newID == rowID
            entry.body.visible = shouldExpand
            entry.chevron.set(iconName: shouldExpand ? "pan-down-symbolic" : "pan-end-symbolic")
        }
    }
}

@MainActor
final class ChoicesEditor {
    let widget: Box
    private var choices: [ComboChoice]
    private let onChanged: ([ComboChoice]) -> Void
    private let listBox: Box
    private let draftIDEntry: Entry
    private let draftNameEntry: Entry
    private var nameAutoFilled: Bool = true
    private var suppressIDChange: Bool = false
    private var suppressNameChange: Bool = false

    init(choices: [ComboChoice], onChanged: @escaping ([ComboChoice]) -> Void) {
        self.choices = choices
        self.onChanged = onChanged
        widget = Box(orientation: .vertical, spacing: 4)
        listBox = Box(orientation: .vertical, spacing: 4)
        draftIDEntry = Entry()
        draftIDEntry.placeholderText = "id"
        draftIDEntry.setSizeRequest(width: 140, height: -1)
        draftNameEntry = Entry()
        draftNameEntry.placeholderText = "Name"
        draftNameEntry.hexpand = true

        layout()
        rebuildList()

        if choices.isEmpty {
            Task { @MainActor in _ = draftIDEntry.grabFocus() }
        }
    }

    private func layout() {
        widget.append(child: listBox)

        let addRow = Box(orientation: .horizontal, spacing: 6)
        addRow.append(child: draftIDEntry)
        addRow.append(child: draftNameEntry)
        let addButton = Button(label: "+")
        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.appendDraft() }
        }
        let onActivate: (Gtk.EntryRef) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.appendDraft() }
        }
        draftIDEntry.onActivate(handler: onActivate)
        draftNameEntry.onActivate(handler: onActivate)
        draftIDEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDraftIDChanged() }
        }
        draftNameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDraftNameChanged() }
        }
        addRow.append(child: addButton)
        widget.append(child: addRow)
    }

    private func handleDraftIDChanged() {
        guard !suppressIDChange else { return }
        let raw = draftIDEntry.text ?? ""
        let lowered = CamelCase.sanitized(raw)
        if lowered != raw {
            suppressIDChange = true
            draftIDEntry.text = lowered
            suppressIDChange = false
            return
        }
        if nameAutoFilled {
            suppressNameChange = true
            draftNameEntry.text = CamelCase.humanized(lowered)
            suppressNameChange = false
        }
    }

    private func handleDraftNameChanged() {
        guard !suppressNameChange else { return }
        if (draftNameEntry.text ?? "") != CamelCase.humanized(draftIDEntry.text ?? "") {
            nameAutoFilled = false
        }
    }

    private func rebuildList() {
        while let child = listBox.firstChild {
            listBox.remove(child: child)
        }
        for (index, choice) in choices.enumerated() {
            listBox.append(child: choiceRow(choice: choice, index: index))
        }
    }

    private func choiceRow(choice: ComboChoice, index: Int) -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let idEntry = Entry()
        idEntry.text = choice.id
        idEntry.placeholderText = "id"
        idEntry.setSizeRequest(width: 140, height: -1)
        idEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.choices.count else { return }
                self.choices[index].id = idEntry.text ?? ""
                self.onChanged(self.choices)
            }
        }
        row.append(child: idEntry)

        let nameEntry = Entry()
        nameEntry.text = choice.name
        nameEntry.placeholderText = "Name"
        nameEntry.hexpand = true
        nameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.choices.count else { return }
                self.choices[index].name = nameEntry.text ?? ""
                self.onChanged(self.choices)
            }
        }
        row.append(child: nameEntry)

        let removeButton = Button(label: "−")
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.choices.count else { return }
                self.choices.remove(at: index)
                self.rebuildList()
                self.onChanged(self.choices)
            }
        }
        row.append(child: removeButton)
        return row
    }

    private func appendDraft() {
        let id = (draftIDEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        let name = (draftNameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !choices.contains(where: { $0.id == id }) else { return }
        choices.append(ComboChoice(id: id, name: name))
        suppressIDChange = true
        draftIDEntry.text = ""
        suppressIDChange = false
        suppressNameChange = true
        draftNameEntry.text = ""
        suppressNameChange = false
        nameAutoFilled = true
        rebuildList()
        onChanged(choices)
        _ = draftIDEntry.grabFocus()
    }
}

enum SchemaKind: CaseIterable {
    case boolean, int, uint, double, string, regex, combo, object, array

    var label: String {
        switch self {
        case .boolean: return "Boolean"
        case .int: return "Integer (signed)"
        case .uint: return "Integer (unsigned)"
        case .double: return "Float"
        case .string: return "String"
        case .regex: return "Regex"
        case .combo: return "Combo"
        case .object: return "Object"
        case .array: return "Array"
        }
    }

    var index: Int {
        Self.allCases.firstIndex(of: self)!
    }

    init(from schema: FeatureSchema) {
        switch schema {
        case .boolean: self = .boolean
        case .int: self = .int
        case .uint: self = .uint
        case .double: self = .double
        case .string: self = .string
        case .regex: self = .regex
        case .combo: self = .combo
        case .object: self = .object
        case .array: self = .array
        }
    }

    func defaultSchema() -> FeatureSchema {
        switch self {
        case .boolean: return .boolean(default: false)
        case .int: return .int(default: 0, min: nil, max: nil)
        case .uint: return .uint(default: 0, min: nil, max: nil)
        case .double: return .double(default: 0, min: nil, max: nil)
        case .string: return .string(default: "")
        case .regex: return .regex(default: "")
        case .combo: return .combo(choices: [], default: nil)
        case .object: return .object(fields: [])
        case .array: return .array(item: .string, default: [])
        }
    }

    var hasChildren: Bool {
        switch self {
        case .combo, .object, .array: return true
        default: return false
        }
    }
}

enum ArrayItemKind: CaseIterable {
    case boolean, int, uint, double, string, regex, combo, object

    var label: String {
        switch self {
        case .boolean: return "Boolean"
        case .int: return "Integer (signed)"
        case .uint: return "Integer (unsigned)"
        case .double: return "Float"
        case .string: return "String"
        case .regex: return "Regex"
        case .combo: return "Combo"
        case .object: return "Object"
        }
    }

    var index: Int {
        Self.allCases.firstIndex(of: self)!
    }

    init(from item: ArrayItemSchema) {
        switch item {
        case .boolean: self = .boolean
        case .int: self = .int
        case .uint: self = .uint
        case .double: self = .double
        case .string: self = .string
        case .regex: self = .regex
        case .combo: self = .combo
        case .object: self = .object
        }
    }

    func defaultItemSchema() -> ArrayItemSchema {
        switch self {
        case .boolean: return .boolean
        case .int: return .int
        case .uint: return .uint
        case .double: return .double
        case .string: return .string
        case .regex: return .regex
        case .combo: return .combo(choices: [])
        case .object: return .object(fields: [])
        }
    }
}
