import Cairo
import CGraphene
import CGtk
import Foundation
import Gdk
import Gtk
import LumaCore
import Observation
import Pango

@MainActor
final class InstrumentWidgetsRenderer {
    let widget: Box

    private weak var engine: Engine?
    private let instance: LumaCore.InstrumentInstance?
    private var canvases: [WidgetCanvas] = []
    private var area: ArrangedWidgetArea?
    private var subscriber: Task<Void, Never>?
    private var queued: [WidgetUpdate] = []
    private static let burstInterval = Duration.milliseconds(100)
    private let actionGate: WidgetActionGate

    init(
        engine: Engine, instance: LumaCore.InstrumentInstance?, child: InstrumentChild?, widgets: [InstrumentWidget], layout: InstrumentLayout,
        above: [Widget], margin: Int32
    ) {
        self.engine = engine
        self.instance = instance
        actionGate = WidgetActionGate { [weak engine] action, widget in
            guard let engine, let instance else { return false }
            return action.map { engine.canChoose($0, of: widget, instance: instance) } ?? engine.canChooseWidgetActions(of: instance)
        }

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        let updates = instance.map { _ in engine.widgetUpdates }

        for definition in widgets {
            let slot = child?.widgetKey(definition.id) ?? definition.id
            let snapshot = instance.map { engine.widgetState(instanceID: $0.id, widget: slot) } ?? WidgetState()
            let canvas = WidgetCanvas(
                definition: definition,
                slot: slot,
                snapshot: snapshot,
                engine: engine,
                instance: instance,
                actionGate: actionGate,
                onWidgetAction: { [weak self] action in
                    self?.invoke(widget: slot, action: action)
                },
                onAction: { [weak self] action, item in
                    self?.invoke(widget: slot, action: action, item: item)
                },
                onConsoleSubmit: { [weak self] text in
                    self?.submitConsole(widget: slot, text: text)
                },
                onRowTally: { [weak self] tally in
                    self?.area?.setTally(tally, of: definition.id)
                }
            )
            canvases.append(canvas)
        }

        let area = ArrangedWidgetArea(
            above: above,
            margin: margin,
            layout: layout,
            widgets: widgets,
            cards: canvases.map { canvas -> (id: String, card: Widget) in (canvas.definition.id, canvas.widget) },
            tallies: Dictionary(uniqueKeysWithValues: canvases.compactMap { canvas -> (String, RowTally)? in canvas.rowTally.map { (canvas.definition.id, $0) } }),
            metrics: WidgetCardMetrics.measured)
        self.area = area
        widget.append(child: area.widget)

        startSubscriber(updates)
        followAgentState()
    }

    deinit {
        subscriber?.cancel()
    }

    func cover(with widget: Widget) {
        area?.cover(with: widget)
    }

    func setCovered(_ covered: Bool) {
        area?.setCovered(covered)
    }

    func refreshAgentState() {
        actionGate.refresh()
        let input = consoleInput
        for canvas in canvases {
            canvas.setConsoleInput(enabled: input.enabled, reason: input.reason)
        }
    }

    private var consoleInput: (enabled: Bool, reason: String?) {
        guard let engine, let instance else { return (false, "Session not attached.") }
        if engine.canSubmitConsoleInput(of: instance) { return (true, nil) }
        if let waiting = InstrumentWaitingMark.sentence(engine: engine, instance: instance) { return (false, "\(waiting).") }
        if engine.isHostedRemotelyLive(instance.sessionID) { return (false, "Only the member hosting this session can type here.") }
        if engine.isHostingNode(instance.sessionID) { return (false, "The instrument is not running.") }
        return (false, "Session not attached.")
    }

    private func startSubscriber(_ updates: AsyncStream<WidgetUpdate>?) {
        guard let updates, let instanceID = instance?.id else { return }
        subscriber = Task { @MainActor [weak self] in
            for await update in updates where update.instanceID == instanceID {
                self?.enqueue(update)
            }
        }
    }

    private func enqueue(_ update: WidgetUpdate) {
        queued.append(update)
        guard queued.count == 1 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.burstInterval)
            self?.dispatchQueued()
        }
    }

    private func dispatchQueued() {
        let batch = queued
        queued.removeAll()
        for canvas in canvases {
            canvas.apply(batch.filter { $0.widget == canvas.slot })
        }
    }

    private func followAgentState() {
        withObservationTracking {
            refreshAgentState()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAgentState() }
        }
    }

    private func invoke(widget: String, action: String) {
        guard let engine, let instance else { return }
        Task { @MainActor in
            await engine.invokeWidgetAction(instance: instance, widget: widget, action: action)
        }
    }

    private func invoke(widget: String, action: String, item: String) {
        guard let engine, let instance else { return }
        Task { @MainActor in
            await engine.invokeRowAction(instance: instance, widget: widget, action: action, item: item)
        }
    }

    private func submitConsole(widget: String, text: String) {
        guard let engine, let instance else { return }
        Task { @MainActor in
            await engine.submitConsoleInput(instance: instance, widget: widget, text: text)
        }
    }
}

@MainActor
private final class WidgetCanvas {
    let definition: InstrumentWidget
    let slot: String
    let widget: Box
    private let onAction: (_ action: String, _ item: String) -> Void
    private var counterView: CounterView?
    private var histogramView: HistogramView?
    private var graphView: GraphView?
    private var listView: WidgetRowList<ListItemPresenter>?
    private var tableView: WidgetRowList<TableRowPresenter>?
    private var hexView: HexWidgetView?
    private var consoleWidget: ConsoleWidget?
    private var viewWidget: InstrumentViewWidget?

