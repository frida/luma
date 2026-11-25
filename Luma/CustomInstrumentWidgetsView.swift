import LumaCore
import SwiftUI

enum WidgetsEditorTab: Identifiable {
    case widgets
    case layout

    var id: Self { self }
}

struct CustomInstrumentWidgetsSheet: View {
    let defID: UUID
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CustomInstrumentDef
    @State private var tab: WidgetsEditorTab
    @State private var target: WidgetsTarget = .page

    init(def: CustomInstrumentDef, engine: Engine, tab: WidgetsEditorTab) {
        defID = def.id
        self.engine = engine
        _draft = State(initialValue: def)
        _tab = State(initialValue: tab)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WidgetsTargetList(templates: $draft.children, target: $target)
                .frame(width: 190)
            VStack(alignment: .leading, spacing: 12) {
                if case .template(let index) = target {
                    TemplateProperties(template: $draft.children[index])
                }
                Picker("Editing", selection: $tab) {
                    Text("Widgets").tag(WidgetsEditorTab.widgets)
                    Text("Layout").tag(WidgetsEditorTab.layout)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("customInstrument.widgets.tab")

                switch tab {
                case .widgets:
                    WidgetListEditor(widgets: widgetsBinding, layout: layoutBinding)
                        .id(target)
                case .layout:
                    InstrumentLayoutDesigner(widgets: widgetsBinding.wrappedValue, layout: layoutBinding, sample: sampleTemplate)
                        .id(target)
                }

                ForEach(problems, id: \.self) { problem in
                    ProblemLine(text: problem)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!problems.isEmpty || draft.widgets.contains { $0.problem != nil })
                }
            }
        }
        .padding(12)
        .frame(minWidth: 1040, idealWidth: 1180, maxWidth: .infinity, minHeight: 640, idealHeight: 780, maxHeight: .infinity)
    }

    private var widgetsBinding: Binding<[InstrumentWidget]> {
        switch target {
        case .page: return $draft.widgets
        case .template(let index): return $draft.children[index].widgets
        }
    }

    private var layoutBinding: Binding<InstrumentLayout?> {
        switch target {
        case .page: return $draft.layout
        case .template(let index): return $draft.children[index].layout
        }
    }

    private var sampleTemplate: InstrumentChildTemplate? {
        guard case .template(let index) = target else { return nil }
        return draft.children[index]
    }

    private var problems: [String] {
        var problems: [String] = []
        if let countProblem = InstrumentWidget.countProblem(draft.widgets.count) {
            problems.append("widgets: \(countProblem)")
        }
        if let layoutProblem = savedLayout?.problem(placing: draft.widgets, keys: .camelCase, widgetsName: "widgets", layoutName: "layout") {
            problems.append("layout\(InstrumentLayout.text(of: layoutProblem.path)): \(layoutProblem.text)")
        }
        if let childrenProblem = draft.childrenProblem {
            problems.append("\(InstrumentLayout.text(of: childrenProblem.path).dropFirst()): \(childrenProblem.text)")
        }
        return problems
    }

    private var savedLayout: InstrumentLayout? {
        draft.layout.flatMap { $0.droppingMaxRows(outside: draft.widgets).savable(for: draft.widgets) }
    }

    private var savedChildren: [InstrumentChildTemplate] {
        draft.children.map { template in
            var saved = template
            saved.layout = template.layout.flatMap { $0.droppingMaxRows(outside: template.widgets).savable(for: template.widgets) }
            return saved
        }
    }

    private func save() {
        let widgets = draft.widgets
        let layout = savedLayout
        let children = savedChildren
        engine.updateCustomInstrument(defID) {
            $0.widgets = widgets
            $0.layout = layout
            $0.children = children
        }
        dismiss()
    }
}

enum WidgetsTarget: Hashable {
    case page
    case template(Int)
}

