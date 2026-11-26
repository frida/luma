import Charts
import LumaCore
import SwiftUI

struct InstrumentWidgetsRenderer: View {
    let widgets: [InstrumentWidget]
    let layout: InstrumentLayout
    let height: CGFloat
    var child: InstrumentChild? = nil
    let engine: Engine
    var selection: Binding<SidebarItemID?> = .constant(nil)
    @Environment(\.instrumentInstance) private var instance: LumaCore.InstrumentInstance?

    @State private var rowCounts: [String: Int] = [:]
    @State private var subtitledRowCounts: [String: Int] = [:]

    var body: some View {
        WidgetPageLayout(
            layout: layout, widgets: widgets, height: height, rowCounts: rowCounts, subtitledRowCounts: subtitledRowCounts, metrics: .page
        ) {
            ForEach(widgets) { widget in
                WidgetCard(
                    widget: widget,
                    slot: child?.widgetKey(widget.id) ?? widget.id,
                    instance: instance,
                    engine: engine,
                    selection: selection,
                    isLive: isLive,
                    onRows: { note($0, rowsOf: widget.id) }
                )
                .layoutValue(key: WidgetPlacement.self, value: widget.id)
            }
        }
    }

    private var isLive: Bool {
        guard let instance else { return false }
        if engine.isHostingNode(instance.sessionID) { return true }
        return engine.isHostedRemotelyLive(instance.sessionID)
    }

    private func note(_ rows: WidgetRows, rowsOf widget: String) {
        let cap = layout.path(of: widget).flatMap { layout[$0].maxRows } ?? InstrumentLayout.defaultRowCap
        let shown = min(rows.count, cap)
        let subtitled = min(rows.subtitled, cap)
        if rowCounts[widget] != shown {
            rowCounts[widget] = shown
        }
        if subtitledRowCounts[widget] != subtitled {
            subtitledRowCounts[widget] = subtitled
        }
    }
}

extension InstrumentLayout.Metrics {
    #if os(macOS)
    static let page = InstrumentLayout.Metrics(
        spacing: 12, headerHeight: 16, headerSpacing: 4, boxInset: 5, lineHeight: HexMetrics.regular.rowHeight, rowHeight: 20,
        twoLineRowHeight: 35, counterHeight: 34)
    #else
    static let page = InstrumentLayout.Metrics(
        spacing: 12, headerHeight: 22, headerSpacing: 4, boxInset: 16, lineHeight: HexMetrics.regular.rowHeight, rowHeight: 28,
        twoLineRowHeight: 48, counterHeight: 34)
    #endif
}

private struct WidgetRows: Equatable {
    let count: Int
    let subtitled: Int
}

nonisolated private struct WidgetPlacement: LayoutValueKey {
    static let defaultValue = ""
}