    init(
        definition: InstrumentWidget,
        slot: String,
        snapshot: WidgetState,
        engine: Engine,
        instance: LumaCore.InstrumentInstance?,
        actionGate: WidgetActionGate,
        onWidgetAction: @escaping (_ action: String) -> Void,
        onAction: @escaping (_ action: String, _ item: String) -> Void,
        onConsoleSubmit: @escaping (_ text: String) -> Void,
        onRowTally: @escaping (_ tally: RowTally) -> Void
    ) {
        self.definition = definition
        self.slot = slot
        self.onAction = onAction

        widget = Box(orientation: .vertical, spacing: 0)

        if definition.title != nil || !definition.actions.isEmpty {
            widget.append(child: Self.makeHeader(definition, slot: slot, gate: actionGate, onPress: onWidgetAction))
        }

        let card = Box(orientation: .vertical, spacing: 0)
        card.add(cssClass: "luma-widget-box")
        card.vexpand = true
        Self.setAccessibleLabel(definition.label, of: card)
        widget.append(child: card)

        let column = Box(orientation: .vertical, spacing: 6)
        column.marginStart = Self.boxInset
        column.marginEnd = Self.boxInset
        column.marginTop = Self.boxInset
        column.marginBottom = Self.boxInset
        column.vexpand = true
        card.append(child: column)

        switch definition.kind {
        case .counter(let cfg):
            let view = CounterView(unit: cfg.unit, initial: snapshot.counter)
            counterView = view
            column.append(child: view.widget)
        case .histogram:
            let view = HistogramView(initial: snapshot.histogram)
            histogramView = view
            column.append(child: view.widget)
        case .graph(let cfg):
            let view = GraphView(series: cfg.series, initialSeries: snapshot.graphSeries)
            graphView = view
            column.append(child: view.widget)
        case .list(let cfg):
            let view = WidgetRowList(kind: definition.kind, initial: snapshot, rows: \.listItems, header: nil, emptyText: "No items.") {
                ListItemPresenter(actions: cfg.rowActions, gate: actionGate, onAction: onAction)
            }
            view.onRowTally = onRowTally
            listView = view
            column.append(child: view.widget)
        case .table(let cfg):
            let layout = TableLayout(columns: cfg.columns, actions: cfg.rowActions)
            let header = layout.makeHeader()
            let view = WidgetRowList(kind: definition.kind, initial: snapshot, rows: { layout.fit($0.tableRows) }, header: header, emptyText: "No rows.") {
                TableRowPresenter(layout: layout, gate: actionGate, onAction: onAction)
            }
            view.onRowTally = onRowTally
            tableView = view
            column.append(child: view.widget)
        case .hex:
            if let instance {
                let view = HexWidgetView(initial: snapshot.hex, engine: engine, instance: instance, widgetID: slot)
                hexView = view
                column.append(child: view.widget)
            } else {
                let empty = Label(str: "No data.")
                empty.add(cssClass: "dim-label")
                empty.add(cssClass: "luma-widget-empty")
                empty.halign = .start
                column.append(child: empty)
            }
        case .console(let cfg):
            let view = ConsoleWidget(
                config: cfg,
                initialEntries: snapshot.consoleEntries,
                widgetName: definition.label,
                engine: engine,
                sessionID: instance?.sessionID ?? UUID(),
                onSubmit: onConsoleSubmit
            )
            consoleWidget = view
            column.append(child: view.widget)
        case .view(let cfg):
            if let instance {
                let view = InstrumentViewWidget(
                    engine: engine, key: .init(instanceID: instance.id, widget: slot), sessionID: instance.sessionID,
                    name: definition.label, config: cfg)
                viewWidget = view
                column.append(child: view.widget)
            }
        }
    }

    static let boxInset = 5
    static let headerSpacing = 4

    var rowTally: RowTally? {
        listView?.rowTally ?? tableView?.rowTally
    }

    static func makeHeader(
        _ definition: InstrumentWidget, slot: String, gate: WidgetActionGate, onPress: @escaping (_ action: String) -> Void
    ) -> Box {
        let header = Box(orientation: .horizontal, spacing: 4)
        header.marginBottom = headerSpacing
        header.setSizeRequest(width: -1, height: 16)
        let title = Label(str: definition.title ?? "")
        title.add(cssClass: "luma-widget-title")
        title.halign = .start
        title.xalign = 0
        title.ellipsize = .end
        title.hexpand = true
        title.valign = .center
        header.append(child: title)
        if !definition.actions.isEmpty {
            header.append(child: WidgetHeaderActions.make(definition.actions, of: slot, gate: gate, onPress: onPress))
        }
        return header
    }

    private static func setAccessibleLabel(_ label: String, of widget: Widget) {
        var value = GValue()
        g_value_init(&value, GType(64))
        g_value_set_string(&value, label)
        var property = GTK_ACCESSIBLE_PROPERTY_LABEL
        let accessible = UnsafeMutableRawPointer(widget.widget_ptr)?.assumingMemoryBound(to: GtkAccessible.self)
        gtk_accessible_update_property_value(accessible, 1, &property, &value)
        g_value_unset(&value)
    }

    func setConsoleInput(enabled: Bool, reason: String?) {
        consoleWidget?.setInput(enabled: enabled, reason: reason)
    }

    func apply(_ updates: [WidgetUpdate]) {
        var appended: [WidgetConsoleEntry] = []
        for update in updates {
            if case .consoleAppend(let entry) = update.kind {
                appended.append(entry)
                continue
            }
            consoleWidget?.append(entries: appended)
            appended.removeAll()
            apply(update)
        }
        consoleWidget?.append(entries: appended)
    }

    private func apply(_ update: WidgetUpdate) {
        switch update.kind {
        case .counterSet(let value):
            counterView?.set(value: value)
        case .histogramSet(let buckets):
            histogramView?.setBuckets(buckets)
        case .histogramIncrement(let label, let by):
            histogramView?.increment(label: label, by: by)
        case .graphPoint(let point):
            graphView?.append(point: point)
        case .listUpsert, .listRemove:
            listView?.apply(update.kind)
        case .tableUpsert, .tableRemove:
            tableView?.apply(update.kind)
        case .hexSet(let state):
            hexView?.set(state: state)
        case .consoleAppend(let entry):
            consoleWidget?.append(entries: [entry])
        case .consoleReplyDone, .viewState, .viewEvent, .viewRefused:
            break
        case .clear:
            counterView?.clear()
            histogramView?.clear()
            graphView?.clear()
            listView?.apply(update.kind)
            tableView?.apply(update.kind)
            hexView?.clear()
            consoleWidget?.clear()
        case .snapshot(let snapshot):
            counterView?.replace(value: snapshot.counter)
            histogramView?.replace(buckets: snapshot.histogram)
            graphView?.replace(series: snapshot.graphSeries)
            listView?.apply(update.kind)
            tableView?.apply(update.kind)
            hexView?.replace(state: snapshot.hex)
            consoleWidget?.replace(entries: snapshot.consoleEntries)
        }
    }
}

@MainActor
enum WidgetCardMetrics {
    static let measured = measure()

    private static let spacing = 12.0

    private static func measure() -> InstrumentLayout.Metrics {
        InstrumentLayout.Metrics(
            spacing: spacing,
            headerHeight: Double(headerHeight()),
            headerSpacing: Double(WidgetCanvas.headerSpacing),
            boxInset: Double(WidgetCanvas.boxInset),
            lineHeight: Double(naturalHeight(of: WidgetEmptyLabel.make("No rows."))),
            rowHeight: Double(tableRowHeight()),
            twoLineRowHeight: Double(twoLineRowHeight()),
            counterHeight: Double(naturalHeight(of: CounterView(unit: "calls", initial: WidgetCounterValue(value: 1)).widget)))
    }

    private static func headerHeight() -> Int {
        let sample = InstrumentWidget(
            id: "sample", name: "Sample", kind: .counter(InstrumentWidget.CounterConfig()),
            actions: [InstrumentWidget.Action(id: "sample", name: "Sample")])
        let header = WidgetCanvas.makeHeader(sample, slot: sample.id, gate: WidgetActionGate { _, _ in true }, onPress: { _ in })
        return naturalHeight(of: header) - WidgetCanvas.headerSpacing
    }

    private static func tableRowHeight() -> Int {
        let layout = TableLayout(
            columns: [InstrumentWidget.Column(id: "sample", name: "Sample")],
            actions: [InstrumentWidget.Action(id: "sample", name: "Sample")])
        let row = TableRowPresenter(layout: layout, gate: WidgetActionGate { _, _ in true }, onAction: { _, _ in })
        return naturalHeight(of: row.widget)
    }

