import Cairo
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
    private let instance: LumaCore.InstrumentInstance
    private var canvases: [WidgetCanvas] = []
    private var subscriber: Task<Void, Never>?
    private var live = false

    init(engine: Engine, instance: LumaCore.InstrumentInstance, widgets: [InstrumentWidget]) {
        self.engine = engine
        self.instance = instance

        widget = Box(orientation: .vertical, spacing: 12)
        widget.hexpand = true
        widget.marginTop = 8

        for definition in widgets {
            let snapshot = engine.widgetState(instanceID: instance.id, widget: definition.id)
            let canvas = WidgetCanvas(
                definition: definition,
                snapshot: snapshot,
                engine: engine,
                instance: instance,
                onAction: { [weak self] action, item in
                    self?.invoke(widget: definition.id, action: action, item: item)
                },
                onClear: { [weak self] in
                    self?.clear(widget: definition.id)
                },
                onConsoleSubmit: { [weak self] text in
                    self?.submitConsole(widget: definition.id, text: text)
                }
            )
            canvases.append(canvas)
            widget.append(child: canvas.widget)
        }

        startSubscriber()
    }

    deinit {
        subscriber?.cancel()
    }

    func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        for canvas in canvases {
            canvas.setLive(live)
        }
    }

    private func startSubscriber() {
        guard let engine else { return }
        let instanceID = instance.id
        subscriber = Task { @MainActor [weak self] in
            for await update in engine.widgetUpdates where update.instanceID == instanceID {
                self?.dispatch(update)
            }
        }
    }

    private func dispatch(_ update: WidgetUpdate) {
        for canvas in canvases where canvas.definition.id == update.widget {
            canvas.apply(update)
        }
    }

    private func invoke(widget: String, action: String, item: String?) {
        guard let engine else { return }
        let instance = self.instance
        Task { @MainActor in
            await engine.invokeWidgetAction(instance: instance, widget: widget, action: action, item: item)
        }
    }

    private func clear(widget: String) {
        engine?.clearWidget(instance: instance, widget: widget)
    }

    private func submitConsole(widget: String, text: String) {
        guard let engine else { return }
        let instance = self.instance
        Task { @MainActor in
            await engine.submitConsoleInput(instance: instance, widget: widget, text: text)
        }
    }
}