private struct WidgetsTargetList: View {
    @Binding var templates: [InstrumentChildTemplate]
    @Binding var target: WidgetsTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: targetSelection) {
                Label("Page", systemImage: "doc.richtext")
                    .tag(WidgetsTarget.page)
                Section("Kinds of children") {
                    ForEach(templates.indices, id: \.self) { index in
                        Label {
                            Text(templates[index].name.isEmpty ? templates[index].id : templates[index].name)
                        } icon: {
                            ChildTemplateIcon(template: templates[index])
                        }
                        .tag(WidgetsTarget.template(index))
                    }
                }
            }
            .accessibilityLabel("What to design")
            HStack(spacing: 8) {
                Button(action: add) { Image(systemName: "plus") }
                    .help("Add a Kind of Child")
                    .accessibilityLabel("Add a Kind of Child")
                Button(action: remove) { Image(systemName: "minus") }
                    .disabled(selectedIndex == nil)
                    .help("Remove This Kind of Child")
                    .accessibilityLabel("Remove This Kind of Child")
                Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(selectedIndex.map { $0 == 0 } ?? true)
                    .help("Move Up")
                    .accessibilityLabel("Move Up")
                Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(selectedIndex.map { $0 == templates.count - 1 } ?? true)
                    .help("Move Down")
                    .accessibilityLabel("Move Down")
            }
            .buttonStyle(.borderless)
        }
    }

    private var targetSelection: Binding<WidgetsTarget?> {
        Binding(get: { target }, set: { if let selected = $0 { target = selected } })
    }

    private var selectedIndex: Int? {
        guard case .template(let index) = target else { return nil }
        return index
    }

    private func add() {
        let taken = Set(templates.map(\.id))
        let id = (1...).lazy.map { $0 == 1 ? "child" : "child\($0)" }.first { !taken.contains($0) }!
        templates.append(InstrumentChildTemplate(id: id, name: "Children", widgets: []))
        target = .template(templates.count - 1)
    }

    private func remove() {
        templates.remove(at: selectedIndex!)
        target = .page
    }

    private func move(by offset: Int) {
        let index = selectedIndex!
        templates.swapAt(index, index + offset)
        target = .template(index + offset)
    }
}

private struct TemplateProperties: View {
    @Binding var template: InstrumentChildTemplate

    @State private var isPickingIcon = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isPickingIcon = true
            } label: {
                ChildTemplateIcon(template: template)
                    .frame(width: 24, height: 24)
            }
            .help("Icon")
            .accessibilityLabel("Icon")
            .popover(isPresented: $isPickingIcon, arrowEdge: .bottom) {
                InstrumentSymbolGrid(selected: template.symbol) { template.symbol = $0 }
                    .padding(12)
            }
            Text("id")
                .foregroundStyle(.secondary)
            TextField("id", text: idBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .accessibilityLabel("Kind id")
            Text("Name")
                .foregroundStyle(.secondary)
            TextField("Plural, shown above its rows", text: $template.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Kind name")
        }
    }

    private var idBinding: Binding<String> {
        Binding(get: { template.id }, set: { template.id = CamelCase.sanitized($0) })
    }
}

struct WidgetListEditor: View {
    @Binding var widgets: [InstrumentWidget]
    @Binding var layout: InstrumentLayout?

    @State private var draftID: String = ""
    @State private var draftName: String = ""
    @State private var draftKind: WidgetKindChoice = .graph
    @State private var isAdding: Bool = false
    @State private var nameAutoFilled: Bool = true
    @State private var expandedID: String? = nil
    @FocusState private var draftFocus: NewWidgetField?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live UI elements rendered alongside the settings. Graphs receive points your agent code pushes via `ctx.widget(id).push(...)`. Lists hold items the agent maintains; per-item action buttons post events back to your `onAction` handler. Where each one goes on the page is set under Layout.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            widgetList

            if isAdding {
                addRow
            }

