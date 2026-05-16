import LumaCore
import SwiftUI

struct CustomInstrumentWidgetsPopover: View {
    let def: CustomInstrumentDef
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var draftWidgets: [InstrumentWidget] = []
    @State private var draftID: String = ""
    @State private var draftName: String = ""
    @State private var draftKind: WidgetKindChoice = .graph
    @State private var isAdding: Bool = false
    @State private var nameAutoFilled: Bool = true
    @State private var expandedID: String? = nil
    @FocusState private var draftFocus: NewWidgetField?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Widgets").font(.headline)
            Text("Live UI elements rendered alongside the feature controls. Graphs receive points your agent code pushes via `ctx.widget(id).push(...)`. Lists hold items the agent maintains; per-item action buttons post events back to your `onAction` handler.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            widgetList

            if isAdding {
                addRow
            }

            HStack {
                Button {
                    toggleAdding()
                } label: {
                    Label(
                        isAdding ? "Done Adding" : "Add Widget",
                        systemImage: isAdding ? "checkmark" : "plus"
                    )
                }
                Spacer()
                Button("Done") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 520)
        .onAppear { draftWidgets = def.widgets }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            TextField("id", text: $draftID)
                .frame(width: 110)
                .focused($draftFocus, equals: .id)
                .onChange(of: draftID) { _, newValue in
                    applyIDChange(newValue)
                }
                .onSubmit(addWidget)
            TextField("Name", text: $draftName)
                .focused($draftFocus, equals: .name)
                .onChange(of: draftName) { _, newValue in
                    if newValue != CamelCase.humanized(draftID) {
                        nameAutoFilled = false
                    }
                }
                .onSubmit(addWidget)
            Picker("", selection: $draftKind) {
                ForEach(WidgetKindChoice.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
            Button("Add") { addWidget() }
                .disabled(addDisabled)
        }
    }

    @ViewBuilder
    private var widgetList: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            if draftWidgets.isEmpty {
                Text("No widgets defined.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach($draftWidgets) { $widget in
                    WidgetRow(widget: $widget, expandedID: $expandedID) {
                        let removedID = widget.id
                        draftWidgets.removeAll { $0.id == removedID }
                        if expandedID == removedID { expandedID = nil }
                    }
                }
            }
        }

        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toggleAdding() {
        if isAdding {
            flushDraft()
            isAdding = false
        } else {
            isAdding = true
            expandedID = nil
            DispatchQueue.main.async { draftFocus = .id }
        }
    }

    private func flushDraft() {
        addWidget()
        resetDraft()
    }

    private func resetDraft() {
        draftID = ""
        draftName = ""
        draftKind = .graph
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

    private func addWidget() {
        let id = draftID.trimmingCharacters(in: .whitespaces)
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !draftWidgets.contains(where: { $0.id == id }) else { return }
        draftWidgets.append(InstrumentWidget(id: id, name: name, kind: draftKind.defaultKind()))
        draftID = ""
        draftName = ""
        nameAutoFilled = true
        expandedID = id
        isAdding = false
    }

    private func commit() {
        if isAdding { flushDraft() }
        var updated = def
        updated.widgets = draftWidgets
        Task { @MainActor in
            await engine.updateCustomInstrument(updated)
            dismiss()
        }
    }
}

private enum NewWidgetField: Hashable { case id, name }

enum WidgetKindChoice: String, CaseIterable, Identifiable {
    case counter, histogram, graph, list, table, hex, console

    var id: String { rawValue }

    var label: String {
        switch self {
        case .counter: return "Counter"
        case .histogram: return "Histogram"
        case .graph: return "Graph"
        case .list: return "List"
        case .table: return "Table"
        case .hex: return "Hex Dump"
        case .console: return "Console"
        }
    }

    init(from kind: InstrumentWidget.Kind) {
        switch kind {
        case .counter: self = .counter
        case .histogram: self = .histogram
        case .graph: self = .graph
        case .list: self = .list
        case .table: self = .table
        case .hex: self = .hex
        case .console: self = .console
        }
    }

    func defaultKind() -> InstrumentWidget.Kind {
        switch self {
        case .counter: return .counter(InstrumentWidget.CounterConfig())
        case .histogram: return .histogram(InstrumentWidget.HistogramConfig())
        case .graph: return .graph(InstrumentWidget.GraphConfig())
        case .list: return .list(InstrumentWidget.ListConfig())
        case .table: return .table(InstrumentWidget.TableConfig())
        case .hex: return .hex(InstrumentWidget.HexConfig())
        case .console: return .console(InstrumentWidget.ConsoleConfig())
        }
    }
}

private struct WidgetRow: View {
    @Binding var widget: InstrumentWidget
    @Binding var expandedID: String?
    let onDelete: () -> Void

