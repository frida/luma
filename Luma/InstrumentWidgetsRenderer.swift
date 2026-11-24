import Charts
import LumaCore
import SwiftUI

struct InstrumentWidgetsRenderer: View {
    let widgets: [InstrumentWidget]
    let engine: Engine
    var selection: Binding<SidebarItemID?> = .constant(nil)
    @Environment(\.instrumentInstance) private var instance: LumaCore.InstrumentInstance?

    var body: some View {
        if widgets.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(widgets) { widget in
                    VStack(alignment: .leading, spacing: 4) {
                        if widget.title != nil || !widget.actions.isEmpty {
                            widgetHeader(widget: widget)
                                .font(.subheadline)
                        }
                        GroupBox {
                            WidgetCanvas(
                                widget: widget,
                                instance: instance,
                                engine: engine,
                                selection: selection
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(!isLive && !widget.kind.isView)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(widget.label)
                    }
                }
            }
        }
    }

    private var isLive: Bool {
        guard let instance else { return false }
        if engine.isHostingNode(instance.sessionID) { return true }
        return engine.isHostedRemotelyLive(instance.sessionID)
    }

    private func widgetHeader(widget: InstrumentWidget) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let title = widget.title {
                Text(title)
                    .layoutPriority(1)
            }
            Spacer()
            if !widget.actions.isEmpty {
                WidgetHeaderActions(
                    actions: widget.actions,
                    isEnabled: { canChoose($0, of: widget) },
                    onPress: { invoke(action: $0, of: widget) })
            }
        }
    }

    private func canChoose(_ action: String, of widget: InstrumentWidget) -> Bool {
        instance.map { engine.canChoose(action, of: widget.id, instance: $0) } ?? false
    }

    private func invoke(action: String, of widget: InstrumentWidget) {
        guard let instance else { return }
        let engine = engine
        Task { @MainActor in
            await engine.invokeWidgetAction(instance: instance, widget: widget.id, action: action)
        }
    }
}

private struct WidgetCanvas: View {
    let widget: InstrumentWidget
    let instance: LumaCore.InstrumentInstance?
    let engine: Engine
    let selection: Binding<SidebarItemID?>

    @State private var state = WidgetState()

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
            case .view(let cfg):
                if let instance {
                    InstrumentViewWidget(key: .init(instanceID: instance.id, widget: widget.id), config: cfg, engine: engine)
                }
            }
        }
        .task(id: instance?.id) { await consumeUpdates() }
    }

    @ViewBuilder
    private func consoleView(_ cfg: InstrumentWidget.ConsoleConfig) -> some View {
        ConsoleWidgetView(
            entries: state.consoleEntries,
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
        if !engine.isHostingNode(instance.sessionID) {
            return "Only the member hosting this session can type here."
        }
        return "The instrument is not running."
    }

    private func submitConsoleInput(text: String) {
        guard let instance else { return }
        let widgetID = widget.id
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
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private func listView(_ cfg: InstrumentWidget.ListConfig) -> some View {
        if state.listItems.isEmpty {
            Text("No items.").font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollingRows(spacing: 4) {
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
    }

    @ViewBuilder
    private func tableView(_ cfg: InstrumentWidget.TableConfig) -> some View {
        if cfg.columns.isEmpty {
            Text("No columns defined.").font(.caption).foregroundStyle(.secondary)
        } else if state.tableRows.isEmpty {
            Text("No rows.").font(.caption).foregroundStyle(.secondary)
        } else {
            let widths = TableColumnWidths(columns: cfg.columns, rows: state.tableRows)
            VStack(alignment: .leading, spacing: 0) {
                tableHeader(cfg, widths: widths)
                Divider()
                ScrollingRows(spacing: 0) {
                    ForEach(state.tableRows) { row in
                        VStack(spacing: 0) {
                            tableRow(row: row, columns: cfg.columns, actions: cfg.rowActions, widths: widths)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    private func tableHeader(_ cfg: InstrumentWidget.TableConfig, widths: TableColumnWidths) -> some View {
        TableRowLayout(widths: widths, hasActions: !cfg.rowActions.isEmpty) {
            ForEach(cfg.columns) { col in
                Text(col.name)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment(for: col.alignment))
                    .foregroundStyle(.secondary)
            }
            if !cfg.rowActions.isEmpty {
                ActionButtons(actions: cfg.rowActions, isEnabled: { _ in true }, onPress: { _ in })
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }

    private func tableRow(
        row: WidgetTableRow, columns: [InstrumentWidget.Column], actions: [InstrumentWidget.Action], widths: TableColumnWidths
    ) -> some View {
        TableRowLayout(widths: widths, hasActions: !actions.isEmpty) {
            ForEach(columns) { col in
                Text(row.cells[col.id] ?? "")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment(for: col.alignment))
            }
            if !actions.isEmpty {
                actionButtons(actions, item: row.id)
            }
        }
        .padding(.vertical, 2)
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatCounter(value.value))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                if let unit = value.unit ?? cfg.unit {
                    Text(unit).foregroundStyle(.secondary)
                }
                if let delta = value.delta {
                    Text(formatDelta(delta))
                        .font(.caption)
                        .foregroundStyle(delta >= 0 ? .green : .red)
                }
                Spacer()
            }
        } else {
            Text("No data.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func formatCounter(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int64(value))
        }
        return String(format: "%.2f", value)
    }

    private func formatDelta(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(formatCounter(delta))"
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
            .frame(height: 180)
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
                    get: { engine.placements(forWidget: widget.id, of: instance.id) },
                    set: { engine.setPlacements($0, forWidget: widget.id, of: instance.id) }
                )
            )
        } else {
            Text("No data.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func invoke(action: String, item: String) {
        guard let instance else { return }
        let engine = engine
        Task { @MainActor in
            await engine.invokeRowAction(instance: instance, widget: widget.id, action: action, item: item)
        }
    }

    @MainActor
    private func consumeUpdates() async {
        guard let instance else { return }
        let widgetID = widget.id
        let instanceID = instance.id
        let engine = engine
        state = engine.widgetState(instanceID: instanceID, widget: widgetID)
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
        frames.isPaused = true
        let batch = kinds
        kinds.removeAll()
        apply(batch)
    }
}

private struct ConsoleWidgetView: View {
    let entries: [WidgetConsoleEntry]
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
                        ForEach(entries) { entry in
                            entryRow(entry)
                                .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .frame(maxWidth: .infinity, minHeight: Self.minLogHeight, alignment: .bottomLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.maxLogHeight)
                .fixedSize(horizontal: false, vertical: true)
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
    private static let minLogHeight: CGFloat = 64
    private static let maxLogHeight: CGFloat = 400

    private func entryRow(_ entry: WidgetConsoleEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            entryKindGlyph(entry.kind)
            entryBody(entry)
        }
        .font(.system(.caption, design: .monospaced))
        .contextMenu {
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

    private static var maxHeight: CGFloat { 340 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: spacing) {
                rows
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
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
        var x = bounds.minX
        for (subview, width) in zip(subviews, columns.cells) {
            let cell = ProposedViewSize(width: width, height: bounds.height)
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