    private static func twoLineRowHeight() -> Int {
        let row = ListItemPresenter(actions: [], gate: WidgetActionGate { _, _ in true }, onAction: { _, _ in })
        row.show(WidgetListItem(id: "sample", title: "Sample", subtitle: "Sample"))
        return naturalHeight(of: row.widget)
    }

    private static func naturalHeight(of widget: Widget) -> Int {
        widget.naturalSize(along: .vertical)
    }
}

@MainActor
private final class WidgetActionGate {
    private let allows: (_ action: String?, _ widget: String) -> Bool
    private var controls: [(control: Widget, widget: String, actions: [String?])] = []

    init(allows: @escaping (_ action: String?, _ widget: String) -> Bool) {
        self.allows = allows
    }

    func refresh() {
        for entry in controls {
            apply(entry)
        }
    }

    func adoptWidgetActions(_ control: Widget, widget: String, actions: [String]) {
        adopt((control, widget, actions))
    }

    func adoptRowAction(_ control: Widget) {
        adopt((control, "", [nil]))
    }

    private func adopt(_ entry: (control: Widget, widget: String, actions: [String?])) {
        controls.append(entry)
        apply(entry)
    }

    private func apply(_ entry: (control: Widget, widget: String, actions: [String?])) {
        entry.control.sensitive = entry.actions.contains { allows($0, entry.widget) }
    }
}

@MainActor
private enum WidgetHeaderActions {
    private static let shownBeforeOverflow = 3

    static func make(
        _ actions: [InstrumentWidget.Action], of widget: String, gate: WidgetActionGate, onPress: @escaping (String) -> Void
    ) -> Box {
        let box = Box(orientation: .horizontal, spacing: 2)
        box.valign = .center
        let shown = actions.count > shownBeforeOverflow ? Array(actions.prefix(shownBeforeOverflow - 1)) : actions
        for action in shown {
            let button = Button(label: action.name)
            button.add(cssClass: "luma-widget-action")
            button.valign = .center
            button.onClicked { _ in
                MainActor.assumeIsolated { onPress(action.id) }
            }
            gate.adoptWidgetActions(button, widget: widget, actions: [action.id])
            box.append(child: button)
        }
        guard shown.count < actions.count else { return box }
        let more = MenuButton()
        more.add(cssClass: "luma-widget-action")
        more.valign = .center
        more.set(iconName: "view-more-symbolic")
        more.tooltipText = "More Actions"
        let rest = Array(actions.dropFirst(shown.count))
        more.set(popover: overflowMenu(rest, of: widget, gate: gate, onPress: onPress))
        gate.adoptWidgetActions(more, widget: widget, actions: rest.map(\.id))
        box.append(child: more)
        return box
    }

    private static func overflowMenu(
        _ actions: [InstrumentWidget.Action], of widget: String, gate: WidgetActionGate, onPress: @escaping (String) -> Void
    ) -> Popover {
        let popover = Popover()
        let list = Box(orientation: .vertical, spacing: 0)
        for action in actions {
            let item = Button(label: action.name)
            item.add(cssClass: "flat")
            item.onClicked { [popover] _ in
                MainActor.assumeIsolated {
                    popover.popdown()
                    onPress(action.id)
                }
            }
            gate.adoptWidgetActions(item, widget: widget, actions: [action.id])
            list.append(child: item)
        }
        popover.set(child: list)
        return popover
    }
}

@MainActor
private final class ConsoleWidget {
    let widget: Box
    private weak var engine: Engine?
    private let sessionID: UUID
    private let widgetName: String
    private let console: ConsoleView
    private let inputPlaceholder: String
    private let promptGlyph: String
    private var valueWidgetKeepers: [JSInspectValueWidget] = []
    private let maxEntries: Int
    private var rows: [Widget] = []

    init(
        config: InstrumentWidget.ConsoleConfig,
        initialEntries: [WidgetConsoleEntry],
        widgetName: String,
        engine: Engine,
        sessionID: UUID,
        onSubmit: @escaping (_ text: String) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.widgetName = widgetName
        maxEntries = config.maxEntries
        let placeholder = config.placeholder ?? ""
        inputPlaceholder = placeholder
        promptGlyph = config.prompt ?? "\u{203A}"
        let style = ConsoleView.Style(
            promptGlyph: promptGlyph,
            placeholder: placeholder,
            runButtonLabel: config.runButtonLabel ?? "Run"
        )
        console = ConsoleView(style: style, emptyState: Self.makeEmptyState())
        console.onSubmit = onSubmit
        console.setInputEnabled(false, placeholder: "Session not attached.")
        console.fitLogToContent(minHeight: 64, maxHeight: 400)
        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "luma-widget-console")
        widget.hexpand = true
        widget.append(child: console.widget)