            Button {
                toggleAdding()
            } label: {
                Label(
                    isAdding ? "Done Adding" : "Add Widget",
                    systemImage: isAdding ? "checkmark" : "plus"
                )
            }
        }
    }

    private var widgetList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if widgets.isEmpty {
                    Text("No widgets defined.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach($widgets) { $widget in
                        WidgetRow(widget: $widget, expandedID: $expandedID) {
                            remove(widget.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
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
            TextField("Name (leave empty for no title)", text: $draftName)
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

    private func remove(_ id: String) {
        widgets.removeAll { $0.id == id }
        layout = layout?.removing(id)
        if expandedID == id { expandedID = nil }
    }

    private func toggleAdding() {
        if isAdding {
            addWidget()
            resetDraft()
            isAdding = false
        } else {
            isAdding = true
            expandedID = nil
            DispatchQueue.main.async { draftFocus = .id }
        }
    }

    private func resetDraft() {
        draftID = ""
        draftName = ""
        draftKind = .graph
        nameAutoFilled = true
    }

    private var addDisabled: Bool {
        draftID.trimmingCharacters(in: .whitespaces).isEmpty
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
        guard !id.isEmpty, !widgets.contains(where: { $0.id == id }) else { return }
        widgets.append(InstrumentWidget(id: id, name: name.isEmpty ? nil : name, kind: draftKind.defaultKind()))
        resetDraft()
        expandedID = id
        isAdding = false
    }
}

private enum NewWidgetField: Hashable { case id, name }

enum WidgetKindChoice: String, CaseIterable, Identifiable {
    case counter, histogram, graph, list, table, hex, console, view

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
        case .view: return "Smalltalk View"
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
        case .view: self = .view
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
        case .view: return .view(InstrumentWidget.ViewConfig(className: ""))
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
                if let title = widget.title {
                    Text("—").foregroundStyle(.secondary)
                    Text(title)
                }
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
                    titleField
                    persistencePicker
                    kindEditor
                    WidgetActionsEditor(title: "Actions", actions: $widget.actions)
                }
                .padding(.leading, 20)
                .padding(.top, 4)
            }
            if let problem = widget.problem {
                ProblemLine(text: problem.described)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private var kindBinding: Binding<WidgetKindChoice> {
        Binding(
            get: { WidgetKindChoice(from: widget.kind) },
            set: { if $0 != WidgetKindChoice(from: widget.kind) { widget.kind = $0.defaultKind() } }
        )
    }

    private var titleField: some View {
        HStack(spacing: 8) {
            Text("Name").font(.subheadline).frame(width: 96, alignment: .leading)
            TextField("Leave empty for no title", text: titleBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { widget.title ?? "" },
            set: { widget.name = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        )
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

    private var persistenceBinding: Binding<InstrumentWidget.Persistence> {
        Binding(
            get: { widget.persistence },
            set: { widget.persistence = $0 }
        )
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
                WidgetActionsEditor(title: "Row actions", actions: listActionsBinding)
            }
        case .table:
            VStack(alignment: .leading, spacing: 8) {
                capRow(label: "Max rows", binding: tableMaxRowsBinding)
                TableColumnsEditor(columns: tableColumnsBinding)
                WidgetActionsEditor(title: "Row actions", actions: tableActionsBinding)
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
        case .view:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Class").font(.subheadline).frame(width: 160, alignment: .leading)
                    TextField("A class from the instrument's .st files", text: viewClassBinding)
                        .textFieldStyle(.roundedBorder)
                    Spacer()
                }
                capRow(label: "Height", binding: viewHeightBinding)
            }
        }
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

    private var graphSeriesBinding: Binding<[InstrumentWidget.Series]> {
        Binding(
            get: {
                if case .graph(let cfg) = widget.kind { return cfg.series }
                return []
            },
            set: { newValue in
                if case .graph(var cfg) = widget.kind {
                    cfg.series = newValue
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

    private var listActionsBinding: Binding<[InstrumentWidget.Action]> {
        Binding(
            get: {
                if case .list(let cfg) = widget.kind { return cfg.rowActions }
                return []
            },
            set: { newValue in
                if case .list(var cfg) = widget.kind {
                    cfg.rowActions = newValue
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
                if case .table(let cfg) = widget.kind { return cfg.rowActions }
                return []
            },
            set: { newValue in
                if case .table(var cfg) = widget.kind {
                    cfg.rowActions = newValue
                    widget.kind = .table(cfg)
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

    private var viewClassBinding: Binding<String> {
        Binding(
            get: {
                if case .view(let cfg) = widget.kind { return cfg.className }
                return ""
            },
            set: { newValue in
                if case .view(var cfg) = widget.kind {
                    cfg.className = newValue.trimmingCharacters(in: .whitespaces)
                    widget.kind = .view(cfg)
                }
            }
        )
    }

    private var viewHeightBinding: Binding<Int> {
        Binding(
            get: {
                if case .view(let cfg) = widget.kind { return cfg.height }
                return InstrumentWidget.ViewConfig.defaultHeight
            },
            set: { newValue in
                if case .view(var cfg) = widget.kind {
                    cfg.height = max(1, newValue)
                    widget.kind = .view(cfg)
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

    private func consoleTextRow(label: String, binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.subheadline).frame(width: 160, alignment: .leading)
            TextField("(optional)", text: binding)
                .textFieldStyle(.roundedBorder)
            Spacer()
        }
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

private struct WidgetActionsEditor: View {
    let title: String
    @Binding var actions: [InstrumentWidget.Action]
    @State private var draftID: String = ""
    @State private var draftName: String = ""
    @State private var nameAutoFilled: Bool = true
    @FocusState private var focus: ChildFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
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

private struct ProblemLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension InstrumentLayout {
    fileprivate func droppingMaxRows(outside widgets: [InstrumentWidget]) -> InstrumentLayout {
        widgets.filter { !$0.kind.takesRows }.reduce(self) { layout, widget in
            guard let path = layout.path(of: widget.id), layout[path].maxRows != nil else { return layout }
            return try! layout.setting(.maxRows, to: nil, at: path, widgets: widgets)
        }
    }
}

extension InstrumentWidget.Kind {
    fileprivate var takesRows: Bool {
        switch self {
        case .list, .table: return true
        default: return false
        }
    }
}

extension InstrumentWidget.Problem {
    fileprivate var described: String {
        let place = path.enumerated().map { offset, step in
            switch step {
            case .key(let key): offset == 0 ? key : ".\(key)"
            case .index(let index): "[\(index)]"
            }
        }.joined()
        return "\(place): \(text)"
    }
}