private struct WidgetPageLayout: Layout {
    let layout: InstrumentLayout
    let widgets: [InstrumentWidget]
    let height: CGFloat
    let rowCounts: [String: Int]
    let subtitledRowCounts: [String: Int]
    let metrics: InstrumentLayout.Metrics

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arrangement = arranged(width: proposal.replacingUnspecifiedDimensions().width)
        return CGSize(width: arrangement.width, height: arrangement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arranged(width: bounds.width).frames
        for subview in subviews {
            let frame = frames[subview[WidgetPlacement.self]]!
            subview.place(
                at: CGPoint(x: bounds.minX + frame.x, y: bounds.minY + frame.y),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arranged(width: CGFloat) -> InstrumentLayout.Arrangement {
        layout.arranged(
            widgets: widgets, width: width, height: height, rowCounts: rowCounts, subtitledRowCounts: subtitledRowCounts, metrics: metrics)
    }
}

private struct WidgetCard: View {
    let widget: InstrumentWidget
    let slot: String
    let instance: LumaCore.InstrumentInstance?
    let engine: Engine
    let selection: Binding<SidebarItemID?>
    let isLive: Bool
    let onRows: (WidgetRows) -> Void

    private static let focusRingOutset: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentLayout.Metrics.page.headerSpacing) {
            if widget.title != nil || !widget.actions.isEmpty {
                header
                    .font(.subheadline)
                    .frame(height: InstrumentLayout.Metrics.page.headerHeight)
            }
            GroupBox {
                WidgetCanvas(
                    widget: widget,
                    slot: slot,
                    instance: instance,
                    engine: engine,
                    selection: selection,
                    onRows: onRows
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(Rectangle().inset(by: -Self.focusRingOutset))
                .disabled(!isLive && !widget.kind.isView)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(widget.label)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let title = widget.title {
                Text(title)
                    .layoutPriority(1)
            }
            Spacer()
            if !widget.actions.isEmpty {
                WidgetHeaderActions(
                    actions: widget.actions,
                    isEnabled: canChoose,
                    onPress: invoke)
            }
        }
    }

    private func canChoose(_ action: String) -> Bool {
        instance.map { engine.canChoose(action, of: slot, instance: $0) } ?? false
    }

    private func invoke(action: String) {
        guard let instance else { return }
        let engine = engine
        let widgetID = slot
        Task { @MainActor in
            await engine.invokeWidgetAction(instance: instance, widget: widgetID, action: action)
        }
    }
}

private struct WidgetCanvas: View {
    let widget: InstrumentWidget
    let slot: String
    let instance: LumaCore.InstrumentInstance?
    let engine: Engine
    let selection: Binding<SidebarItemID?>
    let onRows: (WidgetRows) -> Void

    @State private var state = WidgetState()
    @State private var tableWidth: CGFloat = 0
    @State private var consoleNotKept: String?

    var body: some View {
        Group {
            switch widget.kind {
            case .counter(let cfg):
                counterView(cfg)
            case .histogram:
                histogramView()
            case .graph(let cfg):
                graphView(cfg)
            case .list(let cfg):
                listView(cfg)
            case .table(let cfg):
                tableView(cfg)
            case .hex:
                hexView()
            case .console(let cfg):
                consoleView(cfg)
            case .view:
                if let instance {
                    InstrumentViewWidget(key: .init(instanceID: instance.id, widget: slot), name: widget.label, engine: engine)
                }
            }
        }
        .task(id: instance?.id) { await consumeUpdates() }
        .onChange(of: rows, initial: true) { _, rows in onRows(rows) }
    }

    private var rows: WidgetRows {
        switch widget.kind {
        case .list: return WidgetRows(count: state.listItems.count, subtitled: state.listItems.filter { $0.subtitle != nil }.count)
        case .table: return WidgetRows(count: state.tableRows.count, subtitled: 0)
        default: return WidgetRows(count: 0, subtitled: 0)
        }
    }

    @ViewBuilder
    private func consoleView(_ cfg: InstrumentWidget.ConsoleConfig) -> some View {
        ConsoleWidgetView(
            entries: state.consoleEntries,
            notKept: consoleNotKept,
            config: cfg,
            widgetName: widget.label,
            sessionID: instance?.sessionID ?? UUID(),
            engine: engine,
            selection: selection,
            acceptsInput: instance.map(engine.canSubmitConsoleInput) ?? false,
            inputRefusal: inputRefusal,
            onSubmit: { text in submitConsoleInput(text: text) }
        )
    }

    private var inputRefusal: String? {
        guard let instance, !engine.canSubmitConsoleInput(of: instance) else { return nil }
        if !engine.isHostingNode(instance.sessionID) && !engine.isHostedRemotelyLive(instance.sessionID) {
            return "Session not attached."
        }
        let gate = engine.gate(of: instance)
        if case .awaitingHost = gate {
            return gate.waitingLabel
        }
        if !engine.isHostingNode(instance.sessionID) {
            return "Only the member hosting this session can type here."
        }
        return "The instrument is not running."
    }

    private func submitConsoleInput(text: String) {
        guard let instance else { return }
        let widgetID = slot
        let engine = engine
        Task { @MainActor in
            await engine.submitConsoleInput(instance: instance, widget: widgetID, text: text)
        }
    }

    @ViewBuilder
    private func graphView(_ cfg: InstrumentWidget.GraphConfig) -> some View {
        if cfg.series.isEmpty {
            Text("No series defined.").font(.caption).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(cfg.series) { series in
                    let points = state.graphSeries[series.id] ?? []
                    if points.count == 1 {
                        PointMark(
                            x: .value("x", points[0].x),
                            y: .value("y", points[0].y)
                        )
                        .foregroundStyle(by: .value("Series", series.name))
                    } else {
                        ForEach(points.indices, id: \.self) { i in
                            LineMark(
                                x: .value("x", points[i].x),
                                y: .value("y", points[i].y),
                                series: .value("series", series.name)
                            )
                            .foregroundStyle(by: .value("Series", series.name))
                        }
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: cfg.series.map(\.name),
                range: cfg.series.indices.map { GraphSeriesPalette.colors[$0 % GraphSeriesPalette.colors.count] })
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func listView(_ cfg: InstrumentWidget.ListConfig) -> some View {
        if state.listItems.isEmpty {
            Text("No items.").font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollingRows(spacing: 0) {
                ForEach(state.listItems) { item in
                    listRow(item: item, actions: cfg.rowActions)
                }
            }
        }
    }

    private func listRow(item: WidgetListItem, actions: [InstrumentWidget.Action]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let accessory = item.accessory {
                Text(accessory).font(.caption).foregroundStyle(.secondary)
            }
            actionButtons(actions, item: item.id)
        }
        .padding(.vertical, 2)
        .frame(minHeight: item.subtitle == nil ? InstrumentLayout.Metrics.page.rowHeight : InstrumentLayout.Metrics.page.twoLineRowHeight)
    }

    @ViewBuilder
    private func tableView(_ cfg: InstrumentWidget.TableConfig) -> some View {
        if cfg.columns.isEmpty {
            Text("No columns defined.").font(.caption).foregroundStyle(.secondary)
        } else if state.tableRows.isEmpty {
            Text("No rows.").font(.caption).foregroundStyle(.secondary)
        } else {
            let widths = TableColumnWidths(columns: cfg.columns, rows: state.tableRows)
            let shownActions = RowActionFit.shownCount(of: cfg.rowActions, in: tableWidth, beside: widths.minimumWidth)
            VStack(alignment: .leading, spacing: 0) {
                tableHeader(cfg, widths: widths, shownActions: shownActions)
                    .frame(height: InstrumentLayout.Metrics.page.rowHeight)
                    .overlay(alignment: .bottom) { Divider() }
                ScrollingRows(spacing: 0) {
                    ForEach(state.tableRows) { row in
                        tableRow(row: row, columns: cfg.columns, actions: cfg.rowActions, shownActions: shownActions, widths: widths)
                            .frame(height: InstrumentLayout.Metrics.page.rowHeight)
                            .overlay(alignment: .bottom) { Divider().opacity(0.3) }
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { tableWidth = $0 }
        }
    }

    private func tableHeader(_ cfg: InstrumentWidget.TableConfig, widths: TableColumnWidths, shownActions: Int) -> some View {
        TableRowLayout(widths: widths, hasActions: !cfg.rowActions.isEmpty) {
            ForEach(cfg.columns) { col in
                Text(col.name)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment(for: col.alignment))
                    .foregroundStyle(.secondary)
            }
            if !cfg.rowActions.isEmpty {
                TableRowActions(actions: cfg.rowActions, shown: shownActions, isEnabled: { _ in true }, onPress: { _ in })
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
    }

    private func tableRow(
        row: WidgetTableRow, columns: [InstrumentWidget.Column], actions: [InstrumentWidget.Action], shownActions: Int,
        widths: TableColumnWidths
    ) -> some View {
        TableRowLayout(widths: widths, hasActions: !actions.isEmpty) {
            ForEach(columns) { col in
                Text(row.cells[col.id] ?? "")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment(for: col.alignment))
            }
            if !actions.isEmpty {
                TableRowActions(
                    actions: actions, shown: shownActions, isEnabled: { _ in canChooseActions },
                    onPress: { invoke(action: $0, item: row.id) })
            }
        }
    }

    private func alignment(for value: InstrumentWidget.Column.Alignment) -> SwiftUI.Alignment {
        value == .leading ? .leading : .trailing
    }

    private func actionButtons(_ actions: [InstrumentWidget.Action], item: String) -> some View {
        ActionButtons(actions: actions, isEnabled: { _ in canChooseActions }, onPress: { invoke(action: $0, item: item) })
    }

    private var canChooseActions: Bool {
        instance.map(engine.canChooseWidgetActions) ?? false
    }

    @ViewBuilder
    private func counterView(_ cfg: InstrumentWidget.CounterConfig) -> some View {
        if let value = state.counter {
            let text = engine.counterText(value, instanceID: instance?.id ?? UUID(), widget: slot)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text.value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                if let unit = value.unit ?? cfg.unit {
                    Text(unit).foregroundStyle(.secondary)
                }
                if let delta = value.delta, let deltaText = text.delta {
                    Text(deltaText)
                        .font(.caption)
                        .foregroundStyle(delta >= 0 ? .green : .red)
                }
                Spacer()
            }
        } else {
            Text("No data.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func histogramView() -> some View {
        if state.histogram.isEmpty {
            Text("No data.").font(.caption).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(state.histogram, id: \.label) { bucket in
                    BarMark(
                        x: .value("bucket", bucket.label),
                        y: .value("count", bucket.count)
                    )
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func hexView() -> some View {
        if let instance, let hex = state.hex {
            PatternDecodeView(
                data: hex.bytes,
                baseAddress: hex.baseAddress,
                sessionID: instance.sessionID,
                engine: engine,
                placements: Binding(
                    get: { engine.placements(forWidget: slot, of: instance.id) },
                    set: { engine.setPlacements($0, forWidget: slot, of: instance.id) }
                ),
                sizing: .fill
            )
        } else {
            Text("No data.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func invoke(action: String, item: String) {
        guard let instance else { return }
        let engine = engine
        Task { @MainActor in
            await engine.invokeRowAction(instance: instance, widget: slot, action: action, item: item)
        }
    }

    @MainActor
    private func consumeUpdates() async {
        guard let instance else { return }
        let widgetID = slot
        let instanceID = instance.id
        let engine = engine
        state = engine.widgetState(instanceID: instanceID, widget: widgetID)
        consoleNotKept = engine.consoleEntriesNotKept(instanceID: instanceID, widget: widgetID)
        let pending = PendingWidgetUpdates { batch in apply(batch) }
        defer { pending.stop() }
        for await update in engine.widgetUpdates
        where update.instanceID == instanceID && update.widget == widgetID {
            pending.add(update.kind)
        }
    }

    private func apply(_ batch: [WidgetUpdate.Kind]) {
        var next = state
        for kind in batch {
            next.apply(kind)
        }
        next.cap(to: widget.kind)
        state = next
        if let instance {
            consoleNotKept = engine.consoleEntriesNotKept(instanceID: instance.id, widget: slot)
        }
    }
}

@MainActor
private final class PendingWidgetUpdates: NSObject {
    private let apply: ([WidgetUpdate.Kind]) -> Void
    private var kinds: [WidgetUpdate.Kind] = []
    private var frames: CADisplayLink!

    init(apply: @escaping ([WidgetUpdate.Kind]) -> Void) {
        self.apply = apply
        super.init()
        frames = Platform.displayLink(target: self, selector: #selector(frameWillDraw))
        frames.isPaused = true
        frames.add(to: .main, forMode: .common)
    }

    func add(_ kind: WidgetUpdate.Kind) {
        kinds.append(kind)
        frames.isPaused = false
    }

    func stop() {
        frames.invalidate()
    }

    @objc private func frameWillDraw() {
        let now = CACurrentMediaTime()
        guard now - lastApplied >= Self.burstInterval else { return }
        lastApplied = now
        frames.isPaused = true
        let batch = kinds
        kinds.removeAll()
        apply(batch)
    }

    private static let burstInterval: CFTimeInterval = 0.25
    private var lastApplied: CFTimeInterval = 0
}

private struct ConsoleWidgetView: View {
    let entries: [WidgetConsoleEntry]
    let notKept: String?
    let config: InstrumentWidget.ConsoleConfig
    let widgetName: String
    let sessionID: UUID
    let engine: Engine
    let selection: Binding<SidebarItemID?>
    let acceptsInput: Bool
    let inputRefusal: String?
    let onSubmit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    private var promptGlyph: String { config.prompt ?? "›" }
    private var placeholder: String { config.placeholder ?? "" }
    private var runLabel: String { config.runButtonLabel ?? "Run" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let notKept {
                            Text(notKept)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(entries) { entry in
                            entryRow(entry)
                                .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .frame(maxHeight: .infinity)
                .onChange(of: entries.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }

            HStack(spacing: 6) {
                Text(promptGlyph)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField(inputRefusal ?? placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .disabled(!acceptsInput)
                Button(runLabel, action: submit)
                    .disabled(!canSubmit || !acceptsInput)
            }
        }
    }

    private static let bottomAnchorID = "luma-console-bottom"

    private func entryRow(_ entry: WidgetConsoleEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            entryKindGlyph(entry.kind)
            entryBody(entry)
        }
        .font(.system(.caption, design: .monospaced))
        .contextMenu {
            Button {
                Platform.copyToClipboard(entry.text)
            } label: {
                Label("Copy Entry", systemImage: "doc.on.doc")
            }
            Button {
                addToNotebook(entry)
            } label: {
                Label("Add to Notebook", systemImage: "book.pages")
            }
        }
    }

    @ViewBuilder
    private func entryKindGlyph(_ kind: WidgetConsoleEntry.Kind) -> some View {
        switch kind {
        case .input:
            Text(promptGlyph)
                .foregroundStyle(.secondary)
        case .output:
            Text(" ")
        case .image:
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func entryBody(_ entry: WidgetConsoleEntry) -> some View {
        if let image = entry.image, let swiftUIImage = Image(platformImageData: image.data) {
            VStack(alignment: .leading, spacing: 2) {
                if !entry.text.isEmpty {
                    Text(DisplayTruncation.truncated(entry.text)).textSelection(.enabled)
                }
                swiftUIImage
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
                    .cornerRadius(4)
            }
        } else if let value = entry.value {
            JSInspectValueView(
                value: value,
                sessionID: sessionID,
                engine: engine,
                selection: selection
            )
        } else {
            Text(DisplayTruncation.truncated(entry.text))
                .foregroundStyle(entry.kind == .error ? Color.red : .primary)
                .textSelection(.enabled)
        }
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSubmit(text)
    }

    private func addToNotebook(_ entry: WidgetConsoleEntry) {
        var notebookEntry = LumaCore.NotebookEntry(
            title: notebookTitle(for: entry),
            details: entry.value == nil ? entry.text : "",
            binaryData: nil,
            sessionID: sessionID,
            processName: engine.sessions.first(where: { $0.id == sessionID })?.processName
        )
        if let value = entry.value {
            notebookEntry.jsValue = value
        }
        engine.addNotebookEntry(notebookEntry)
    }

    private func notebookTitle(for entry: WidgetConsoleEntry) -> String {
        switch entry.kind {
        case .input:
            return entry.text
        case .output, .image, .error:
            return widgetName
        }
    }
}

private struct ScrollingRows<Rows: View>: View {
    let spacing: CGFloat
    @ViewBuilder let rows: Rows

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: spacing) {
                rows
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }
}

private struct WidgetHeaderActions: View {
    let actions: [InstrumentWidget.Action]
    let isEnabled: (String) -> Bool
    let onPress: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ActionButtons(actions: actions, isEnabled: isEnabled, onPress: onPress)
            Menu {
                ForEach(actions) { action in
                    Button(action.name) { onPress(action.id) }
                        .disabled(!isEnabled(action.id))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")
            .accessibilityLabel("Actions")
        }
    }
}

private struct ActionButtons: View {
    let actions: [InstrumentWidget.Action]
    let isEnabled: (String) -> Bool
    let onPress: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions) { action in
                Button(action.name) { onPress(action.id) }
                    .buttonStyle(RowActionButtonStyle())
                    .disabled(!isEnabled(action.id))
            }
        }
        .fixedSize()
    }
}

private struct TableRowActions: View {
    let actions: [InstrumentWidget.Action]
    let shown: Int
    let isEnabled: (String) -> Bool
    let onPress: (String) -> Void

    var body: some View {
        HStack(spacing: RowActionFit.spacing) {
            ActionButtons(actions: Array(actions.prefix(shown)), isEnabled: isEnabled, onPress: onPress)
            if shown < actions.count {
                Menu {
                    ForEach(actions.dropFirst(shown)) { action in
                        Button(action.name) { onPress(action.id) }
                            .disabled(!isEnabled(action.id))
                    }
                } label: {
                    Text("\u{22EF}")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
            }
        }
        .fixedSize()
    }
}

private enum RowActionFit {
    static let spacing: CGFloat = 2

    private static let labelPadding: CGFloat = 12
    private static let overflowWidth: CGFloat = 24
    private static let gapBeforeActions: CGFloat = 8

    static func shownCount(of actions: [InstrumentWidget.Action], in width: CGFloat, beside reserved: CGFloat) -> Int {
        let room = width - reserved - gapBeforeActions
        let widths = actions.map(buttonWidth)
        if widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0)) <= room {
            return actions.count
        }
        var used = overflowWidth
        var count = 0
        for width in widths {
            used += width + spacing
            guard used <= room else { break }
            count += 1
        }
        return count
    }

    private static func buttonWidth(_ action: InstrumentWidget.Action) -> CGFloat {
        let font = PlatformFont.preferredFont(forTextStyle: .subheadline)
        return (action.name as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + labelPadding
    }
}

private struct RowActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowActionLabel(configuration: configuration)
    }
}

private struct RowActionLabel: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.subheadline)
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill((isEnabled ? Color.accentColor : Color.secondary).opacity(highlight))
                    .padding(.vertical, -1)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }

    private var highlight: Double {
        guard isEnabled else { return 0.06 }
        if configuration.isPressed { return 0.3 }
        return isHovered ? 0.18 : 0.1
    }
}

private struct TableColumnWidths: Equatable {
    let natural: [CGFloat]

    init(columns: [InstrumentWidget.Column], rows: [WidgetTableRow]) {
        let advance = Self.advance
        natural = columns.map { column in
            let longest = rows.reduce(column.name.count) { max($0, ($1.cells[column.id] ?? "").count) }
            return (CGFloat(longest) * advance).rounded(.up) + 1
        }
    }

    nonisolated func fitted(to available: CGFloat) -> [CGFloat] {
        let total = natural.reduce(0, +)
        guard total > 0 else { return natural }
        if total <= available {
            return natural.map { $0 + (available - total) * $0 / total }
        }
        var kept: CGFloat = 0
        var cap = available / CGFloat(natural.count)
        for (index, width) in natural.sorted().enumerated() {
            let share = (available - kept) / CGFloat(natural.count - index)
            guard width <= share else {
                cap = share
                break
            }
            kept += width
        }
        let floor = Self.advance * Self.minimumCharacters
        return natural.map { min($0, max(cap, floor)) }
    }

    var minimumWidth: CGFloat {
        Self.advance * Self.minimumCharacters
    }

    nonisolated private static let minimumCharacters: CGFloat = 6

    nonisolated private static var advance: CGFloat {
        let size = PlatformFont.preferredFont(forTextStyle: .caption1).pointSize
        let font = PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }
}

private struct TableRowLayout: Layout {
    let widths: TableColumnWidths
    let hasActions: Bool

    private static let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let columns = columnWidths(proposal: proposal, subviews: subviews)
        let height = zip(subviews, columns.cells + [columns.actions]).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: proposal.width ?? columns.total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnWidths(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        let cellsEnd = hasActions ? bounds.maxX - columns.actions - Self.spacing : bounds.maxX
        var x = bounds.minX
        for (subview, width) in zip(subviews, columns.cells) {
            let cell = ProposedViewSize(width: max(0, min(width, cellsEnd - x)), height: bounds.height)
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: cell)
            x += width + Self.spacing
        }
        if hasActions, let actions = subviews.last {
            actions.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        }
    }

    private func columnWidths(
        proposal: ProposedViewSize, subviews: Subviews
    ) -> (cells: [CGFloat], actions: CGFloat, total: CGFloat) {
        let actions = hasActions ? (subviews.last?.sizeThatFits(.unspecified).width ?? 0) : 0
        let count = CGFloat(widths.natural.count)
        let gaps = Self.spacing * (count - 1 + (hasActions ? 1 : 0))
        let natural = widths.natural.reduce(0, +) + gaps + actions
        let available = (proposal.width ?? natural) - gaps - actions
        return (widths.fitted(to: max(0, available)), actions, natural)
    }
}

private enum GraphSeriesPalette {
    static let colors: [Color] = [
        Color(red: 0x2F / 255, green: 0x7B / 255, blue: 0xF6 / 255),
        Color(red: 0xF0 / 255, green: 0x8A / 255, blue: 0x24 / 255),
        Color(red: 0x2E / 255, green: 0xA4 / 255, blue: 0x4F / 255),
        Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255),
        Color(red: 0x8E / 255, green: 0x5B / 255, blue: 0xD9 / 255),
        Color(red: 0x1A / 255, green: 0xA7 / 255, blue: 0xA1 / 255),
        Color(red: 0xA0 / 255, green: 0x70 / 255, blue: 0x3B / 255),
        Color(red: 0xD9 / 255, green: 0x46 / 255, blue: 0x8F / 255),
    ]
}
