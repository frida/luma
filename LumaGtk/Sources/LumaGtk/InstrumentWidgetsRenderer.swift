import Cairo
import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class InstrumentWidgetsRenderer {
    let widget: Box

    private weak var engine: Engine?
    private let instance: LumaCore.InstrumentInstance
    private var canvases: [WidgetCanvas] = []
    private var subscriber: Task<Void, Never>?

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
                onAction: { [weak self] action, item in
                    self?.invoke(widget: definition.id, action: action, item: item)
                },
                onClear: { [weak self] in
                    self?.clear(widget: definition.id)
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
}

@MainActor
private final class WidgetCanvas {
    let definition: InstrumentWidget
    let widget: Box
    private let onAction: (_ action: String, _ item: String?) -> Void
    private var graphView: GraphView?
    private var listView: ListView?

    init(
        definition: InstrumentWidget,
        snapshot: WidgetState,
        onAction: @escaping (_ action: String, _ item: String?) -> Void,
        onClear: @escaping () -> Void
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
        case .graph(let cfg):
            let view = GraphView(series: cfg.series, initialSeries: snapshot.graphSeries)
            graphView = view
            column.append(child: view.widget)
        case .list(let cfg):
            let view = ListView(actions: cfg.actions, initialItems: snapshot.listItems, onAction: onAction)
            listView = view
            column.append(child: view.widget)
        }
    }

    func apply(_ update: WidgetUpdate) {
        switch update.kind {
        case .graphPoint(let point):
            graphView?.append(point: point)
        case .listUpsert(let item):
            listView?.upsert(item: item)
        case .listRemove(let id):
            listView?.remove(itemID: id)
        case .clear:
            graphView?.clear()
            listView?.clear()
        }
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
        "monospace".withCString { p in
            ctx.selectFontFace(p, slant: CAIRO_FONT_SLANT_NORMAL, weight: CAIRO_FONT_WEIGHT_NORMAL)
        }
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
private final class ListView {
    let widget: Box
    private let listBox: Gtk.ListBox
    private let actions: [InstrumentWidget.Action]
    private let onAction: (_ action: String, _ item: String?) -> Void
    private let emptyLabel: Label
    private var rowsByItemID: [String: ListBoxRow] = [:]
    private var orderedItemIDs: [String] = []

    init(actions: [InstrumentWidget.Action], initialItems: [WidgetListItem], onAction: @escaping (_ action: String, _ item: String?) -> Void) {
        self.actions = actions
        self.onAction = onAction

        widget = Box(orientation: .vertical, spacing: 0)
        listBox = Gtk.ListBox()
        listBox.selectionMode = .none
        listBox.hexpand = true
        listBox.add(cssClass: "boxed-list")

        emptyLabel = Label(str: "No items.")
        emptyLabel.add(cssClass: "dim-label")
        emptyLabel.halign = .start

        widget.append(child: emptyLabel)
        widget.append(child: listBox)
        listBox.visible = false

        for item in initialItems {
            upsert(item: item)
        }
    }

    func upsert(item: WidgetListItem) {
        if let existing = rowsByItemID[item.id] {
            existing.set(child: makeRowContent(item: item))
        } else {
            let row = ListBoxRow()
            row.set(child: makeRowContent(item: item))
            rowsByItemID[item.id] = row
            orderedItemIDs.append(item.id)
            listBox.append(child: row)
        }
        refreshVisibility()
    }

    func remove(itemID: String) {
        guard let row = rowsByItemID.removeValue(forKey: itemID) else { return }
        orderedItemIDs.removeAll { $0 == itemID }
        listBox.remove(child: row)
        refreshVisibility()
    }

    func clear() {
        for id in orderedItemIDs {
            if let row = rowsByItemID[id] { listBox.remove(child: row) }
        }
        rowsByItemID.removeAll()
        orderedItemIDs.removeAll()
        refreshVisibility()
    }

    private func refreshVisibility() {
        let isEmpty = orderedItemIDs.isEmpty
        listBox.visible = !isEmpty
        emptyLabel.visible = isEmpty
    }

    private func makeRowContent(item: WidgetListItem) -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.marginStart = 8
        row.marginEnd = 8
        row.marginTop = 6
        row.marginBottom = 6

        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        let title = Label(str: item.title)
        title.halign = .start
        column.append(child: title)
        if let subtitle = item.subtitle {
            let sub = Label(str: subtitle)
            sub.add(cssClass: "caption")
            sub.add(cssClass: "dim-label")
            sub.halign = .start
            column.append(child: sub)
        }
        row.append(child: column)

        if let accessory = item.accessory {
            let acc = Label(str: accessory)
            acc.add(cssClass: "caption")
            acc.add(cssClass: "dim-label")
            row.append(child: acc)
        }

        let itemID = item.id
        for action in actions {
            let button = Button(label: action.name)
            button.add(cssClass: "flat")
            let actionID = action.id
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.onAction(actionID, itemID) }
            }
            row.append(child: button)
        }

        return row
    }
}
