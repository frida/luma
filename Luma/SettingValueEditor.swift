import LumaCore
import SwiftUI

struct SettingValueEditor: View {
    let schema: SettingSchema
    @Binding var value: SettingValue

    var body: some View {
        switch schema {
        case .boolean:
            Toggle("", isOn: boolBinding).labelsHidden().platformCheckboxToggleStyle()
        case .int(_, let lo, let hi):
            integerEditor(min: lo, max: hi, signed: true)
        case .uint(_, let lo, let hi):
            integerEditor(
                min: lo.map { Int64(min(UInt64(Int64.max), $0)) },
                max: hi.map { Int64(min(UInt64(Int64.max), $0)) },
                signed: false
            )
        case .double(_, let lo, let hi):
            doubleEditor(min: lo, max: hi)
        case .string:
            HStack(spacing: 0) {
                TextField("", text: stringBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer(minLength: 0)
            }
        case .regex:
            HStack(spacing: 0) {
                TextField("regex", text: regexBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 320)
                Spacer(minLength: 0)
            }
        case .combo(let choices, _):
            HStack(spacing: 0) {
                Picker("", selection: comboBinding(choices: choices)) {
                    ForEach(choices) { c in Text(c.name).tag(c.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                Spacer(minLength: 0)
            }
        case .object(let fields):
            objectEditor(fields: fields)
        case .array(let item, _):
            ArrayValueEditor(itemSchema: item, items: arrayBinding)
        }
    }

    @ViewBuilder
    private func integerEditor(min lo: Int64?, max hi: Int64?, signed: Bool) -> some View {
        HStack(spacing: 6) {
            TextField(
                "0",
                value: signed ? intBinding : uintBinding,
                formatter: integerFormatter
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 140)
            if let hint = boundsHint(min: lo, max: hi) {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func doubleEditor(min lo: Double?, max hi: Double?) -> some View {
        HStack(spacing: 6) {
            TextField("0", value: doubleBinding, formatter: doubleFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
            if let hint = boundsHint(min: lo, max: hi) {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func boundsHint<T: CustomStringConvertible>(min lo: T?, max hi: T?) -> String? {
        switch (lo, hi) {
        case (let lo?, let hi?): return "(\(lo)–\(hi))"
        case (let lo?, nil): return "(≥ \(lo))"
        case (nil, let hi?): return "(≤ \(hi))"
        default: return nil
        }
    }

    @ViewBuilder
    private func objectEditor(fields: [ObjectField]) -> some View {
        if fields.isEmpty {
            Text("(no fields)").font(.caption).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(fields, id: \.id) { field in
                    fieldGridRow(field: field)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.05)))
        }
    }

    @ViewBuilder
    private func fieldGridRow(field: ObjectField) -> some View {
        if field.optional {
            GridRow {
                optionalFieldContent(field: field)
                    .gridCellColumns(2)
            }
        } else {
            GridRow {
                Text(field.name)
                    .font(.system(.caption, design: .monospaced))
                    .gridColumnAlignment(.trailing)
                SettingValueEditor(
                    schema: field.schema,
                    value: objectFieldBinding(id: field.id, schema: field.schema)
                )
            }
        }
    }

    @ViewBuilder
    private func optionalFieldContent(field: ObjectField) -> some View {
        let enabled = objectFieldEnabledBinding(id: field.id, schema: field.schema)
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: enabled) {
                Text(field.name).font(.system(.caption, design: .monospaced))
            }
            .platformCheckboxToggleStyle()
            if enabled.wrappedValue, case .boolean = field.schema {
                EmptyView()
            } else if enabled.wrappedValue {
                SettingValueEditor(
                    schema: field.schema,
                    value: objectFieldBinding(id: field.id, schema: field.schema)
                )
                .padding(.leading, 20)
            }
        }
    }

    private func objectFieldEnabledBinding(id: String, schema: SettingSchema) -> Binding<Bool> {
        Binding(
            get: {
                if case .object(let fields) = value { return fields[id] != nil }
                return false
            },
            set: { newValue in
                var fields: [String: SettingValue] = [:]
                if case .object(let f) = value { fields = f }
                if newValue {
                    if fields[id] == nil {
                        fields[id] = schema.defaultValue
                    }
                } else {
                    fields.removeValue(forKey: id)
                }
                value = .object(fields)
            }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: {
                if case .boolean(let v) = value { return v }
                return false
            },
            set: { value = .boolean($0) }
        )
    }

    private var intBinding: Binding<Int64> {
        Binding(
            get: {
                if case .int(let v) = value { return v }
                return 0
            },
            set: { value = .int(clampInt($0)) }
        )
    }

    private var uintBinding: Binding<Int64> {
        Binding(
            get: {
                if case .uint(let v) = value { return Int64(min(UInt64(Int64.max), v)) }
                return 0
            },
            set: { value = .uint(clampUInt(UInt64(max(0, $0)))) }
        )
    }

    private var doubleBinding: Binding<Double> {
        Binding(
            get: {
                if case .double(let v) = value { return v }
                return 0
            },
            set: { value = .double(clampDouble($0)) }
        )
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

    private var stringBinding: Binding<String> {
        Binding(
            get: {
                if case .string(let v) = value { return v }
                return ""
            },
            set: { value = .string($0) }
        )
    }

    private var regexBinding: Binding<String> {
        Binding(
            get: {
                if case .regex(let v) = value { return v }
                return ""
            },
            set: { value = .regex($0) }
        )
    }

    private func comboBinding(choices: [ComboChoice]) -> Binding<String> {
        Binding(
            get: {
                if case .string(let v) = value, choices.contains(where: { $0.id == v }) { return v }
                return choices.first?.id ?? ""
            },
            set: { value = .string($0) }
        )
    }

    private func objectFieldBinding(id: String, schema: SettingSchema) -> Binding<SettingValue> {
        Binding(
            get: {
                if case .object(let fields) = value, let v = fields[id] {
                    return v
                }
                return schema.defaultValue
            },
            set: { newValue in
                var fields: [String: SettingValue] = [:]
                if case .object(let f) = value { fields = f }
                fields[id] = newValue
                value = .object(fields)
            }
        )
    }

    private var arrayBinding: Binding<[SettingValue]> {
        Binding(
            get: {
                if case .array(let items) = value { return items }
                return []
            },
            set: { value = .array($0) }
        )
    }
}

struct ArrayValueEditor: View {
    let itemSchema: ArrayItemSchema
    @Binding var items: [SettingValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty {
                Text("(empty)").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(items.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        SettingValueEditor(
                            schema: itemSchema.asSettingSchema,
                            value: itemBinding(at: index)
                        )
                        Button {
                            items.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button {
                items.append(itemSchema.defaultValue)
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func itemBinding(at index: Int) -> Binding<SettingValue> {
        Binding(
            get: {
                index < items.count ? items[index] : itemSchema.defaultValue
            },
            set: { newValue in
                if index < items.count {
                    items[index] = newValue
                }
            }
        )
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