        append(entries: initialEntries)
        console.setHistory(initialEntries.filter { $0.kind == .input }.map(\.text))
    }

    func setInput(enabled: Bool, reason: String?) {
        console.setInputEnabled(enabled, placeholder: reason ?? inputPlaceholder)
    }

    func append(entries: [WidgetConsoleEntry]) {
        for entry in entries.suffix(maxEntries) {
            let row = makeRow(for: entry)
            rows.append(row)
            console.appendEntry(row)
        }
        let excess = rows.count - maxEntries
        guard excess > 0 else { return }
        for row in rows.prefix(excess) {
            console.removeEntry(row)
        }
        rows.removeFirst(excess)
        if valueWidgetKeepers.count > maxEntries {
            valueWidgetKeepers.removeFirst(valueWidgetKeepers.count - maxEntries)
        }
    }

    func clear() {
        console.clearEntries()
        console.setHistory([])
        rows.removeAll()
        valueWidgetKeepers.removeAll()
    }

    func replace(entries: [WidgetConsoleEntry]) {
        console.clearEntries()
        rows.removeAll()
        valueWidgetKeepers.removeAll()
        append(entries: entries)
        console.setHistory(entries.filter { $0.kind == .input }.map(\.text))
    }

    private func makeRow(for entry: WidgetConsoleEntry) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 6)
        let glyph: String
        let bodyCssClass: String?
        switch entry.kind {
        case .input:
            glyph = promptGlyph
            bodyCssClass = nil
        case .output:
            glyph = ""
            bodyCssClass = nil
        case .image:
            glyph = "\u{1F5BC}"
            bodyCssClass = nil
        case .error:
            glyph = "\u{26A0}"
            bodyCssClass = "error"
        }
        let glyphLabel = Label(str: glyph)
        glyphLabel.add(cssClass: "monospace")
        glyphLabel.add(cssClass: bodyCssClass ?? "dim-label")
        glyphLabel.widthChars = 1
        glyphLabel.valign = .start
        row.append(child: glyphLabel)
        row.append(child: makeBody(for: entry, cssClass: bodyCssClass))
        attachContextMenu(to: row, entry: entry)
        return row
    }

    private func attachContextMenu(to anchor: Box, entry: WidgetConsoleEntry) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.onPressed { [weak self, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                self?.presentRowContextMenu(at: anchor, x: x, y: y, entry: entry)
            }
        }
        anchor.add(controller: gesture)
    }

    private func presentRowContextMenu(at anchor: Widget, x: Double, y: Double, entry: WidgetConsoleEntry) {
        ContextMenu.present([
            [
                .init("Add to Notebook") { [weak self] in
                    self?.addEntryToNotebook(entry)
                },
            ],
        ], at: anchor, x: x, y: y)
    }

    private func addEntryToNotebook(_ entry: WidgetConsoleEntry) {
        guard let engine else { return }
        let processName = engine.sessions.first { $0.id == sessionID }?.processName ?? ""
        var notebookEntry = LumaCore.NotebookEntry(
            title: notebookTitle(for: entry),
            details: entry.value == nil ? entry.text : "",
            binaryData: nil,
            sessionID: sessionID,
            processName: processName
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

    private func makeBody(for entry: WidgetConsoleEntry, cssClass: String?) -> Widget {
        if let image = entry.image, let texture = IconPixbuf.makeTexture(fromEncodedData: image.data) {
            return makeImageBody(text: entry.text, texture: texture)
        }
        if let value = entry.value, let engine {
            let valueWidget = JSInspectValueWidget.make(value: value, engine: engine, sessionID: sessionID)
            valueWidgetKeepers.append(valueWidget)
            return valueWidget.widget
        }
        let body = Label(str: DisplayTruncation.truncated(entry.text))
        body.add(cssClass: "monospace")
        if let cssClass { body.add(cssClass: cssClass) }
        body.halign = .start
        body.hexpand = true
        body.wrap = true
        body.selectable = true
        return body
    }

    private func makeImageBody(text: String, texture: Gdk.Texture) -> Widget {
        let box = Box(orientation: .vertical, spacing: 4)
        box.halign = .start
        if !text.isEmpty {
            let caption = Label(str: DisplayTruncation.truncated(text))
            caption.add(cssClass: "monospace")
            caption.halign = .start
            caption.wrap = true
            caption.selectable = true
            box.append(child: caption)
        }
        let picture = Picture(paintable: texture)
        picture.canShrink = true
        picture.contentFit = .scaleDown
        picture.halign = .start
        box.append(child: picture)
        return box
    }

    private static func makeEmptyState() -> Widget {
        let box = Box(orientation: .vertical, spacing: 8)
        box.halign = .center
        box.valign = .center
        box.marginTop = 16
        box.marginBottom = 16
        let label = Label(str: "Awaiting input\u{2026}")
        label.add(cssClass: "dim-label")
        box.append(child: label)
        return box
    }
}

@MainActor
private final class GraphView {
    let widget: Box
    private let drawingArea: DrawingArea
    private let series: [InstrumentWidget.Series]
    private var points: [String: [WidgetGraphPoint]]

    init(series: [InstrumentWidget.Series], initialSeries: [String: [WidgetGraphPoint]]) {
        self.series = series
        self.points = initialSeries

        widget = Box(orientation: .vertical, spacing: 4)
        drawingArea = DrawingArea()
        drawingArea.hexpand = true
        drawingArea.vexpand = true
        drawingArea.contentHeight = 180
        widget.append(child: drawingArea)
        widget.append(child: Self.makeLegend(series))

        drawingArea.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated {
                self?.draw(ctx: ctx, width: Double(width), height: Double(height))
            }
        }
    }

    func append(point: WidgetGraphPoint) {
        points[point.series, default: []].append(point)
        drawingArea.queueDraw()
    }

    func clear() {
        points.removeAll()
        drawingArea.queueDraw()
    }

    func replace(series: [String: [WidgetGraphPoint]]) {
        points = series
        drawingArea.queueDraw()
    }

    private static func makeLegend(_ series: [InstrumentWidget.Series]) -> Box {
        let legend = Box(orientation: .horizontal, spacing: 12)
        for (index, definition) in series.enumerated() {
            let entry = Box(orientation: .horizontal, spacing: 4)
            let swatch = DrawingArea()
            swatch.contentWidth = 8
            swatch.contentHeight = 8
            swatch.valign = .center
            swatch.setDrawFunc { _, ctx, width, height in
                let color = ChartFrame.seriesColor(at: index)
                ctx.setSource(red: color.0, green: color.1, blue: color.2, alpha: 1)
                ctx.arc(xc: Double(width) / 2, yc: Double(height) / 2, radius: 4)
                ctx.fill()
            }
            entry.append(child: swatch)
            let name = Label(str: definition.name)
            name.add(cssClass: "luma-chart-legend")
            name.add(cssClass: "dim-label")
            entry.append(child: name)
            legend.append(child: entry)
        }
        return legend
    }

    private func draw(ctx: Cairo.ContextRef, width: Double, height: Double) {
        guard let bounds = computeBounds() else { return }
        let yTicks = ChartFrame.ticks(upTo: bounds.y.upperBound, from: bounds.y.lowerBound)
        let xTicks = ChartFrame.ticks(upTo: bounds.x.upperBound, from: bounds.x.lowerBound).filter { bounds.x.contains($0) }
        let frame = ChartFrame(area: drawingArea, width: width, height: height, yTicks: yTicks)
        let xRange = bounds.x
        let yRange = yTicks.first!...yTicks.last!
        frame.drawGrid(ctx, verticalAt: xTicks.map { frame.plot.minX + frame.plot.width * normalize($0, in: xRange) })
        for tick in xTicks {
            let x = frame.plot.minX + frame.plot.width * normalize(tick, in: xRange)
            frame.drawText(ctx, ChartFrame.format(tick), x: x + 3, y: frame.plot.maxY + 3, maxWidth: nil, centered: false)
        }

        for (index, definition) in series.enumerated() {
            guard let line = points[definition.id], !line.isEmpty else { continue }
            let color = ChartFrame.seriesColor(at: index)
            ctx.setSource(red: color.0, green: color.1, blue: color.2, alpha: 1.0)
            let positions = line.map {
                (frame.plot.minX + frame.plot.width * normalize($0.x, in: xRange), frame.plot.maxY - frame.plot.height * normalize($0.y, in: yRange))
            }
            if positions.count == 1 {
                ctx.arc(xc: positions[0].0, yc: positions[0].1, radius: 3)
                ctx.fill()
                continue
            }
            ctx.lineWidth = 2
            ctx.moveTo(positions[0].0, positions[0].1)
            for position in positions.dropFirst() {
                ctx.lineTo(position.0, position.1)
            }
            ctx.stroke()
        }
    }

    private func computeBounds() -> (x: ClosedRange<Double>, y: ClosedRange<Double>)? {
        let all = points.values.joined()
        guard let xMin = all.map(\.x).min(), let xMax = all.map(\.x).max(), let yMin = all.map(\.y).min(),
            let yMax = all.map(\.y).max()
        else { return nil }
        let x = xMin == xMax ? (xMin - 0.5)...(xMax + 0.5) : xMin...xMax
        let y = yMin == yMax ? (yMin - 0.5)...(yMax + 0.5) : yMin...yMax
        return (x, min(0, y.lowerBound)...max(0, y.upperBound))
    }

    private func normalize(_ value: Double, in range: ClosedRange<Double>) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}

