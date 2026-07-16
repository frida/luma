import Adw
import CGtk
import Foundation
import GLibObject
import Gtk
import LumaCore

@MainActor
final class FeatureValueEditor {
    let widget: Box
    private(set) var value: FeatureValue
    private let schema: FeatureSchema
    private let onChanged: (FeatureValue) -> Void

    private var childEditors: [FeatureValueEditor] = []
    private var comboChoices: [ComboChoice] = []

    init(schema: FeatureSchema, value: FeatureValue, onChanged: @escaping (FeatureValue) -> Void) {
        self.schema = schema
        self.value = value
        self.onChanged = onChanged
        widget = Box(orientation: .vertical, spacing: 4)
        widget.hexpand = true
        layout()
    }

    private func layout() {
        switch schema {
        case .boolean:
            widget.append(child: booleanToggle())
        case .int:
            widget.append(child: integerEntry(signed: true))
        case .uint:
            widget.append(child: integerEntry(signed: false))
        case .double:
            widget.append(child: doubleEntry())
        case .string:
            widget.append(child: textEntry(monospaced: false))
        case .regex:
            widget.append(child: textEntry(monospaced: true))
        case .combo(let choices, _):
            widget.append(child: comboDropdown(choices: choices))
        case .object(let fields):
            widget.append(child: objectEditor(fields: fields))
        case .array(let item, _):
            widget.append(child: arrayEditor(itemSchema: item))
        }
    }