@MainActor
private final class WidgetCanvas {
    let definition: InstrumentWidget
    let widget: Box
    private let onAction: (_ action: String, _ item: String?) -> Void
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
        snapshot: WidgetState,
        engine: Engine,
        instance: LumaCore.InstrumentInstance,
        onAction: @escaping (_ action: String, _ item: String?) -> Void,
        onClear: @escaping () -> Void,
        onConsoleSubmit: @escaping (_ text: String) -> Void
    ) {
        self.definition = definition
        self.onAction = onAction

        widget = Box(orientation: .vertical, spacing: 4)
        widget.add(cssClass: "card")

        let column = Box(orientation: .vertical, spacing: 6)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12
        widget.append(child: column)

        let header = Box(orientation: .horizontal, spacing: 8)
        let title = Label(str: definition.name)
        title.add(cssClass: "heading")
        title.halign = .start
        title.hexpand = true
        header.append(child: title)
        let clearButton = Button()
        clearButton.add(cssClass: "flat")
        clearButton.set(iconName: "user-trash-symbolic")
        clearButton.tooltipText = "Clear"
        clearButton.onClicked { _ in
            MainActor.assumeIsolated { onClear() }
        }
        header.append(child: clearButton)
        column.append(child: header)

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
                ListItemPresenter(actions: cfg.actions, onAction: onAction)
            }
            listView = view
            column.append(child: view.widget)
        case .table(let cfg):
            let layout = TableLayout(columns: cfg.columns, actions: cfg.actions)
            let header = layout.makeHeader()
            let view = WidgetRowList(kind: definition.kind, initial: snapshot, rows: \.tableRows, header: header, emptyText: "No rows.") {
                TableRowPresenter(layout: layout, onAction: onAction)
            }
            tableView = view
            column.append(child: view.widget)
        case .hex:
            let view = HexWidgetView(initial: snapshot.hex, engine: engine, instance: instance, widgetID: definition.id)
            hexView = view
            column.append(child: view.widget)
        case .console(let cfg):
            let view = ConsoleWidget(
                config: cfg,
                initialEntries: snapshot.consoleEntries,
                widgetName: definition.name,
                engine: engine,
                sessionID: instance.sessionID,
                onSubmit: onConsoleSubmit
            )
            consoleWidget = view
            column.append(child: view.widget)
        case .view(let cfg):
            let view = InstrumentViewWidget(engine: engine, key: .init(instanceID: instance.id, widget: definition.id), config: cfg)
            viewWidget = view
            column.append(child: view.widget)
        }
    }

    func setLive(_ live: Bool) {
        consoleWidget?.setLive(live)
    }

    func apply(_ update: WidgetUpdate) {
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
            consoleWidget?.append(entry: entry)
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
private final class ConsoleWidget {
    let widget: Box
    private weak var engine: Engine?
    private let sessionID: UUID
    private let widgetName: String
    private let console: ConsoleView
    private let inputPlaceholder: String
    private var valueWidgetKeepers: [JSInspectValueWidget] = []

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
        let placeholder = config.placeholder ?? ""
        inputPlaceholder = placeholder
        let style = ConsoleView.Style(
            promptGlyph: config.prompt ?? "\u{203A}",
            placeholder: placeholder,
            runButtonLabel: config.runButtonLabel ?? "Run"
        )
        console = ConsoleView(style: style, emptyState: Self.makeEmptyState())
        console.onSubmit = onSubmit
        console.setInputEnabled(false, placeholder: "Session not attached.")
        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.setSizeRequest(width: -1, height: 280)
        widget.append(child: console.widget)

        var seededHistory: [String] = []
        for entry in initialEntries {
            console.appendEntry(makeRow(for: entry))
            if entry.kind == .input { seededHistory.append(entry.text) }
        }
        console.setHistory(seededHistory)
    }

    func setLive(_ live: Bool) {
        console.setInputEnabled(live, placeholder: live ? inputPlaceholder : "Session not attached.")
    }

    func append(entry: WidgetConsoleEntry) {
        console.appendEntry(makeRow(for: entry))
    }

    func clear() {
        console.clearEntries()
        console.setHistory([])
        valueWidgetKeepers.removeAll()
    }

    func replace(entries: [WidgetConsoleEntry]) {
        console.clearEntries()
        valueWidgetKeepers.removeAll()
        var history: [String] = []
        for entry in entries {
            console.appendEntry(makeRow(for: entry))
            if entry.kind == .input { history.append(entry.text) }
        }
        console.setHistory(history)
    }

    private func makeRow(for entry: WidgetConsoleEntry) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 8)
        let glyph: String
        let bodyCssClass: String?
        switch entry.kind {
        case .input:
            glyph = "\u{203A}"
            bodyCssClass = nil
        case .output:
            glyph = "\u{2190}"
            bodyCssClass = nil
        case .image:
            glyph = "\u{1F5BC}"
            bodyCssClass = nil
        case .error:
            glyph = "!"
            bodyCssClass = "error"
        }
        let glyphLabel = Label(str: glyph)
        glyphLabel.add(cssClass: "monospace")
        glyphLabel.add(cssClass: "dim-label")
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

        widget = Box(orientation: .vertical, spacing: 0)
        drawingArea = DrawingArea()
        drawingArea.hexpand = true
        drawingArea.contentHeight = 180
        widget.append(child: drawingArea)

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

    private func draw(ctx: Cairo.ContextRef, width: Double, height: Double) {
        let bounds = computeBounds()
        guard let bounds else {
            drawEmptyMessage(ctx: ctx, width: width, height: height)
            return
        }

        let inset: Double = 8
        let plotWidth = max(1.0, width - inset * 2)
        let plotHeight = max(1.0, height - inset * 2)

        ctx.setSource(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.6)
        ctx.lineWidth = 0.5
        ctx.moveTo(inset, inset)
        ctx.lineTo(inset, inset + plotHeight)
        ctx.lineTo(inset + plotWidth, inset + plotHeight)
        ctx.stroke()

        for (index, definition) in series.enumerated() {
            guard let line = points[definition.id], line.count >= 2 else { continue }
            let color = seriesColor(at: index)
            ctx.setSource(red: color.0, green: color.1, blue: color.2, alpha: 1.0)
            ctx.lineWidth = 1.5
            for (i, point) in line.enumerated() {
                let px = inset + plotWidth * normalize(point.x, in: bounds.x)
                let py = inset + plotHeight * (1 - normalize(point.y, in: bounds.y))
                if i == 0 {
                    ctx.moveTo(px, py)
                } else {
                    ctx.lineTo(px, py)
                }
            }
            ctx.stroke()
        }
    }

    private func drawEmptyMessage(ctx: Cairo.ContextRef, width: Double, height: Double) {
        ctx.setSource(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)
        "monospace".withCString { ctx.selectFontFace($0) }
        ctx.fontSize = 12
        let text = "Waiting for data\u{2026}"
        let extents = text.withCString { ctx.textExtents($0) }
        ctx.moveTo((width - extents.width) / 2, (height + extents.height) / 2)
        text.withCString { ctx.showText($0) }
    }

    private func computeBounds() -> (x: ClosedRange<Double>, y: ClosedRange<Double>)? {
        var xMin = Double.infinity
        var xMax = -Double.infinity
        var yMin = Double.infinity
        var yMax = -Double.infinity
        var count = 0
        for line in points.values {
            for point in line {
                xMin = min(xMin, point.x)
                xMax = max(xMax, point.x)
                yMin = min(yMin, point.y)
                yMax = max(yMax, point.y)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        if xMin == xMax { xMax = xMin + 1 }
        if yMin == yMax { yMax = yMin + 1 }
        return (xMin...xMax, yMin...yMax)
    }

    private func normalize(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    private func seriesColor(at index: Int) -> (Double, Double, Double) {
        let palette: [(Double, Double, Double)] = [
            (0.20, 0.55, 0.92),
            (0.92, 0.42, 0.20),
            (0.30, 0.78, 0.42),
            (0.78, 0.30, 0.78),
            (0.92, 0.78, 0.20),
        ]
        return palette[index % palette.count]
    }
}

@MainActor
private protocol WidgetRowPresenter: AnyObject {
    associatedtype Row: Identifiable & Equatable

    var widget: Box { get }

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
    private var state: WidgetState
    private var shownRows: [Presenter.Row] = []
    private var presenters: [UnsafeMutableRawPointer: Presenter] = [:]
    private var refresh = Refresh.idle

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
        scroller.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroller.propagateNaturalHeight = true
        scroller.maxContentHeight = Self.maxHeight
        scroller.set(child: list)
        widget.append(child: scroller)

        emptyLabel = Label(str: emptyText)
        emptyLabel.add(cssClass: "dim-label")
        emptyLabel.halign = .start
        emptyLabel.marginStart = 8
        emptyLabel.marginEnd = 8
        emptyLabel.marginTop = 6
        emptyLabel.marginBottom = 6
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

        scroller.visible = !rows.isEmpty
        emptyLabel.visible = rows.isEmpty
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

    init(actions: [InstrumentWidget.Action], onAction: @escaping (_ action: String, _ item: String?) -> Void) {
        widget = Box(orientation: .horizontal, spacing: 8)
        widget.marginStart = 8
        widget.marginEnd = 8
        widget.marginTop = 6
        widget.marginBottom = 6

        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        title = Label(str: "")
        title.halign = .start
        column.append(child: title)
        subtitle = Label(str: "")
        subtitle.add(cssClass: "caption")
        subtitle.add(cssClass: "dim-label")
        subtitle.halign = .start
        column.append(child: subtitle)
        widget.append(child: column)

        accessory = Label(str: "")
        accessory.add(cssClass: "caption")
        accessory.add(cssClass: "dim-label")
        widget.append(child: accessory)

        for action in actions {
            let button = Button(label: action.name)
            button.add(cssClass: "flat")
            let actionID = action.id
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    onAction(actionID, self.itemID)
                }
            }
            widget.append(child: button)
        }
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

    init(layout: TableLayout, onAction: @escaping (_ action: String, _ item: String?) -> Void) {
        self.layout = layout
        widget = layout.makeRow(verticalMargin: 4)

        cells = layout.columns.map { layout.makeCell(for: $0, text: "") }
        for cell in cells {
            widget.append(child: cell)
        }

        guard !layout.actions.isEmpty else { return }
        let buttons = layout.makeActionsBox()
        for action in layout.actions {
            let button = Button(label: action.name)
            button.add(cssClass: "flat")
            let actionID = action.id
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    onAction(actionID, self.rowID)
                }
            }
            buttons.append(child: button)
        }
        widget.append(child: buttons)
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

    init(columns: [InstrumentWidget.Column], actions: [InstrumentWidget.Action]) {
        self.columns = columns
        self.actions = actions
    }

    func makeHeader() -> Box {
        let header = makeRow(verticalMargin: 6)
        for column in columns {
            let label = makeCell(for: column, text: column.name)
            label.add(cssClass: "caption")
            label.add(cssClass: "dim-label")
            header.append(child: label)
        }
        if !actions.isEmpty {
            header.append(child: makeActionsBox())
        }
        return header
    }

    func makeRow(verticalMargin: Int) -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.marginStart = 8
        row.marginEnd = 8
        row.marginTop = verticalMargin
        row.marginBottom = verticalMargin
        return row
    }

    func makeCell(for column: InstrumentWidget.Column, text: String) -> Label {
        let label = Label(str: text)
        label.hexpand = true
        label.xalign = column.alignment == .leading ? 0 : 1
        label.ellipsize = EllipsizeMode.end
        label.maxWidthChars = 1
        return label
    }

    func makeActionsBox() -> Box {
        let box = Box(orientation: .horizontal, spacing: 4)
        actionsWidth.add(widget: box)
        return box
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
        valueLabel.add(cssClass: "title-1")
        valueLabel.halign = .start
        valueRow.append(child: valueLabel)

        unitLabel = Label(str: unit ?? "")
        unitLabel.add(cssClass: "dim-label")
        unitLabel.halign = .start
        valueRow.append(child: unitLabel)

        deltaLabel = Label(str: "")
        deltaLabel.add(cssClass: "caption")
        deltaLabel.halign = .start
        valueRow.append(child: deltaLabel)

        emptyLabel = Label(str: "No data.")
        emptyLabel.add(cssClass: "dim-label")
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
        guard !buckets.isEmpty, let maxCount = buckets.map(\.count).max(), maxCount > 0 else { return }
        let inset: Double = 12
        let plotWidth = max(1.0, width - inset * 2)
        let plotHeight = max(1.0, height - inset * 2)
        let barCount = Double(buckets.count)
        let gap: Double = 4
        let barWidth = max(1.0, (plotWidth - gap * (barCount - 1)) / barCount)

        ctx.setSource(red: 0.20, green: 0.55, blue: 0.92, alpha: 0.85)
        for (i, bucket) in buckets.enumerated() {
            let h = plotHeight * (bucket.count / maxCount)
            let x = inset + Double(i) * (barWidth + gap)
            let y = inset + plotHeight - h
            ctx.rectangle(x: x, y: y, width: barWidth, height: h)
            ctx.fill()
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
            placements: engine.placements(forWidget: widgetID, of: instance.id), sizing: .capped
        ) { [weak engine] placements in
            engine?.setPlacements(placements, forWidget: widgetID, of: instance.id)
        }
        decodeView.widget.hexpand = true

        emptyLabel = Label(str: "No data.")
        emptyLabel.add(cssClass: "dim-label")
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