@MainActor
private struct ChartFrame {
    let plot: (minX: Double, maxX: Double, minY: Double, maxY: Double, width: Double, height: Double)
    private let area: DrawingArea
    private let yTicks: [Double]
    private let color: GdkRGBA

    static let palette: [(Double, Double, Double)] = [0x2F7BF6, 0xF08A24, 0x2EA44F, 0xE5484D, 0x8E5BD9, 0x1AA7A1, 0xA0703B, 0xD9468F].map(rgb)

    nonisolated private static func rgb(_ hex: Int) -> (Double, Double, Double) {
        let red = Double(hex >> 16) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        return (red, green, blue)
    }

    static func seriesColor(at index: Int) -> (Double, Double, Double) {
        palette[index % palette.count]
    }

    static func ticks(upTo top: Double, from bottom: Double) -> [Double] {
        let span = top - bottom
        let raw = span / 4
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= raw }!
        let first = floor(bottom / step) * step
        let last = ceil(top / step) * step
        return stride(from: first, through: last + step / 2, by: step).map { $0 }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    init(area: DrawingArea, width: Double, height: Double, yTicks: [Double]) {
        self.area = area
        self.yTicks = yTicks
        var color = GdkRGBA()
        gtk_widget_get_color(area.widget_ptr, &color)
        self.color = color
        let labelWidth = yTicks.map { Self.measure(area, Self.format($0)).width }.max() ?? 0
        let labelHeight = Self.measure(area, "0").height
        let maxX = width - labelWidth - 6
        let minY = labelHeight / 2
        let maxY = height - labelHeight - 4
        plot = (0, maxX, minY, maxY, maxX, maxY - minY)
    }

    func drawGrid(_ ctx: Cairo.ContextRef, verticalAt xs: [Double]) {
        ctx.setSource(red: Double(color.red), green: Double(color.green), blue: Double(color.blue), alpha: 0.12)
        ctx.lineWidth = 1
        let span = yTicks.last! - yTicks.first!
        for tick in yTicks {
            let y = (plot.maxY - plot.height * (tick - yTicks.first!) / span).rounded() + 0.5
            ctx.moveTo(plot.minX, y)
            ctx.lineTo(plot.maxX, y)
            ctx.stroke()
            drawText(ctx, Self.format(tick), x: plot.maxX + 6, y: y - Self.measure(area, "0").height / 2, maxWidth: nil, centered: false)
            ctx.setSource(red: Double(color.red), green: Double(color.green), blue: Double(color.blue), alpha: 0.12)
        }
        ctx.setDash([2.0, 2.0], offset: 0.0)
        for x in xs {
            ctx.moveTo(x.rounded() + 0.5, plot.minY)
            ctx.lineTo(x.rounded() + 0.5, plot.maxY + 4)
            ctx.stroke()
        }
        ctx.setDash([], offset: 0.0)
    }

    func drawText(_ ctx: Cairo.ContextRef, _ text: String, x: Double, y: Double, maxWidth: Double?, centered: Bool) {
        let layout = Self.layout(area, text)
        defer { g_object_unref(layout) }
        if let maxWidth {
            pango_layout_set_width(layout, Int32(maxWidth * Double(PANGO_SCALE)))
            pango_layout_set_ellipsize(layout, EllipsizeMode.end.value)
        }
        var width: gint = 0
        var height: gint = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        ctx.setSource(red: Double(color.red), green: Double(color.green), blue: Double(color.blue), alpha: 0.55)
        ctx.moveTo(centered ? x - Double(width) / 2 : x, y)
        pango_cairo_show_layout(ctx._ptr, layout)
    }

    private static func measure(_ area: DrawingArea, _ text: String) -> (width: Double, height: Double) {
        let layout = layout(area, text)
        defer { g_object_unref(layout) }
        var width: gint = 0
        var height: gint = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        return (Double(width), Double(height))
    }

    private static func layout(_ area: DrawingArea, _ text: String) -> UnsafeMutablePointer<PangoLayout> {
        let layout = gtk_widget_create_pango_layout(area.widget_ptr, text)!
        let font = pango_font_description_copy(pango_context_get_font_description(pango_layout_get_context(layout)))
        pango_font_description_set_absolute_size(font, 10 * Double(PANGO_SCALE))
        pango_layout_set_font_description(layout, font)
        pango_font_description_free(font)
        return layout
    }
}

@MainActor
private protocol WidgetRowPresenter: AnyObject {
    associatedtype Row: Identifiable & Equatable

    var widget: Box { get }

    static func isTwoLine(_ row: Row) -> Bool

    func show(_ row: Row)
}

@MainActor
private final class WidgetRowList<Presenter: WidgetRowPresenter> {
    let widget: Box
    private let kind: InstrumentWidget.Kind
    private let rowsOfState: (WidgetState) -> [Presenter.Row]
    private let makePresenter: () -> Presenter
    private let model: StringList
    private let scroller: ScrolledWindow
    private let emptyLabel: Label
    private let header: Widget?
    private var state: WidgetState
    private var shownRows: [Presenter.Row] = []
    private var presenters: [UnsafeMutableRawPointer: Presenter] = [:]
    private var refresh = Refresh.idle
    var onRowTally: ((RowTally) -> Void)?

    var rowTally: RowTally {
        RowTally(count: shownRows.count, subtitled: shownRows.filter(Presenter.isTwoLine).count)
    }

    private enum Refresh {
        case idle
        case scheduled
    }

    private static var maxHeight: Int { 340 }

    init(
        kind: InstrumentWidget.Kind,
        initial: WidgetState,
        rows rowsOfState: @escaping (WidgetState) -> [Presenter.Row],
        header: Widget?,
        emptyText: String,
        makePresenter: @escaping () -> Presenter
    ) {
        self.kind = kind
        self.rowsOfState = rowsOfState
        self.makePresenter = makePresenter
        state = initial

        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "boxed-list")
        self.header = header
        if let header {
            widget.append(child: header)
        }

        model = StringList(strings: nil)
        let selection = NoSelection(model: model)
        let factory = SignalListItemFactory()
        let list = Gtk.ListView(model: selection, factory: factory)
        list.add(cssClass: "luma-widget-rows")
        _ = g_object_ref(model.ptr)
        _ = g_object_ref(selection.ptr)

        scroller = ScrolledWindow()
        scroller.add(cssClass: "luma-widget-rows")
        scroller.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroller.propagateNaturalHeight = true
        scroller.maxContentHeight = Self.maxHeight
        scroller.vexpand = true
        scroller.set(child: list)
        widget.append(child: scroller)

        emptyLabel = WidgetEmptyLabel.make(emptyText)
        widget.append(child: emptyLabel)

