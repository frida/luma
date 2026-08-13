import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
final class PharoChartArea {
    let widget: Box
    var onDrill: ((Int) -> Void)?

    private let chart: PharoChart
    private let area: DrawingArea
    private var selected: Int?
    private var hovered: Int?
    private var centers: [(x: Double, y: Double)?] = []
    private var zoom = 1.0
    private var panX = 0.0
    private var panY = 0.0
    private var needsFit = true
    private var mouse = (x: 0.0, y: 0.0)
    private var dragged = (x: 0.0, y: 0.0)
    private var pinchBase = 1.0
    private var themeToken: gulong = 0

    private let canvasWidth = 720.0
    private let canvasHeight = 440.0

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeToken)
    }

    init(chart: PharoChart) {
        self.chart = chart

        area = DrawingArea()
        area.hexpand = true
        area.vexpand = true
        area.focusable = true
        area.canFocus = true

        let controls = Box(orientation: .horizontal, spacing: 0)
        controls.add(cssClass: "linked")
        controls.add(cssClass: "osd")
        controls.halign = .end
        controls.valign = .end
        controls.marginEnd = 10
        controls.marginBottom = 10

        let overlay = Overlay()
        overlay.hexpand = true
        overlay.vexpand = true
        overlay.set(child: area)
        overlay.addOverlay(widget: controls)

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true
        widget.append(child: overlay)

        controls.append(child: zoomButton("zoom-out-symbolic", "Zoom out") { [weak self] in self?.zoomAroundCenter(0.8) })
        controls.append(child: zoomButton("zoom-fit-best-symbolic", "Fit") { [weak self] in self?.fit(); self?.area.queueDraw() })
        controls.append(child: zoomButton("zoom-in-symbolic", "Zoom in") { [weak self] in self?.zoomAroundCenter(1.25) })

        area.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated { self?.draw(ctx, Double(width), Double(height)) }
        }
        gtk_widget_set_cursor_from_name(area.widget_ptr, "pointer")
        installGestures()
        themeToken = ThemeWatcher.subscribe(owner: self) { $0.area.queueDraw() }
    }

    private func zoomButton(_ icon: String, _ tip: String, _ action: @escaping () -> Void) -> Button {
        let button = Button(iconName: icon)
        button.tooltipText = tip
        button.onClicked { _ in MainActor.assumeIsolated { action() } }
        return button
    }

    private func installGestures() {
        let click = GestureClick()
        click.onPressed { [weak self] _, count, x, y in
            MainActor.assumeIsolated { self?.press(x, y, count: count) }
        }
        area.install(controller: click)

        let secondary = GestureClick()
        secondary.button = Int(GDK_BUTTON_SECONDARY)
        secondary.propagationPhase = .capture
        secondary.onPressed { [weak self] gesture, _, x, y in
            MainActor.assumeIsolated {
                _ = gesture.set(state: .claimed)
                self?.presentCopyMenu(x, y)
            }
        }
        area.install(controller: secondary)

        let keys = EventControllerKey()
        keys.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated { self?.handleKey(keyval) ?? false }
        }
        area.install(controller: keys)

        let drag = GestureDrag()
        drag.onDragBegin { [weak self] _, _, _ in
            MainActor.assumeIsolated { self?.dragged = (0, 0) }
        }
        drag.onDragUpdate { [weak self] _, offsetX, offsetY in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panX += offsetX - self.dragged.x
                self.panY += offsetY - self.dragged.y
                self.dragged = (offsetX, offsetY)
                self.area.queueDraw()
            }
        }
        area.install(controller: drag)

        let motion = EventControllerMotion()
        motion.onMotion { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouse = (x, y)
                self.setHovered(self.point(atScreen: x, y))
            }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.setHovered(nil) }
        }
        area.install(controller: motion)

        let scroll = EventControllerScroll(flags: .bothAxes)
        scroll.onScroll { [weak self] controller, dx, dy in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if controller.currentEventState.contains(.controlMask) {
                    self.zoomAround(self.mouse.x, self.mouse.y, factor: 1.0 - dy * 0.1)
                } else {
                    let multiplier = controller.unit == .wheel ? 30.0 : 1.0
                    self.panX -= dx * multiplier
                    self.panY -= dy * multiplier
                    self.area.queueDraw()
                }
                return true
            }
        }
        area.install(controller: scroll)

        let pinch = GestureZoom()
        pinch.onBegin { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pinchBase = 1.0 }
        }
        pinch.onScaleChanged { [weak self] _, scale in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.zoomAround(self.mouse.x, self.mouse.y, factor: scale / self.pinchBase)
                self.pinchBase = scale
            }
        }
        area.install(controller: pinch)
    }

    private func press(_ x: Double, _ y: Double, count: Int) {
        _ = area.grabFocus()
        guard let index = point(atScreen: x, y) else { return }
        if count >= 2 {
            onDrill?(index)
        } else if selected != index {
            selected = index
            area.queueDraw()
        }
    }

    private func setHovered(_ index: Int?) {
        guard hovered != index else { return }
        hovered = index
        area.queueDraw()
    }

    private func handleKey(_ keyval: UInt) -> Bool {
        switch Int32(keyval) {
        case Gdk.keyLeft, Gdk.keyUp:
            move(-1)
            return true
        case Gdk.keyRight, Gdk.keyDown:
            move(1)
            return true
        case Gdk.keyReturn, Gdk.keyKPEnter, Gdk.keyISOEnter:
            if let selected { onDrill?(selected) }
            return true
        case Gdk.keyEscape:
            selected = nil
            area.queueDraw()
            return true
        default:
            return false
        }
    }

    private func move(_ delta: Int) {
        let count = flatCount
        guard count > 0 else { return }
        if let selected {
            self.selected = min(max(selected + delta, 0), count - 1)
        } else {
            selected = delta > 0 ? 0 : count - 1
        }
        area.queueDraw()
    }

    private func presentCopyMenu(_ x: Double, _ y: Double) {
        guard let index = selected ?? point(atScreen: x, y) else { return }
        selected = index
        area.queueDraw()
        let value = readout(index)
        ContextMenu.present(
            [[ContextMenu.Item("Copy Value") { Self.copyToClipboard(value) }]], at: area, x: x, y: y)
    }

    private static func copyToClipboard(_ value: String) {
        guard let display = Display.getDefault() else { return }
        display.clipboard.set(text: value)
    }

    private func point(atScreen x: Double, _ y: Double) -> Int? {
        let worldX = (x - panX) / zoom
        let worldY = (y - panY) / zoom
        var best: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            guard let center else { continue }
            let distance = hypot(center.x - worldX, center.y - worldY)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func readout(_ flat: Int) -> String {
        guard let at = locate(flat) else { return "" }
        let point = chart.series[at.series].points[at.point]
        return chart.series[at.series].kind == "bar"
            ? "\(point.label): \(formatted(point.y))"
            : "\(formatted(point.x)), \(formatted(point.y))"
    }

    private func locate(_ flat: Int) -> (series: Int, point: Int)? {
        var base = 0
        for (series, points) in chart.series.enumerated() {
            if flat < base + points.points.count {
                return (series, flat - base)
            }
            base += points.points.count
        }
        return nil
    }

    private func flatIndex(series: Int, point: Int) -> Int {
        chart.series.prefix(series).reduce(0) { $0 + $1.points.count } + point
    }

    private var flatCount: Int {
        chart.series.reduce(0) { $0 + $1.points.count }
    }

    private func zoomAroundCenter(_ factor: Double) {
        zoomAround(Double(area.width) / 2, Double(area.height) / 2, factor: factor)
    }

    private func zoomAround(_ screenX: Double, _ screenY: Double, factor: Double) {
        let target = max(0.2, min(6.0, zoom * factor))
        let worldX = (screenX - panX) / zoom
        let worldY = (screenY - panY) / zoom
        zoom = target
        panX = screenX - worldX * zoom
        panY = screenY - worldY * zoom
        area.queueDraw()
    }

    private func fit() {
        let viewW = Double(area.width)
        let viewH = Double(area.height)
        guard viewW > 0, viewH > 0 else { return }
        zoom = min(viewW / canvasWidth, viewH / canvasHeight)
        panX = (viewW - canvasWidth * zoom) / 2
        panY = (viewH - canvasHeight * zoom) / 2
    }

    private func draw(_ ctx: Cairo.ContextRef, _ width: Double, _ height: Double) {
        if needsFit {
            fit()
            needsFit = false
        }
        cairo_save(ctx.context_ptr)
        cairo_translate(ctx.context_ptr, panX, panY)
        cairo_scale(ctx.context_ptr, zoom, zoom)
        drawChart(ctx)
        cairo_restore(ctx.context_ptr)

        drawSelection(ctx)
        drawReadout(ctx)
    }

    private func screenPosition(of flat: Int) -> (x: Double, y: Double)? {
        guard flat >= 0, flat < centers.count, let center = centers[flat] else { return nil }
        return (panX + center.x * zoom, panY + center.y * zoom)
    }

    private func drawSelection(_ ctx: Cairo.ContextRef) {
        guard let selected, let at = screenPosition(of: selected) else { return }
        let palette = PharoVizColors.current
        setSource(ctx, palette.nodeFill)
        cairo_new_sub_path(ctx.context_ptr)
        cairo_arc(ctx.context_ptr, at.x, at.y, 7, 0, 2 * .pi)
        ctx.fill()
        setSource(ctx, PharoVizColors.brand)
        cairo_new_sub_path(ctx.context_ptr)
        cairo_arc(ctx.context_ptr, at.x, at.y, 5, 0, 2 * .pi)
        ctx.fill()
    }

    private func drawReadout(_ ctx: Cairo.ContextRef) {
        guard let hovered, let at = screenPosition(of: hovered) else { return }
        let palette = PharoVizColors.current
        PharoVisualArea.setFont(ctx, size: 11)
        readout(hovered).withCString { cString in
            let extents = ctx.textExtents(cString)
            let padding = 5.0
            let boxWidth = extents.width + padding * 2
            let boxHeight = extents.height + padding * 2
            let boxX = at.x - boxWidth / 2
            let boxY = at.y - 16 - boxHeight
            setSource(ctx, palette.nodeFill)
            ctx.rectangle(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
            ctx.fill()
            setSource(ctx, palette.border)
            ctx.lineWidth = 1
            ctx.rectangle(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
            ctx.stroke()
            setSource(ctx, palette.label)
            ctx.moveTo(boxX + padding, boxY + padding + extents.height)
            ctx.showText(cString)
        }
    }

    private func setSource(_ ctx: Cairo.ContextRef, _ c: PharoVizColors.RGBA) {
        ctx.setSource(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    private func drawChart(_ ctx: Cairo.ContextRef) {
        let palette = PharoVizColors.current
        PharoVisualArea.setFont(ctx, size: 11)

        centers = Array(repeating: nil, count: flatCount)
        let points = chart.series.flatMap(\.points)
        guard !points.isEmpty else { return }

        let left = 58.0
        let top = 22.0
        let right = canvasWidth - 22
        let bottom = canvasHeight - 52
        guard right > left, bottom > top else { return }

        if chart.series.contains(where: { $0.kind == "bar" }) {
            drawBars(ctx, left: left, top: top, right: right, bottom: bottom, palette: palette)
        } else {
            drawXY(ctx, left: left, top: top, right: right, bottom: bottom, palette: palette)
        }

        setSource(ctx, palette.label)
        if !chart.titleX.isEmpty {
            text(ctx, chart.titleX, x: (left + right) / 2, y: canvasHeight - 14, align: .center)
        }
        if !chart.titleY.isEmpty {
            cairo_save(ctx.context_ptr)
            cairo_translate(ctx.context_ptr, 16, (top + bottom) / 2)
            cairo_rotate(ctx.context_ptr, -.pi / 2)
            text(ctx, chart.titleY, x: 0, y: 0, align: .center)
            cairo_restore(ctx.context_ptr)
        }
    }

    private func drawBars(
        _ ctx: Cairo.ContextRef, left: Double, top: Double, right: Double, bottom: Double, palette: PharoVizColors.Palette
    ) {
        let plotW = right - left
        let plotH = bottom - top
        let categories = chart.series.map(\.points.count).max() ?? 0
        guard categories > 0 else { return }
        let highest = max(chart.series.flatMap { $0.points.map(\.y) }.max() ?? 1, 0.000001)
        let showsValues = chart.series.reduce(0) { $0 + $1.points.count } <= 40

        drawYAxis(ctx, low: 0, high: highest, left: left, top: top, right: right, bottom: bottom, palette: palette)

        let groupWidth = plotW / Double(categories)
        let padding = groupWidth * 0.18
        let barWidth = (groupWidth - padding) / Double(chart.series.count)

        for category in 0..<categories {
            for (index, series) in chart.series.enumerated() where category < series.points.count {
                let point = series.points[category]
                let color = PharoVizColors.series[index % PharoVizColors.series.count]
                let barX = left + Double(category) * groupWidth + padding / 2 + Double(index) * barWidth
                let barH = point.y / highest * plotH
                let barY = bottom - barH
                centers[flatIndex(series: index, point: category)] = (barX + barWidth / 2, barY)
                setSource(ctx, color)
                ctx.rectangle(x: barX + 1, y: barY, width: barWidth - 2, height: barH)
                ctx.fill()
                if showsValues {
                    setSource(ctx, palette.label)
                    text(ctx, formatted(point.y), x: barX + barWidth / 2, y: barY - 4, align: .center)
                }
            }
            if let label = chart.series.first?.points[safe: category]?.label, !label.isEmpty {
                setSource(ctx, palette.label)
                let fitted = PharoVisualArea.fit(label, into: groupWidth - 4, ctx: ctx)
                text(ctx, fitted, x: left + (Double(category) + 0.5) * groupWidth, y: bottom + 14, align: .center)
            }
        }
    }

    private func drawXY(
        _ ctx: Cairo.ContextRef, left: Double, top: Double, right: Double, bottom: Double, palette: PharoVizColors.Palette
    ) {
        let plotW = right - left
        let plotH = bottom - top
        let logX = chart.scaleX == "logarithmic"
        let logY = chart.scaleY == "logarithmic"
        let points = chart.series.flatMap(\.points)
        let xs = Bounds(points.map(\.x), log: logX)
        let ys = Bounds(points.map(\.y), log: logY)

        drawYAxis(ctx, low: ys.low, high: ys.high, left: left, top: top, right: right, bottom: bottom, palette: palette, log: logY)

        setSource(ctx, palette.label)
        text(ctx, formatted(xs.rawLow), x: left, y: bottom + 14, align: .center)
        text(ctx, formatted(xs.rawHigh), x: right, y: bottom + 14, align: .center)

        for (index, series) in chart.series.enumerated() {
            let color = PharoVizColors.series[index % PharoVizColors.series.count]
            let placed = series.points.map { point -> (x: Double, y: Double) in
                (left + xs.fraction(point.x, log: logX) * plotW,
                 bottom - ys.fraction(point.y, log: logY) * plotH)
            }
            for (pointIndex, at) in placed.enumerated() {
                centers[flatIndex(series: index, point: pointIndex)] = at
            }
            setSource(ctx, color)
            if series.kind == "line" {
                ctx.lineWidth = 2
                for (i, at) in placed.enumerated() {
                    if i == 0 { ctx.moveTo(at.x, at.y) } else { ctx.lineTo(at.x, at.y) }
                }
                ctx.stroke()
            }
            for at in placed {
                cairo_new_sub_path(ctx.context_ptr)
                cairo_arc(ctx.context_ptr, at.x, at.y, 2.6, 0, 2 * .pi)
                ctx.fill()
            }
        }
    }

    private func drawYAxis(
        _ ctx: Cairo.ContextRef, low: Double, high: Double,
        left: Double, top: Double, right: Double, bottom: Double,
        palette: PharoVizColors.Palette, log: Bool = false
    ) {
        let ticks = 4
        for tick in 0...ticks {
            let fraction = Double(tick) / Double(ticks)
            let y = bottom - fraction * (bottom - top)
            setSource(ctx, palette.grid)
            ctx.lineWidth = 1
            ctx.moveTo(left, y)
            ctx.lineTo(right, y)
            ctx.stroke()
            let value = log ? pow(10, low + fraction * (high - low)) : low + fraction * (high - low)
            setSource(ctx, palette.label)
            text(ctx, formatted(value), x: left - 6, y: y + 3, align: .trailing)
        }
        setSource(ctx, palette.axis)
        ctx.lineWidth = 1
        ctx.moveTo(left, top)
        ctx.lineTo(left, bottom)
        ctx.lineTo(right, bottom)
        ctx.stroke()
    }

    private enum Align { case leading, center, trailing }

    private func text(_ ctx: Cairo.ContextRef, _ string: String, x: Double, y: Double, align: Align) {
        string.withCString { cString in
            let extents = ctx.textExtents(cString)
            let originX: Double
            switch align {
            case .leading: originX = x
            case .center: originX = x - extents.width / 2
            case .trailing: originX = x - extents.width
            }
            ctx.moveTo(originX, y)
            ctx.showText(cString)
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private struct Bounds {
        let low, high, rawLow, rawHigh: Double
        init(_ values: [Double], log: Bool) {
            let lowest = values.min() ?? 0
            let highest = values.max() ?? 1
            rawLow = lowest
            rawHigh = highest > lowest ? highest : lowest + 1
            let mapped = log ? [rawLow, rawHigh].map { Foundation.log10(max($0, 1e-9)) } : [rawLow, rawHigh]
            low = mapped[0]
            high = mapped[1] > mapped[0] ? mapped[1] : mapped[0] + 1
        }
        func fraction(_ value: Double, log: Bool) -> Double {
            let mapped = log ? Foundation.log10(max(value, 1e-9)) : value
            return (mapped - low) / (high - low)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
