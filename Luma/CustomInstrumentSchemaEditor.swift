import LumaCore
import SwiftUI

struct SchemaKindPicker: View {
    @Binding var schema: FeatureSchema

    var body: some View {
        Picker("", selection: kindBinding) {
            ForEach(SchemaKind.allCases) { k in
                Text(k.label).tag(k)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 130)
    }

    private var kindBinding: Binding<SchemaKind> {
        Binding(
            get: { SchemaKind(from: schema) },
            set: { schema = $0.defaultSchema() }
        )
    }
}

struct CustomInstrumentSchemaEditor: View {
    @Binding var schema: FeatureSchema

    var body: some View {
        schemaFields
    }

    @ViewBuilder
    private var schemaFields: some View {
        switch schema {
        case .boolean:
            EmptyView()
        case .int:
            intFields(signed: true)
        case .uint:
            intFields(signed: false)
        case .double:
            doubleFields
        case .string:
            textDefaultField
        case .regex:
            regexDefaultField
        case .combo:
            comboFields
        case .object:
            objectFields
        case .array:
            arrayFields
        }
    }

    @ViewBuilder
    private func intFields(signed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Default").frame(width: 80, alignment: .leading)
                TextField("0", value: signed ? intDefaultBinding : uintDefaultBinding, formatter: integerFormatter)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Text("Min").frame(width: 80, alignment: .leading)
                OptionalIntegerField(
                    binding: signed ? intMinBinding : uintMinBinding,
                    placeholder: "(none)"
                )
            }
            HStack(spacing: 8) {
                Text("Max").frame(width: 80, alignment: .leading)
                OptionalIntegerField(
                    binding: signed ? intMaxBinding : uintMaxBinding,
                    placeholder: "(none)"
                )
            }
        }
    }

    private var doubleFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Default").frame(width: 80, alignment: .leading)
                TextField("0", value: doubleDefaultBinding, formatter: doubleFormatter)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Text("Min").frame(width: 80, alignment: .leading)
                OptionalDoubleField(binding: doubleMinBinding, placeholder: "(none)")
            }
            HStack(spacing: 8) {
                Text("Max").frame(width: 80, alignment: .leading)
                OptionalDoubleField(binding: doubleMaxBinding, placeholder: "(none)")
            }
        }
    }

    private var textDefaultField: some View {
        HStack(spacing: 8) {
            Text("Default").frame(width: 80, alignment: .leading)
            TextField("", text: stringDefaultBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var regexDefaultField: some View {
        HStack(spacing: 8) {
            Text("Default").frame(width: 80, alignment: .leading)
            TextField("regex", text: regexDefaultBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var comboFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choices").font(.caption).foregroundStyle(.secondary)
            ChoicesEditor(choices: comboChoicesBinding)
            HStack(spacing: 8) {
                Text("Default").frame(width: 80, alignment: .leading)
                Picker("", selection: comboDefaultBinding) {
                    Text("(first)").tag(nil as String?)
                    ForEach(currentComboChoices) { c in
                        Text(c.name).tag(c.id as String?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var objectFields: some View {
        ObjectFieldsEditor(fields: objectFieldsBinding)
    }

    private var arrayFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Item Type").frame(width: 80, alignment: .leading)
                Picker("", selection: arrayItemKindBinding) {
                    ForEach(ArrayItemKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }
            if case .array(let item, _) = schema {
                switch item {
                case .combo:
                    Text("Item Choices").font(.caption).foregroundStyle(.secondary)
                    ChoicesEditor(choices: arrayComboChoicesBinding)
                case .object:
                    ObjectFieldsEditor(fields: arrayObjectFieldsBinding)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var intDefaultBinding: Binding<Int64> {
        Binding(
            get: {
                if case .int(let d, _, _) = schema { return d }
                return 0
            },
            set: { newValue in
                if case .int(_, let lo, let hi) = schema {
                    schema = .int(default: newValue, min: lo, max: hi)
                }
            }
        )
    }

    private var intMinBinding: Binding<Int64?> {
        Binding(
            get: {
                if case .int(_, let lo, _) = schema { return lo }
                return nil
            },
            set: { newValue in
                if case .int(let d, _, let hi) = schema {
                    schema = .int(default: d, min: newValue, max: hi)
                }
            }
        )
    }

    private var intMaxBinding: Binding<Int64?> {
        Binding(
            get: {
                if case .int(_, _, let hi) = schema { return hi }
                return nil
            },
            set: { newValue in
                if case .int(let d, let lo, _) = schema {
                    schema = .int(default: d, min: lo, max: newValue)
                }
            }
        )
    }

    private var uintDefaultBinding: Binding<Int64> {
        Binding(
            get: {
                if case .uint(let d, _, _) = schema { return Int64(min(UInt64(Int64.max), d)) }
                return 0
            },
            set: { newValue in
                if case .uint(_, let lo, let hi) = schema {
                    schema = .uint(default: UInt64(max(0, newValue)), min: lo, max: hi)
                }
            }
        )
    }

    private var uintMinBinding: Binding<Int64?> {
        Binding(
            get: {
                if case .uint(_, let lo, _) = schema, let lo { return Int64(min(UInt64(Int64.max), lo)) }
                return nil
            },
            set: { newValue in
                if case .uint(let d, _, let hi) = schema {
                    let m = newValue.map { UInt64(max(0, $0)) }
                    schema = .uint(default: d, min: m, max: hi)
                }
            }
        )
    }

    private var uintMaxBinding: Binding<Int64?> {
        Binding(
            get: {
                if case .uint(_, _, let hi) = schema, let hi { return Int64(min(UInt64(Int64.max), hi)) }
                return nil
            },
            set: { newValue in
                if case .uint(let d, let lo, _) = schema {
                    let m = newValue.map { UInt64(max(0, $0)) }
                    schema = .uint(default: d, min: lo, max: m)
                }
            }
        )
    }

    private var doubleDefaultBinding: Binding<Double> {
        Binding(
            get: {
                if case .double(let d, _, _) = schema { return d }
                return 0
            },
            set: { newValue in
                if case .double(_, let lo, let hi) = schema {
                    schema = .double(default: newValue, min: lo, max: hi)
                }
            }
        )
    }

    private var doubleMinBinding: Binding<Double?> {
        Binding(
            get: {
                if case .double(_, let lo, _) = schema { return lo }
                return nil
            },
            set: { newValue in
                if case .double(let d, _, let hi) = schema {
                    schema = .double(default: d, min: newValue, max: hi)
                }
            }
        )
    }

    private var doubleMaxBinding: Binding<Double?> {
        Binding(
            get: {
                if case .double(_, _, let hi) = schema { return hi }
                return nil
            },
            set: { newValue in
                if case .double(let d, let lo, _) = schema {
                    schema = .double(default: d, min: lo, max: newValue)
                }
            }
        )
    }

    private var stringDefaultBinding: Binding<String> {
        Binding(
            get: {
                if case .string(let d) = schema { return d }
                return ""
            },
            set: { schema = .string(default: $0) }
        )
    }

    private var regexDefaultBinding: Binding<String> {
        Binding(
            get: {
                if case .regex(let d) = schema { return d }
                return ""
            },
            set: { schema = .regex(default: $0) }
        )
    }

    private var currentComboChoices: [ComboChoice] {
        if case .combo(let choices, _) = schema { return choices }
        return []
    }

    private var comboChoicesBinding: Binding<[ComboChoice]> {
        Binding(
            get: { currentComboChoices },
            set: { newChoices in
                if case .combo(_, let d) = schema {
                    let ids = Set(newChoices.map(\.id))
                    let preservedDefault = d.flatMap { ids.contains($0) ? $0 : nil }
                    schema = .combo(choices: newChoices, default: preservedDefault)
                }
            }
        )
    }

    private var comboDefaultBinding: Binding<String?> {
        Binding(
            get: {
                if case .combo(_, let d) = schema { return d }
                return nil
            },
            set: { newValue in
                if case .combo(let choices, _) = schema {
                    schema = .combo(choices: choices, default: newValue)
                }
            }
        )
    }

    private var arrayItemKindBinding: Binding<ArrayItemKind> {
        Binding(
            get: {
                if case .array(let item, _) = schema { return ArrayItemKind(from: item) }
                return .string
            },
            set: { newKind in
                schema = .array(item: newKind.defaultItemSchema(), default: [])
            }
        )
    }

    private var arrayComboChoicesBinding: Binding<[ComboChoice]> {
        Binding(
            get: {
                if case .array(let item, _) = schema, case .combo(let choices) = item {
                    return choices
                }
                return []
            },
            set: { newChoices in
                if case .array = schema {
                    schema = .array(item: .combo(choices: newChoices), default: [])
                }
            }
        )
    }

    private var objectFieldsBinding: Binding<[ObjectField]> {
        Binding(
            get: {
                if case .object(let fields) = schema { return fields }
                return []
            },
            set: { schema = .object(fields: $0) }
        )
    }

    private var arrayObjectFieldsBinding: Binding<[ObjectField]> {
        Binding(
            get: {
                if case .array(let item, _) = schema, case .object(let fields) = item {
                    return fields
                }
                return []
            },
            set: { newFields in
                if case .array = schema {
                    schema = .array(item: .object(fields: newFields), default: [])
                }
            }
        )
    }
}

struct ObjectFieldsEditor: View {
    @Binding var fields: [ObjectField]
    @State private var draftID: String = ""
    @State private var draftName: String = ""
    @State private var draftKind: SchemaKind = .boolean
    @State private var isAddingField: Bool
    @State private var nameAutoFilled: Bool = true
    @State private var expandedFieldID: String? = nil
    @FocusState private var draftFocus: ObjectFieldDraftFocus?

    init(fields: Binding<[ObjectField]>) {
        self._fields = fields
        self._isAddingField = State(initialValue: fields.wrappedValue.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if fields.isEmpty {
                Text("No fields defined.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(fields.indices, id: \.self) { index in
                    ObjectFieldRow(
                        field: fieldBinding(at: index),
                        expandedID: $expandedFieldID,
                        onDelete: {
                            let removedID = fields[index].id
                            fields.remove(at: index)
                            if expandedFieldID == removedID { expandedFieldID = nil }
                        }
                    )
                }
            }
            if isAddingField {
                HStack(spacing: 6) {
                    TextField("id", text: $draftID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .focused($draftFocus, equals: .id)
                        .onChange(of: draftID) { _, newValue in
                            applyIDChange(newValue)
                        }
                        .onSubmit(appendField)
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .focused($draftFocus, equals: .name)
                        .onChange(of: draftName) { _, newValue in
                            if newValue != CamelCase.humanized(draftID) {
                                nameAutoFilled = false
                            }
                        }
                        .onSubmit(appendField)
                    Picker("", selection: $draftKind) {
                        ForEach(SchemaKind.allCases) { k in
                            Text(k.label).tag(k)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    Button {
                        appendField()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(addDisabled)
                }
            }
            Button {
                toggleAdding()
            } label: {
                Label(
                    isAddingField ? "Done Adding" : "Add Field",
                    systemImage: isAddingField ? "checkmark" : "plus"
                )
            }
        }
        .onAppear {
            if isAddingField {
                DispatchQueue.main.async { draftFocus = .id }
            }
        }
    }

    private func toggleAdding() {
        isAddingField.toggle()
        if isAddingField {
            expandedFieldID = nil
            DispatchQueue.main.async { draftFocus = .id }
        } else {
            resetDraft()
        }
    }

    private func resetDraft() {
        draftID = ""
        draftName = ""
        draftKind = .boolean
        nameAutoFilled = true
    }

    private var addDisabled: Bool {
        let id = draftID.trimmingCharacters(in: .whitespaces)
        let name = draftName.trimmingCharacters(in: .whitespaces)
        return id.isEmpty || name.isEmpty
    }

    private func applyIDChange(_ newValue: String) {
        let lowered = CamelCase.sanitized(newValue)
        if lowered != newValue {
            draftID = lowered
            return
        }
        if nameAutoFilled {
            draftName = CamelCase.humanized(lowered)
        }
    }

    private func fieldBinding(at index: Int) -> Binding<ObjectField> {
        Binding(
            get: { index < fields.count ? fields[index] : ObjectField(id: "", name: "", schema: .boolean) },
            set: { newValue in
                if index < fields.count {
                    fields[index] = newValue
                }
            }
        )
    }

    private func appendField() {
        let id = draftID.trimmingCharacters(in: .whitespaces)
        let name = draftName.trimmingCharacters(in: .whitespaces)
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
        draftID = ""
        draftName = ""
        nameAutoFilled = true
        if kindHasChildren {
            expandedFieldID = id
            isAddingField = false
        } else {
            expandedFieldID = nil
            draftFocus = .id
        }
    }
}

private enum ObjectFieldDraftFocus: Hashable { case id, name }

private struct ObjectFieldRow: View {
    @Binding var field: ObjectField
    @Binding var expandedID: String?
    let onDelete: () -> Void

    private var isExpanded: Bool { expandedID == field.id }

    private var isBooleanSchema: Bool {
        if case .boolean = field.schema { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isBooleanSchema {
                    Image(systemName: "chevron.right").opacity(0)
                } else {
                    Button {
                        expandedID = isExpanded ? nil : field.id
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                }
                TextField("id", text: $field.id)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                TextField("Name", text: $field.name)
                    .textFieldStyle(.roundedBorder)
                SchemaKindPicker(schema: $field.schema)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
            if isExpanded && !isBooleanSchema {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Optional", isOn: $field.optional)
                        .platformCheckboxToggleStyle()
                    if field.optional {
                        Toggle("Enabled by default", isOn: $field.enabledByDefault)
                            .platformCheckboxToggleStyle()
                    }
                    CustomInstrumentSchemaEditor(schema: $field.schema)
                }
                .padding(.leading, 20)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.05)))
        .onChange(of: field.schema) { _, newSchema in
            if case .boolean = newSchema {
                if field.optional { field.optional = false }
            } else {
                expandedID = field.id
            }
        }
    }
}

enum SchemaKind: String, CaseIterable, Identifiable {
    case boolean, int, uint, double, string, regex, combo, object, array

    var id: String { rawValue }

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
        case .boolean: return .boolean
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

enum ArrayItemKind: String, CaseIterable, Identifiable {
    case boolean, int, uint, double, string, regex, combo, object

    var id: String { rawValue }

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

struct ChoicesEditor: View {
    @Binding var choices: [ComboChoice]
    @State private var draftID: String = ""
    @State private var draftName: String = ""
    @State private var nameAutoFilled: Bool = true
    @FocusState private var draftFocus: ChoiceDraftFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(choices.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("id", text: idBinding(at: i))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField("Name", text: nameBinding(at: i))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        choices.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 6) {
                TextField("id", text: $draftID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .focused($draftFocus, equals: .id)
                    .onChange(of: draftID) { _, newValue in
                        applyIDChange(newValue)
                    }
                    .onSubmit(appendDraft)
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocus, equals: .name)
                    .onChange(of: draftName) { _, newValue in
                        if newValue != CamelCase.humanized(draftID) {
                            nameAutoFilled = false
                        }
                    }
                    .onSubmit(appendDraft)
                Button {
                    appendDraft()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(addDisabled)
            }
        }
        .onAppear {
            DispatchQueue.main.async { draftFocus = .id }
        }
    }

    private var addDisabled: Bool {
        let id = draftID.trimmingCharacters(in: .whitespaces)
        let name = draftName.trimmingCharacters(in: .whitespaces)
        return id.isEmpty || name.isEmpty
    }

    private func applyIDChange(_ newValue: String) {
        let lowered = CamelCase.sanitized(newValue)
        if lowered != newValue {
            draftID = lowered
            return
        }
        if nameAutoFilled {
            draftName = CamelCase.humanized(lowered)
        }
    }

    private func appendDraft() {
        let id = draftID.trimmingCharacters(in: .whitespaces)
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !choices.contains(where: { $0.id == id }) else { return }
        choices.append(ComboChoice(id: id, name: name))
        draftID = ""
        draftName = ""
        nameAutoFilled = true
        draftFocus = .id
    }

    private func idBinding(at i: Int) -> Binding<String> {
        Binding(
            get: { i < choices.count ? choices[i].id : "" },
            set: { newValue in
                if i < choices.count { choices[i].id = newValue }
            }
        )
    }

    private func nameBinding(at i: Int) -> Binding<String> {
        Binding(
            get: { i < choices.count ? choices[i].name : "" },
            set: { newValue in
                if i < choices.count { choices[i].name = newValue }
            }
        )
    }
}

private enum ChoiceDraftFocus: Hashable { case id, name }

struct OptionalIntegerField: View {
    @Binding var binding: Int64?
    let placeholder: String
    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .onAppear { text = binding.map { String($0) } ?? "" }
            .onChange(of: text) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                binding = trimmed.isEmpty ? nil : Int64(trimmed)
            }
            .onChange(of: binding) { _, newValue in
                let formatted = newValue.map { String($0) } ?? ""
                if formatted != text { text = formatted }
            }
    }
}

struct OptionalDoubleField: View {
    @Binding var binding: Double?
    let placeholder: String
    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .onAppear { text = binding.map { String($0) } ?? "" }
            .onChange(of: text) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                binding = trimmed.isEmpty ? nil : Double(trimmed)
            }
            .onChange(of: binding) { _, newValue in
                let formatted = newValue.map { String($0) } ?? ""
                if formatted != text { text = formatted }
            }
    }
}

private let integerFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .none
    f.allowsFloats = false
    f.maximumFractionDigits = 0
    return f
}()

private let doubleFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 6
    return f
}()