        configure(factory)
        refreshRows()
    }

    func apply(_ update: WidgetUpdate.Kind) {
        state.apply(update)
        state.cap(to: kind)
        guard refresh == .idle else { return }
        refresh = .scheduled
        NextFrame.run(on: widget) { [weak self] in
            self?.refreshRows()
        }
    }

    private func configure(_ factory: SignalListItemFactory) {
        factory.onSetup { [weak self] _, object in
            MainActor.assumeIsolated {
                guard let self else { return }
                let presenter = self.makePresenter()
                self.presenters[presenter.widget.ptr] = presenter
                ListItemRef(raw: object.ptr).set(child: presenter.widget)
            }
        }
        factory.onBind { [weak self] _, object in
            MainActor.assumeIsolated {
                guard let self else { return }
                let item = ListItemRef(raw: object.ptr)
                guard let child = item.child, let presenter = self.presenters[child.ptr] else { return }
                presenter.show(self.shownRows[item.position])
            }
        }
        factory.onTeardown { [weak self] _, object in
            MainActor.assumeIsolated {
                guard let self, let child = ListItemRef(raw: object.ptr).child else { return }
                self.presenters.removeValue(forKey: child.ptr)
            }
        }
    }

    private func refreshRows() {
        refresh = .idle
        let rows = rowsOfState(state)

        let dropped = leadingRowsDropped(before: rows)
        if dropped > 0 {
            shownRows.removeFirst(dropped)
            splice(at: 0, removing: dropped, adding: 0)
        }

        let kept = zip(shownRows, rows).prefix { $0.0 == $0.1 }.count
        let keptAtEnd = zip(shownRows[kept...].reversed(), rows[kept...].reversed()).prefix { $0.0 == $0.1 }.count
        let removed = shownRows.count - kept - keptAtEnd
        shownRows = rows
        splice(at: kept, removing: removed, adding: rows.count - kept - keptAtEnd)

        header?.visible = !rows.isEmpty
        scroller.visible = !rows.isEmpty
        emptyLabel.visible = rows.isEmpty
        onRowTally?(rowTally)
    }

    private func leadingRowsDropped(before rows: [Presenter.Row]) -> Int {
        guard let first = rows.first, shownRows.first?.id != first.id else { return 0 }
        return shownRows.firstIndex { $0.id == first.id } ?? 0
    }

    private func splice(at position: Int, removing removals: Int, adding additions: Int) {
        guard removals > 0 || additions > 0 else { return }
        "".withCString { blank in
            let blanks = [UnsafePointer<CChar>?](repeating: blank, count: additions) + [nil]
            blanks.withUnsafeBufferPointer {
                model.splice(position: position, nRemovals: removals, additions: $0.baseAddress)
            }
        }
    }
}

@MainActor
private enum WidgetEmptyLabel {
    static func make(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "dim-label")
        label.add(cssClass: "luma-widget-empty")
        label.halign = .start
        label.marginTop = 2
        label.marginBottom = 2
        return label
    }
}

@MainActor
private final class NextFrame {
    private let work: () -> Void

    private init(_ work: @escaping () -> Void) {
        self.work = work
    }

    static func run(on widget: Widget, _ work: @escaping () -> Void) {
        gtk_widget_add_tick_callback(
            widget.widget_ptr!,
            { _, _, frame in
                MainActor.assumeIsolated { Unmanaged<NextFrame>.fromOpaque(frame!).takeUnretainedValue().work() }
                return gboolean(0)
            },
            Unmanaged.passRetained(NextFrame(work)).toOpaque(),
            { frame in Unmanaged<NextFrame>.fromOpaque(frame!).release() })
    }
}

@MainActor
private final class ListItemPresenter: WidgetRowPresenter {
    let widget: Box
    private let title: Label
    private let subtitle: Label
    private let accessory: Label
    private var itemID = ""

    init(actions: [InstrumentWidget.Action], gate: WidgetActionGate, onAction: @escaping (_ action: String, _ item: String) -> Void) {
        widget = Box(orientation: .horizontal, spacing: 8)
        widget.marginTop = 2
        widget.marginBottom = 2

        let column = Box(orientation: .vertical, spacing: 2)
        column.hexpand = true
        gtk_box_set_baseline_child(UnsafeMutableRawPointer(column.widget_ptr)?.assumingMemoryBound(to: GtkBox.self), 0)
        column.valign = .baselineFill
        title = Label(str: "")
        title.add(cssClass: "luma-list-title")
        title.halign = .start
        title.xalign = 0
        title.ellipsize = .end
        column.append(child: title)
        subtitle = Label(str: "")
        subtitle.add(cssClass: "luma-list-detail")
        subtitle.add(cssClass: "dim-label")
        subtitle.halign = .start
        subtitle.xalign = 0
        subtitle.ellipsize = .end
        column.append(child: subtitle)
        widget.append(child: column)

        accessory = Label(str: "")
        accessory.add(cssClass: "luma-list-detail")
        accessory.add(cssClass: "dim-label")
        accessory.valign = .baselineFill
        widget.append(child: accessory)

        let buttons = Box(orientation: .horizontal, spacing: 2)
        buttons.valign = .center
        widget.append(child: buttons)
        for action in actions {
            let button = Button(label: action.name)
            button.add(cssClass: "luma-widget-action")
            button.valign = .center
            let actionID = action.id
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    onAction(actionID, self.itemID)
                }
            }
            gate.adoptRowAction(button)
            buttons.append(child: button)
        }
    }

    static func isTwoLine(_ item: WidgetListItem) -> Bool {
        item.subtitle != nil
    }

    func show(_ item: WidgetListItem) {
        itemID = item.id
        title.setText(str: item.title)
        subtitle.setText(str: item.subtitle ?? "")
        subtitle.visible = item.subtitle != nil
        accessory.setText(str: item.accessory ?? "")
        accessory.visible = item.accessory != nil
    }
}

@MainActor
private final class TableRowPresenter: WidgetRowPresenter {
    let widget: Box
    private let layout: TableLayout
    private let cells: [Label]
    private var rowID = ""

    init(layout: TableLayout, gate: WidgetActionGate, onAction: @escaping (_ action: String, _ item: String) -> Void) {
        self.layout = layout
        widget = layout.makeRow(header: false)

        cells = layout.columns.indices.map { layout.makeCell(column: $0, text: "") }
        for cell in cells {
            widget.append(child: cell)
        }

        guard !layout.actions.isEmpty else { return }
        let buttons = layout.makeActionsBox()
        for action in layout.actions {
            let button = Button(label: action.name)
            button.add(cssClass: "luma-widget-action")
            button.valign = .center
            let actionID = action.id
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    onAction(actionID, self.rowID)
                }
            }
            gate.adoptRowAction(button)
            buttons.append(child: button)
        }
        widget.append(child: buttons)
    }

    static func isTwoLine(_ row: WidgetTableRow) -> Bool {
        false
    }

    func show(_ row: WidgetTableRow) {
        rowID = row.id
        for (cell, column) in zip(cells, layout.columns) {
            cell.setText(str: row.cells[column.id] ?? "")
        }
    }
}