    private func booleanToggle() -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let toggle = Switch()
        toggle.active = currentBool()
        toggle.valign = .center
        toggle.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                guard let self else { return false }
                self.value = .boolean(state)
                self.onChanged(self.value)
                return false
            }
        }
        row.append(child: toggle)
        return row
    }

    private func integerEntry(signed: Bool) -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let entry = Entry()
        entry.text = currentIntegerText(signed: signed)
        entry.placeholderText = "0"
        entry.setSizeRequest(width: 140, height: -1)
        entry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyIntegerInput(entry.text ?? "", signed: signed)
            }
        }
        row.append(child: entry)
        appendBoundsHint(to: row)
        appendTrailingSpacer(to: row)
        return row
    }

    private func doubleEntry() -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let entry = Entry()
        entry.text = currentDoubleText()
        entry.placeholderText = "0"
        entry.setSizeRequest(width: 140, height: -1)
        entry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDoubleInput(entry.text ?? "")
            }
        }
        row.append(child: entry)
        appendBoundsHint(to: row)
        appendTrailingSpacer(to: row)
        return row
    }

    private func textEntry(monospaced: Bool) -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let entry = Entry()
        entry.text = currentString()
        entry.setSizeRequest(width: 320, height: -1)
        if monospaced { entry.add(cssClass: "monospace") }
        entry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTextInput(entry.text ?? "")
            }
        }
        row.append(child: entry)
        appendTrailingSpacer(to: row)
        return row
    }

    private func comboDropdown(choices: [ComboChoice]) -> Box {
        comboChoices = choices
        let row = Box(orientation: .horizontal, spacing: 6)
        row.append(child: makeComboDropdown(choices: choices))
        appendTrailingSpacer(to: row)
        return row
    }

    private func appendTrailingSpacer(to row: Box) {
        let spacer = Label(str: "")
        spacer.hexpand = true
        row.append(child: spacer)
    }

    private func objectEditor(fields: [ObjectField]) -> Box {
        let card = Box(orientation: .vertical, spacing: 0)
        card.add(cssClass: "card")
        card.marginStart = 4
        card.marginEnd = 4
        card.marginTop = 4
        card.marginBottom = 4
        card.halign = .start
        card.hexpand = false

        let column = Box(orientation: .vertical, spacing: 6)
        column.marginStart = 10
        column.marginEnd = 10
        column.marginTop = 10
        column.marginBottom = 10
        card.append(child: column)

        if fields.isEmpty {
            column.append(child: dimLabel("(no fields)"))
            return card
        }

        for field in fields {
            if field.optional {
                column.append(child: optionalObjectFieldRow(field: field))
            } else {
                column.append(child: requiredObjectFieldRow(field: field))
            }
        }
        return card
    }

    private func requiredObjectFieldRow(field: ObjectField) -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.valign = .center
        let nameLabel = Label(str: field.name)
        nameLabel.halign = .start
        nameLabel.valign = .center
        nameLabel.add(cssClass: "monospace")
        nameLabel.setSizeRequest(width: 120, height: -1)
        row.append(child: nameLabel)

        let fieldID = field.id
        let initialValue = currentObjectField(id: fieldID, schema: field.schema)
        let editor = FeatureValueEditor(schema: field.schema, value: initialValue) { [weak self] newValue in
            self?.applyObjectField(id: fieldID, value: newValue)
        }
        childEditors.append(editor)
        editor.widget.valign = .center
        editor.widget.hexpand = false
        row.append(child: editor.widget)

        let spacer = Label(str: "")
        spacer.hexpand = true
        row.append(child: spacer)
        return row
    }

    private func optionalObjectFieldRow(field: ObjectField) -> Box {
        let column = Box(orientation: .vertical, spacing: 4)
        let header = Box(orientation: .horizontal, spacing: 8)
        let fieldID = field.id
        let fieldSchema = field.schema
        let isPresent = isObjectFieldPresent(id: fieldID)

        let toggle = Switch()
        toggle.active = isPresent
        toggle.valign = .center
        header.append(child: toggle)
        let nameLabel = Label(str: field.name)
        nameLabel.halign = .start
        nameLabel.add(cssClass: "monospace")
        nameLabel.hexpand = true
        header.append(child: nameLabel)
        column.append(child: header)

        let editorContainer = Box(orientation: .vertical, spacing: 0)
        editorContainer.marginStart = 28
        editorContainer.visible = isPresent && !isBooleanSchema(fieldSchema)
        column.append(child: editorContainer)

        if !isBooleanSchema(fieldSchema) {
            let initialValue = currentObjectField(id: fieldID, schema: fieldSchema)
            let editor = FeatureValueEditor(schema: fieldSchema, value: initialValue) { [weak self] newValue in
                self?.applyObjectField(id: fieldID, value: newValue)
            }
            childEditors.append(editor)
            editorContainer.append(child: editor.widget)
        }

        toggle.onStateSet { [weak self] _, state in
            MainActor.assumeIsolated {
                guard let self else { return false }
                self.setObjectFieldPresent(id: fieldID, schema: fieldSchema, present: state)
                editorContainer.visible = state && !self.isBooleanSchema(fieldSchema)
                return false
            }
        }

        return column
    }

    private func isObjectFieldPresent(id: String) -> Bool {
        if case .object(let fields) = value { return fields[id] != nil }
        return false
    }

    private func setObjectFieldPresent(id: String, schema: FeatureSchema, present: Bool) {
        var fields: [String: FeatureValue] = [:]
        if case .object(let f) = value { fields = f }
        if present {
            if fields[id] == nil { fields[id] = schema.defaultValue }
        } else {
            fields.removeValue(forKey: id)
        }
        value = .object(fields)
        onChanged(value)
    }

    private func isBooleanSchema(_ schema: FeatureSchema) -> Bool {
        if case .boolean = schema { return true }
        return false
    }

    private func arrayEditor(itemSchema: ArrayItemSchema) -> Box {
        let column = Box(orientation: .vertical, spacing: 4)
        let listBox = Box(orientation: .vertical, spacing: 4)
        column.append(child: listBox)
        rebuildArray(itemSchema: itemSchema, into: listBox)

        let addButton = Button(label: "Add")
        addButton.halign = .start
        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var items = self.currentArrayItems()
                items.append(itemSchema.defaultValue)
                self.value = .array(items)
                self.onChanged(self.value)
                self.rebuildArray(itemSchema: itemSchema, into: listBox)
            }
        }
        column.append(child: addButton)
        return column
    }

    private func rebuildArray(itemSchema: ArrayItemSchema, into listBox: Box) {
        clearChildren(of: listBox)
        childEditors.removeAll()
        let items = currentArrayItems()
        if items.isEmpty {
            listBox.append(child: dimLabel("(empty)"))
            return
        }
        for index in items.indices {
            listBox.append(child: arrayItemRow(itemSchema: itemSchema, index: index, listBox: listBox))
        }
    }

    private func arrayItemRow(itemSchema: ArrayItemSchema, index: Int, listBox: Box) -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let itemValue = currentArrayItems()[index]
        let editor = FeatureValueEditor(schema: itemSchema.asFeatureSchema, value: itemValue) { [weak self] newValue in
            self?.applyArrayItem(at: index, value: newValue)
        }
        childEditors.append(editor)
        row.append(child: editor.widget)

        let removeButton = Button(label: "−")
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var items = self.currentArrayItems()
                guard index < items.count else { return }
                items.remove(at: index)
                self.value = .array(items)
                self.onChanged(self.value)
                self.rebuildArray(itemSchema: itemSchema, into: listBox)
            }
        }
        row.append(child: removeButton)
        return row
    }

    fileprivate func applyComboSelection(_ index: Int) {
        guard index >= 0, index < comboChoices.count else { return }
        value = .string(comboChoices[index].id)
        onChanged(value)
    }

    private func currentBool() -> Bool {
        if case .boolean(let v) = value { return v }
        return false
    }

    private func currentIntegerText(signed: Bool) -> String {
        if signed, case .int(let v) = value { return String(v) }
        if !signed, case .uint(let v) = value { return String(v) }
        return ""
    }

    private func currentDoubleText() -> String {
        if case .double(let v) = value { return String(v) }
        return ""
    }

    private func currentString() -> String {
        if case .string(let v) = value { return v }
        if case .regex(let v) = value { return v }
        return ""
    }

    private func currentArrayItems() -> [FeatureValue] {
        if case .array(let items) = value { return items }
        return []
    }

    private func currentObjectField(id: String, schema: FeatureSchema) -> FeatureValue {
        if case .object(let fields) = value, let v = fields[id] {
            return v
        }
        return schema.defaultValue
    }

    private func applyIntegerInput(_ text: String, signed: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if signed {
            value = .int(clampInt(Int64(trimmed) ?? 0))
        } else {
            value = .uint(clampUInt(UInt64(trimmed) ?? 0))
        }
        onChanged(value)
    }

    private func applyDoubleInput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        value = .double(clampDouble(Double(trimmed) ?? 0))
        onChanged(value)
    }

    private func clampInt(_ v: Int64) -> Int64 {
        guard case .int(_, let lo, let hi) = schema else { return v }
        var clamped = v
        if let lo, clamped < lo { clamped = lo }
        if let hi, clamped > hi { clamped = hi }
        return clamped
    }

    private func clampUInt(_ v: UInt64) -> UInt64 {
        guard case .uint(_, let lo, let hi) = schema else { return v }
        var clamped = v
        if let lo, clamped < lo { clamped = lo }
        if let hi, clamped > hi { clamped = hi }
        return clamped
    }

    private func clampDouble(_ v: Double) -> Double {
        guard case .double(_, let lo, let hi) = schema else { return v }
        var clamped = v
        if let lo, clamped < lo { clamped = lo }
        if let hi, clamped > hi { clamped = hi }
        return clamped
    }

    private func applyTextInput(_ text: String) {
        switch schema {
        case .regex:
            value = .regex(text)
        default:
            value = .string(text)
        }
        onChanged(value)
    }

    private func applyObjectField(id: String, value newValue: FeatureValue) {
        var fields: [String: FeatureValue] = [:]
        if case .object(let f) = value { fields = f }
        fields[id] = newValue
        value = .object(fields)
        onChanged(value)
    }

    private func applyArrayItem(at index: Int, value newValue: FeatureValue) {
        var items = currentArrayItems()
        guard index < items.count else { return }
        items[index] = newValue
        value = .array(items)
        onChanged(value)
    }

    private func appendBoundsHint(to row: Box) {
        guard let hint = boundsHint() else { return }
        let label = Label(str: hint)
        label.add(cssClass: "caption")
        label.add(cssClass: "dim-label")
        row.append(child: label)
    }

    private func boundsHint() -> String? {
        switch schema {
        case .int(_, let lo, let hi):
            return numericBoundsHint(min: lo, max: hi)
        case .uint(_, let lo, let hi):
            return numericBoundsHint(min: lo, max: hi)
        case .double(_, let lo, let hi):
            return numericBoundsHint(min: lo, max: hi)
        default:
            return nil
        }
    }

    private func numericBoundsHint<T: CustomStringConvertible>(min lo: T?, max hi: T?) -> String? {
        switch (lo, hi) {
        case (let lo?, let hi?): return "(\(lo)–\(hi))"
        case (let lo?, nil): return "(≥ \(lo))"
        case (nil, let hi?): return "(≤ \(hi))"
        default: return nil
        }
    }

    private func dimLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "dim-label")
        label.halign = .start
        return label
    }

    private func clearChildren(of box: Box) {
        while let child = box.firstChild {
            box.remove(child: child)
        }
    }

    private func makeComboDropdown(choices: [ComboChoice]) -> DropDown {
        let cStrings = choices.map { strdup($0.name) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        ptrs.append(nil)
        let widgetPtr = ptrs.withUnsafeBufferPointer { buf in
            gtk_drop_down_new_from_strings(buf.baseAddress)
        }!
        g_object_ref_sink(UnsafeMutableRawPointer(widgetPtr))
        let dropdown = DropDown(raw: UnsafeMutableRawPointer(widgetPtr))
        let initialIndex: Int = {
            if case .string(let v) = value, let idx = choices.firstIndex(where: { $0.id == v }) { return idx }
            return 0
        }()
        if initialIndex < choices.count {
            dropdown.selected = initialIndex
        }
        dropdown.halign = .start

        let context = Unmanaged.passUnretained(self).toOpaque()
        g_signal_connect_data(
            widgetPtr,
            "notify::selected",
            unsafeBitCast(featureValueEditorComboChanged, to: GCallback.self),
            context,
            nil,
            GConnectFlags(rawValue: 0)
        )
        return dropdown
    }
}

private let featureValueEditorComboChanged: @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?
) -> Void = { widget, _, userData in
    guard let userData else { return }
    let editorPtr = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: userData))!
    let widgetPtr = UnsafeMutablePointer<GtkDropDown>(OpaquePointer(bitPattern: UInt(bitPattern: widget))!)
    MainActor.assumeIsolated {
        let editor = Unmanaged<FeatureValueEditor>.fromOpaque(editorPtr).takeUnretainedValue()
        editor.applyComboSelection(Int(gtk_drop_down_get_selected(widgetPtr)))
    }
}