    private var isExpanded: Bool { expandedID == widget.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    expandedID = isExpanded ? nil : widget.id
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Text(widget.id).font(.system(.caption, design: .monospaced))
                Text("—").foregroundStyle(.secondary)
                Text(widget.name)
                Spacer()
                Picker("", selection: kindBinding) {
                    ForEach(WidgetKindChoice.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    persistencePicker
                    kindEditor
                }
                .padding(.leading, 20)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private var persistencePicker: some View {
        HStack(spacing: 8) {
            Text("Persistence").font(.subheadline).frame(width: 96, alignment: .leading)
            Picker("", selection: persistenceBinding) {
                ForEach(InstrumentWidget.Persistence.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
            Spacer()
        }
    }

    @ViewBuilder
    private var kindEditor: some View {
        switch widget.kind {
        case .counter:
            HStack(spacing: 8) {
                Text("Unit").font(.subheadline).frame(width: 160, alignment: .leading)
                TextField("(optional)", text: counterUnitBinding)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
        case .histogram:
            capRow(label: "Max buckets", binding: histogramMaxBucketsBinding)
        case .graph:
            VStack(alignment: .leading, spacing: 8) {
                capRow(label: "Max points / series", binding: graphMaxPointsBinding)
                GraphSeriesEditor(series: graphSeriesBinding)
            }
        case .list:
            VStack(alignment: .leading, spacing: 8) {
                capRow(label: "Max items", binding: listMaxItemsBinding)
                ListActionsEditor(actions: listActionsBinding)
            }
        case .table:
            VStack(alignment: .leading, spacing: 8) {
                capRow(label: "Max rows", binding: tableMaxRowsBinding)
                TableColumnsEditor(columns: tableColumnsBinding)
                ListActionsEditor(actions: tableActionsBinding)
            }
        case .hex:
            capRow(label: "Max bytes", binding: hexMaxBytesBinding)
        case .console:
            VStack(alignment: .leading, spacing: 8) {
                capRow(label: "Max entries", binding: consoleMaxEntriesBinding)
                consoleTextRow(label: "Prompt", binding: consolePromptBinding)
                consoleTextRow(label: "Placeholder", binding: consolePlaceholderBinding)
                consoleTextRow(label: "Run button label", binding: consoleRunLabelBinding)
            }
        }
    }

    private func consoleTextRow(label: String, binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.subheadline).frame(width: 160, alignment: .leading)
            TextField("(optional)", text: binding)
                .textFieldStyle(.roundedBorder)
            Spacer()
        }
    }

    private var consoleMaxEntriesBinding: Binding<Int> {
        Binding(
            get: {
                if case .console(let cfg) = widget.kind { return cfg.maxEntries }
                return InstrumentWidget.ConsoleConfig.defaultMaxEntries
            },
            set: { newValue in
                if case .console(var cfg) = widget.kind {
                    cfg.maxEntries = max(1, newValue)
                    widget.kind = .console(cfg)
                }
            }
        )
    }

    private var consolePromptBinding: Binding<String> {
        consoleStringBinding(keyPath: \.prompt)
    }

    private var consolePlaceholderBinding: Binding<String> {
        consoleStringBinding(keyPath: \.placeholder)
    }

    private var consoleRunLabelBinding: Binding<String> {
        consoleStringBinding(keyPath: \.runButtonLabel)
    }

    private func consoleStringBinding(
        keyPath: WritableKeyPath<InstrumentWidget.ConsoleConfig, String?>
    ) -> Binding<String> {
        Binding(
            get: {
                if case .console(let cfg) = widget.kind { return cfg[keyPath: keyPath] ?? "" }
                return ""
            },
            set: { newValue in
                if case .console(var cfg) = widget.kind {
                    cfg[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                    widget.kind = .console(cfg)
                }
            }
        )
    }

    private func capRow(label: String, binding: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.subheadline).frame(width: 160, alignment: .leading)
            TextField("", value: binding, formatter: capFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            Spacer()
        }
    }

    private var graphMaxPointsBinding: Binding<Int> {
        Binding(
            get: {
                if case .graph(let cfg) = widget.kind { return cfg.maxPoints }
                return InstrumentWidget.GraphConfig.defaultMaxPoints
            },
            set: { newValue in
                if case .graph(var cfg) = widget.kind {
                    cfg.maxPoints = max(1, newValue)
                    widget.kind = .graph(cfg)
                }
            }
        )
    }

    private var listMaxItemsBinding: Binding<Int> {
        Binding(
            get: {
                if case .list(let cfg) = widget.kind { return cfg.maxItems }
                return InstrumentWidget.ListConfig.defaultMaxItems
            },
            set: { newValue in
                if case .list(var cfg) = widget.kind {
                    cfg.maxItems = max(1, newValue)
                    widget.kind = .list(cfg)
                }
            }
        )
    }

    private var tableMaxRowsBinding: Binding<Int> {
        Binding(
            get: {
                if case .table(let cfg) = widget.kind { return cfg.maxRows }
                return InstrumentWidget.TableConfig.defaultMaxRows
            },
            set: { newValue in
                if case .table(var cfg) = widget.kind {
                    cfg.maxRows = max(1, newValue)
                    widget.kind = .table(cfg)
                }
            }
        )
    }

    private var tableColumnsBinding: Binding<[InstrumentWidget.Column]> {
        Binding(
            get: {
                if case .table(let cfg) = widget.kind { return cfg.columns }
                return []
            },
            set: { newValue in
                if case .table(var cfg) = widget.kind {
                    cfg.columns = newValue
                    widget.kind = .table(cfg)
                }
            }
        )
    }

    private var tableActionsBinding: Binding<[InstrumentWidget.Action]> {
        Binding(
            get: {
                if case .table(let cfg) = widget.kind { return cfg.actions }
                return []
            },
            set: { newValue in
                if case .table(var cfg) = widget.kind {
                    cfg.actions = newValue
                    widget.kind = .table(cfg)
                }
            }
        )
    }

    private var counterUnitBinding: Binding<String> {
        Binding(
            get: {
                if case .counter(let cfg) = widget.kind { return cfg.unit ?? "" }
                return ""
            },
            set: { newValue in
                if case .counter(var cfg) = widget.kind {
                    cfg.unit = newValue.isEmpty ? nil : newValue
                    widget.kind = .counter(cfg)
                }
            }
        )
    }

    private var histogramMaxBucketsBinding: Binding<Int> {
        Binding(
            get: {
                if case .histogram(let cfg) = widget.kind { return cfg.maxBuckets }
                return InstrumentWidget.HistogramConfig.defaultMaxBuckets
            },
            set: { newValue in
                if case .histogram(var cfg) = widget.kind {
                    cfg.maxBuckets = max(1, newValue)
                    widget.kind = .histogram(cfg)
                }
            }
        )
    }

    private var hexMaxBytesBinding: Binding<Int> {
        Binding(
            get: {
                if case .hex(let cfg) = widget.kind { return cfg.maxBytes }
                return InstrumentWidget.HexConfig.defaultMaxBytes
            },
            set: { newValue in
                if case .hex(var cfg) = widget.kind {
                    cfg.maxBytes = max(1, newValue)
                    widget.kind = .hex(cfg)
                }
            }
        )
    }

    private var persistenceBinding: Binding<InstrumentWidget.Persistence> {
        Binding(
            get: { widget.persistence },
            set: { widget.persistence = $0 }
        )
    }

    private var kindBinding: Binding<WidgetKindChoice> {
        Binding(
            get: { WidgetKindChoice(from: widget.kind) },
            set: { widget.kind = $0.defaultKind() }
        )
    }

    private var graphSeriesBinding: Binding<[InstrumentWidget.Series]> {
        Binding(
            get: {
                if case .graph(let cfg) = widget.kind { return cfg.series }
                return []
            },
            set: { widget.kind = .graph(InstrumentWidget.GraphConfig(series: $0)) }
        )
    }

    private var listActionsBinding: Binding<[InstrumentWidget.Action]> {
        Binding(
            get: {
                if case .list(let cfg) = widget.kind { return cfg.actions }
                return []
            },
            set: { widget.kind = .list(InstrumentWidget.ListConfig(actions: $0)) }
        )
    }
}

private struct GraphSeriesEditor: View {
    @Binding var series: [InstrumentWidget.Series]
    @State private var draftID: String = ""
    @State private var draftName: String = ""
    @State private var nameAutoFilled: Bool = true
    @FocusState private var focus: ChildFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Series").font(.caption).foregroundStyle(.secondary)
            ForEach(series.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("id", text: idBinding(at: i))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField("Name", text: nameBinding(at: i))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        series.remove(at: i)
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
                    .focused($focus, equals: .id)
                    .onChange(of: draftID) { _, newValue in applyIDChange(newValue) }
                    .onSubmit(append)
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
                    .onChange(of: draftName) { _, newValue in
                        if newValue != CamelCase.humanized(draftID) { nameAutoFilled = false }
                    }
                    .onSubmit(append)
                Button { append() } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(addDisabled)
            }
        }
    }

    private var addDisabled: Bool {
        draftID.trimmingCharacters(in: .whitespaces).isEmpty
            || draftName.trimmingCharacters(in: .whitespaces).isEmpty
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

    private func append() {
        let id = draftID.trimmingCharacters(in: .whitespaces)
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !series.contains(where: { $0.id == id }) else { return }
        series.append(InstrumentWidget.Series(id: id, name: name))
        draftID = ""
        draftName = ""
        nameAutoFilled = true
        focus = .id
    }

    private func idBinding(at i: Int) -> Binding<String> {
        Binding(
            get: { i < series.count ? series[i].id : "" },
            set: { if i < series.count { series[i].id = $0 } }
        )
    }

    private func nameBinding(at i: Int) -> Binding<String> {
        Binding(
            get: { i < series.count ? series[i].name : "" },
            set: { if i < series.count { series[i].name = $0 } }
        )
    }
}

private struct TableColumnsEditor: View {
    @Binding var columns: [InstrumentWidget.Column]
    @State private var draftID: String = ""
    @State private var draftName: String = ""
    @State private var nameAutoFilled: Bool = true
    @FocusState private var focus: ChildFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Columns").font(.caption).foregroundStyle(.secondary)
            ForEach(columns.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("id", text: idBinding(at: i))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField("Name", text: nameBinding(at: i))
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: alignmentBinding(at: i)) {
                        Text("Leading").tag(InstrumentWidget.Column.Alignment.leading)
                        Text("Trailing").tag(InstrumentWidget.Column.Alignment.trailing)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    Button { columns.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 6) {
                TextField("id", text: $draftID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .focused($focus, equals: .id)
                    .onChange(of: draftID) { _, newValue in applyIDChange(newValue) }
                    .onSubmit(append)
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
                    .onChange(of: draftName) { _, newValue in
                        if newValue != CamelCase.humanized(draftID) { nameAutoFilled = false }
                    }
                    .onSubmit(append)
                Button { append() } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(addDisabled)
            }
        }
    }

    private var addDisabled: Bool {
        draftID.trimmingCharacters(in: .whitespaces).isEmpty
            || draftName.trimmingCharacters(in: .whitespaces).isEmpty
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

    private func append() {
        let id = draftID.trimmingCharacters(in: .whitespaces)
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !columns.contains(where: { $0.id == id }) else { return }
        columns.append(InstrumentWidget.Column(id: id, name: name))
        draftID = ""
        draftName = ""
        nameAutoFilled = true
        focus = .id
    }

    private func idBinding(at i: Int) -> Binding<String> {
        Binding(
            get: { i < columns.count ? columns[i].id : "" },
            set: { if i < columns.count { columns[i].id = $0 } }
        )
    }

    private func nameBinding(at i: Int) -> Binding<String> {
        Binding(
            get: { i < columns.count ? columns[i].name : "" },
            set: { if i < columns.count { columns[i].name = $0 } }
        )
    }

    private func alignmentBinding(at i: Int) -> Binding<InstrumentWidget.Column.Alignment> {
        Binding(
            get: { i < columns.count ? columns[i].alignment : .leading },
            set: { if i < columns.count { columns[i].alignment = $0 } }
        )
    }
}

private struct ListActionsEditor: View {
    @Binding var actions: [InstrumentWidget.Action]
    @State private var draftID: String = ""
    @State private var draftName: String = ""
    @State private var nameAutoFilled: Bool = true
    @FocusState private var focus: ChildFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Actions").font(.caption).foregroundStyle(.secondary)
            ForEach(actions.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("id", text: idBinding(at: i))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField("Name", text: nameBinding(at: i))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        actions.remove(at: i)
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
                    .focused($focus, equals: .id)
                    .onChange(of: draftID) { _, newValue in applyIDChange(newValue) }
                    .onSubmit(append)
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
                    .onChange(of: draftName) { _, newValue in
                        if newValue != CamelCase.humanized(draftID) { nameAutoFilled = false }
                    }
                    .onSubmit(append)
                Button { append() } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(addDisabled)
            }
        }
    }

    private var addDisabled: Bool {
        draftID.trimmingCharacters(in: .whitespaces).isEmpty
            || draftName.trimmingCharacters(in: .whitespaces).isEmpty
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

    private func append() {
        let id = draftID.trimmingCharacters(in: .whitespaces)
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !actions.contains(where: { $0.id == id }) else { return }
        actions.append(InstrumentWidget.Action(id: id, name: name))
        draftID = ""
        draftName = ""
        nameAutoFilled = true
        focus = .id
    }

    private func idBinding(at i: Int) -> Binding<String> {
        Binding(
            get: { i < actions.count ? actions[i].id : "" },
            set: { if i < actions.count { actions[i].id = $0 } }
        )
    }

    private func nameBinding(at i: Int) -> Binding<String> {
        Binding(
            get: { i < actions.count ? actions[i].name : "" },
            set: { if i < actions.count { actions[i].name = $0 } }
        )
    }
}

private enum ChildFocus: Hashable { case id, name }

private let capFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .none
    f.allowsFloats = false
    f.minimum = 1
    return f
}()