@MainActor
private final class TableLayout {
    let columns: [InstrumentWidget.Column]
    let actions: [InstrumentWidget.Action]
    private let actionsWidth = SizeGroup(mode: .horizontal)
    private var longest: [Int]
    private var header: Box?
    private var advance: Double?

    private static let spacing = 8
    private static let minimumCharacters = 6.0

    init(columns: [InstrumentWidget.Column], actions: [InstrumentWidget.Action]) {
        self.columns = columns
        self.actions = actions
        longest = columns.map(\.name.count)
    }

    func fit(_ rows: [WidgetTableRow]) -> [WidgetTableRow] {
        let fitted = columns.map { column in rows.reduce(column.name.count) { max($0, ($1.cells[column.id] ?? "").count) } }
        if fitted != longest {
            longest = fitted
            header?.parent.map { Self.queueAllocate(rowsUnder: $0.widget_ptr) }
        }
        return rows
    }

    func makeHeader() -> Box {
        let header = makeRow(header: true)
        for index in columns.indices {
            let label = makeCell(column: index, text: columns[index].name)
            label.add(cssClass: "dim-label")
            header.append(child: label)
        }
        if !actions.isEmpty {
            header.append(child: makeActionsBox())
        }
        self.header = header
        return header
    }

    func makeRow(header: Bool) -> Box {
        let row = Box(orientation: .horizontal, spacing: 0)
        row.add(cssClass: header ? "luma-table-header" : "luma-table-row")
        g_object_set_data(UnsafeMutableRawPointer(row.widget_ptr)?.assumingMemoryBound(to: GObject.self), Self.key, Unmanaged.passUnretained(self).toOpaque())
        gtk_widget_set_layout_manager(row.widget_ptr, gtk_custom_layout_new(nil, Self.measure, Self.allocate))
        return row
    }

    func makeCell(column index: Int, text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "luma-table-text")
        label.xalign = columns[index].alignment == .leading ? 0 : 1
        label.ellipsize = EllipsizeMode.end
        return label
    }

    func makeActionsBox() -> Box {
        let box = Box(orientation: .horizontal, spacing: 2)
        actionsWidth.add(widget: box)
        return box
    }

    private static let key = "luma-table-layout"

    private static func layout(of row: UnsafeMutablePointer<GtkWidget>?) -> TableLayout {
        let data = g_object_get_data(UnsafeMutableRawPointer(row)?.assumingMemoryBound(to: GObject.self), key)!
        return Unmanaged<TableLayout>.fromOpaque(data).takeUnretainedValue()
    }

    private static func children(of row: UnsafeMutablePointer<GtkWidget>?) -> [UnsafeMutablePointer<GtkWidget>] {
        var children: [UnsafeMutablePointer<GtkWidget>] = []
        var child = gtk_widget_get_first_child(row)
        while let each = child {
            children.append(each)
            child = gtk_widget_get_next_sibling(each)
        }
        return children
    }

    private static func natural(of child: UnsafeMutablePointer<GtkWidget>, _ orientation: GtkOrientation, for size: Int32) -> (Int32, Int32) {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(child, orientation, size, &minimum, &natural, nil, nil)
        return (minimum, natural)
    }

    private static let measure: GtkCustomMeasureFunc = { row, orientation, _, minimum, natural, _, _ in
        nonisolated(unsafe) let row = row
        nonisolated(unsafe) let minimum = minimum
        nonisolated(unsafe) let natural = natural
        MainActor.assumeIsolated {
            let children = TableLayout.children(of: row)
            if orientation == GTK_ORIENTATION_VERTICAL {
                let sizes = children.map { TableLayout.natural(of: $0, orientation, for: -1) }
                minimum?.pointee = sizes.map(\.0).max() ?? 0
                natural?.pointee = sizes.map(\.1).max() ?? 0
                return
            }
            let layout = TableLayout.layout(of: row)
            let gaps = Int32(TableLayout.spacing * (children.count - 1))
            let actions = layout.actions.isEmpty ? 0 : TableLayout.natural(of: children.last!, orientation, for: -1).1
            minimum?.pointee = gaps + actions
            natural?.pointee = gaps + actions + Int32(layout.naturalWidths(measuringWith: children[0]).reduce(0, +))
        }
    }

    private static let allocate: GtkCustomAllocateFunc = { row, width, height, _ in
        nonisolated(unsafe) let row = row
        MainActor.assumeIsolated {
            let children = TableLayout.children(of: row)
            let layout = TableLayout.layout(of: row)
            let actions = layout.actions.isEmpty ? 0 : Double(TableLayout.natural(of: children.last!, GTK_ORIENTATION_HORIZONTAL, for: -1).1)
            let available = Double(width) - actions - Double(TableLayout.spacing * (children.count - 1))
            var widths = layout.fitted(to: available, measuringWith: children[0])
            if !layout.actions.isEmpty { widths.append(actions) }
            var x = 0.0
            for (child, childWidth) in zip(children, widths) {
                var origin = graphene_point_t(x: Float(x.rounded()), y: 0)
                gtk_widget_allocate(child, Int32(childWidth.rounded(.down)), height, -1, gsk_transform_translate(nil, &origin))
                x += childWidth + Double(TableLayout.spacing)
            }
        }
    }

    private func naturalWidths(measuringWith cell: UnsafeMutablePointer<GtkWidget>) -> [Double] {
        let advance = advance ?? Self.measureAdvance(cell)
        self.advance = advance
        return longest.map { (Double($0) * advance).rounded(.up) + 1 }
    }

    private func fitted(to available: Double, measuringWith cell: UnsafeMutablePointer<GtkWidget>) -> [Double] {
        let natural = naturalWidths(measuringWith: cell)
        let total = natural.reduce(0, +)
        guard total > 0 else { return natural }
        if total <= available {
            return natural.map { $0 + (available - total) * $0 / total }
        }
        var kept = 0.0
        var cap = available / Double(natural.count)
        for (index, width) in natural.sorted().enumerated() {
            let share = (available - kept) / Double(natural.count - index)
            guard width <= share else {
                cap = share
                break
            }
            kept += width
        }
        let floor = advance! * Self.minimumCharacters
        return natural.map { min($0, max(cap, floor)) }
    }

    private static func measureAdvance(_ cell: UnsafeMutablePointer<GtkWidget>) -> Double {
        let layout = gtk_widget_create_pango_layout(cell, "0")!
        defer { g_object_unref(layout) }
        var width: Int32 = 0
        pango_layout_get_size(layout, &width, nil)
        return Double(width) / Double(PANGO_SCALE)
    }

    private static func queueAllocate(rowsUnder widget: UnsafeMutablePointer<GtkWidget>?) {
        for child in children(of: widget) {
            if gtk_widget_has_css_class(child, "luma-table-row") != 0 || gtk_widget_has_css_class(child, "luma-table-header") != 0 {
                gtk_widget_queue_allocate(child)
            } else {
                queueAllocate(rowsUnder: child)
            }
        }
    }
}

