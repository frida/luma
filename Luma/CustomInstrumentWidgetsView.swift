import LumaCore
import SwiftUI

struct CustomInstrumentWidgetsPopover: View {
    let def: CustomInstrumentDef
    @ObservedObject var workspace: Workspace
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
            await workspace.engine.updateCustomInstrument(updated)
            dismiss()
        }
    }
}

private enum NewWidgetField: Hashable { case id, name }

enum WidgetKindChoice: String, CaseIterable, Identifiable {
    case graph, list

    var id: String { rawValue }

    var label: String {
        switch self {
        case .graph: return "Graph"
        case .list: return "List"
        }
    }

    init(from kind: InstrumentWidget.Kind) {
        switch kind {
        case .graph: self = .graph
        case .list: self = .list
        }
    }

    func defaultKind() -> InstrumentWidget.Kind {
        switch self {
        case .graph: return .graph(InstrumentWidget.GraphConfig())
        case .list: return .list(InstrumentWidget.ListConfig())
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
        case .graph:
            GraphSeriesEditor(series: graphSeriesBinding)
        case .list:
            ListActionsEditor(actions: listActionsBinding)
        }
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