@MainActor
private final class CounterView {
    let widget: Box
    private let unitFromConfig: String?
    private let valueRow: Box
    private let valueLabel: Label
    private let unitLabel: Label
    private let deltaLabel: Label
    private let emptyLabel: Label

    init(unit: String?, initial: WidgetCounterValue?) {
        self.unitFromConfig = unit

        widget = Box(orientation: .vertical, spacing: 0)

        valueRow = Box(orientation: .horizontal, spacing: 8)
        valueRow.valign = .center

        valueLabel = Label(str: "")
        valueLabel.add(cssClass: "luma-counter-value")
        valueLabel.halign = .start
        valueLabel.valign = .baselineFill
        valueRow.append(child: valueLabel)

        unitLabel = Label(str: unit ?? "")
        unitLabel.add(cssClass: "luma-counter-unit")
        unitLabel.add(cssClass: "dim-label")
        unitLabel.halign = .start
        unitLabel.valign = .baselineFill
        valueRow.append(child: unitLabel)

        deltaLabel = Label(str: "")
        deltaLabel.add(cssClass: "luma-counter-delta")
        deltaLabel.halign = .start
        deltaLabel.valign = .baselineFill
        valueRow.append(child: deltaLabel)

        emptyLabel = Label(str: "No data.")
        emptyLabel.add(cssClass: "dim-label")
        emptyLabel.add(cssClass: "luma-widget-empty")
        emptyLabel.halign = .start

        widget.append(child: valueRow)
        widget.append(child: emptyLabel)

        if let initial {
            set(value: initial)
        } else {
            showEmptyState()
        }
    }

    func set(value: WidgetCounterValue) {
        valueLabel.label = formatNumber(value.value)
        let resolvedUnit = value.unit ?? unitFromConfig
        unitLabel.label = resolvedUnit ?? ""
        unitLabel.visible = resolvedUnit != nil
        if let delta = value.delta {
            deltaLabel.label = formatDelta(delta)
            deltaLabel.remove(cssClass: delta >= 0 ? "error" : "success")
            deltaLabel.add(cssClass: delta >= 0 ? "success" : "error")
            deltaLabel.visible = true
        } else {
            deltaLabel.visible = false
        }
        valueRow.visible = true
        emptyLabel.visible = false
    }

    func clear() {
        showEmptyState()
    }

    func replace(value: WidgetCounterValue?) {
        if let value {
            set(value: value)
        } else {
            showEmptyState()
        }
    }

    private func showEmptyState() {
        valueRow.visible = false
        emptyLabel.visible = true
    }

    private func formatNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int64(value))
        }
        return String(format: "%.2f", value)
    }

    private func formatDelta(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(formatNumber(delta))"
    }
}

@MainActor
private final class HistogramView {
    let widget: Box
    private let drawingArea: DrawingArea
    private var buckets: [WidgetHistogramBucket]

    init(initial: [WidgetHistogramBucket]) {
        self.buckets = initial

        widget = Box(orientation: .vertical, spacing: 0)
        drawingArea = DrawingArea()
        drawingArea.hexpand = true
        drawingArea.vexpand = true
        drawingArea.contentHeight = 180
        widget.append(child: drawingArea)

        drawingArea.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated {
                self?.draw(ctx: ctx, width: Double(width), height: Double(height))
            }
        }
    }

    func setBuckets(_ buckets: [WidgetHistogramBucket]) {
        self.buckets = buckets
        drawingArea.queueDraw()
    }

    func increment(label: String, by: Double) {
        if let i = buckets.firstIndex(where: { $0.label == label }) {
            buckets[i].count += by
        } else {
            buckets.append(WidgetHistogramBucket(label: label, count: by))
        }
        drawingArea.queueDraw()
    }

    func clear() {
        buckets.removeAll()
        drawingArea.queueDraw()
    }

    func replace(buckets: [WidgetHistogramBucket]) {
        self.buckets = buckets
        drawingArea.queueDraw()
    }

    private func draw(ctx: Cairo.ContextRef, width: Double, height: Double) {
        guard let maxCount = buckets.map(\.count).max(), maxCount > 0 else { return }
        let yTicks = ChartFrame.ticks(upTo: maxCount, from: 0)
        let frame = ChartFrame(area: drawingArea, width: width, height: height, yTicks: yTicks)
        let slot = frame.plot.width / Double(buckets.count)
        frame.drawGrid(ctx, verticalAt: buckets.indices.map { frame.plot.minX + slot * Double($0) })

        let top = yTicks.last!
        let barWidth = slot * 0.7
        for (i, bucket) in buckets.enumerated() {
            let center = frame.plot.minX + slot * (Double(i) + 0.5)
            let h = frame.plot.height * bucket.count / top
            let color = ChartFrame.seriesColor(at: 0)
            ctx.setSource(red: color.0, green: color.1, blue: color.2, alpha: 1)
            ctx.rectangle(x: center - barWidth / 2, y: frame.plot.maxY - h, width: barWidth, height: h)
            ctx.fill()
            frame.drawText(ctx, bucket.label, x: center, y: frame.plot.maxY + 3, maxWidth: slot - 4, centered: true)
        }
    }
}

@MainActor
private final class HexWidgetView {
    let widget: Box
    private let engine: Engine
    private let instanceID: UUID
    private let widgetID: String
    private let decodeView: PatternDecodeView
    private let emptyLabel: Label

    init(initial: WidgetHexState?, engine: Engine, instance: LumaCore.InstrumentInstance, widgetID: String) {
        self.engine = engine
        instanceID = instance.id
        self.widgetID = widgetID
        decodeView = PatternDecodeView(
            engine: engine, sessionID: instance.sessionID, data: initial?.bytes ?? Data(), baseAddress: initial?.baseAddress,
            placements: engine.placements(forWidget: widgetID, of: instance.id), sizing: .fill
        ) { [weak engine] placements in
            engine?.setPlacements(placements, forWidget: widgetID, of: instance.id)
        }
        decodeView.widget.hexpand = true
        decodeView.widget.vexpand = true

        emptyLabel = Label(str: "No data.")
        emptyLabel.add(cssClass: "dim-label")
        emptyLabel.add(cssClass: "luma-widget-empty")
        emptyLabel.halign = .start

        widget = Box(orientation: .vertical, spacing: 0)
        widget.append(child: decodeView.widget)
        widget.append(child: emptyLabel)

        replace(state: initial)
        followPlacements()
    }

    func replace(state: WidgetHexState?) {
        if let state {
            set(state: state)
        } else {
            clear()
        }
    }

    func set(state: WidgetHexState) {
        decodeView.setData(state.bytes, baseAddress: state.baseAddress)
        decodeView.widget.visible = true
        emptyLabel.visible = false
    }

    func clear() {
        decodeView.widget.visible = false
        emptyLabel.visible = true
    }

    private func followPlacements() {
        let placements = withObservationTracking {
            engine.placements(forWidget: widgetID, of: instanceID)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followPlacements()
            }
        }
        decodeView.setPlacements(placements)
    }
}
