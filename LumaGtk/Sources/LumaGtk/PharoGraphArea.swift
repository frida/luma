import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk
import LumaCore
import SwiftyPharo

/// A `mondrian` graph the reader can walk and roam: single-click a node to
/// select it and its edges, double-click to drill; arrow keys step to the
/// neighbour in a direction, Return drills, Escape lets go. Drag to pan,
/// Ctrl+scroll or pinch to zoom about the pointer, and the buttons zoom in and
/// out or fit the whole graph. Mirrors the SwiftUI graph over the shared
/// layout.
@MainActor
final class PharoGraphArea {
    let widget: Box
    var onDrill: ((Int) -> Void)?

    private let graph: PharoGraph
    private let solution: PharoGraphLayout.Solution
    private let area: DrawingArea
    private var selected: Int?
    private var hovered: Int?

    private var zoom = 1.0
    private var panX = 0.0
    private var panY = 0.0
    private var needsFit = true
    private var mouse = (x: 0.0, y: 0.0)
    private var dragged = (x: 0.0, y: 0.0)
    private var pinchBase = 1.0
    private var themeToken: gulong = 0

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeToken)
    }

    private func setSource(_ ctx: Cairo.ContextRef, _ c: PharoVizColors.RGBA) {
        ctx.setSource(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    init(graph: PharoGraph) {
        self.graph = graph
        solution = PharoGraphLayout(
            nodeCount: graph.nodes.count,
            edges: graph.edges.map { .init(from: $0.from, to: $0.to) },
            kind: .init(graph.layout)
        ).solve()

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

        let motion = EventControllerMotion()
        motion.onMotion { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouse = (x, y)
                self.setHovered(self.node(atScreen: x, y))
            }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.setHovered(nil) }
        }
        area.install(controller: motion)

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

        let keys = EventControllerKey()
        keys.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated { self?.handleKey(keyval) ?? false }
        }
        area.install(controller: keys)
    }

    private func press(_ x: Double, _ y: Double, count: Int) {
        _ = area.grabFocus()
        guard let index = node(atScreen: x, y) else { return }
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

    private func presentCopyMenu(_ x: Double, _ y: Double) {
        guard let index = node(atScreen: x, y) ?? selected, index < graph.nodes.count else { return }
        selected = index
        area.queueDraw()
        let label = graph.nodes[index].label
        ContextMenu.present(
            [[ContextMenu.Item("Copy Label") { Self.copyToClipboard(label) }]], at: area, x: x, y: y)
    }

    private static func copyToClipboard(_ value: String) {
        guard let display = Display.getDefault() else { return }
        display.clipboard.set(text: value)
    }

    private func handleKey(_ keyval: UInt) -> Bool {
        switch Int32(keyval) {
        case Gdk.keyUp:
            move(0, -1)
            return true
        case Gdk.keyDown:
            move(0, 1)
            return true
        case Gdk.keyLeft:
            move(-1, 0)
            return true
        case Gdk.keyRight:
            move(1, 0)
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

    private func move(_ dx: Double, _ dy: Double) {
        guard let from = selected else {
            selected = solution.points.isEmpty ? nil : 0
            area.queueDraw()
            return
        }
        if let next = neighbor(of: from, dx: dx, dy: dy) {
            selected = next
            area.queueDraw()
        }
    }

    private func neighbor(of index: Int, dx: Double, dy: Double) -> Int? {
        let from = solution[index]
        var best: Int?
        var bestScore = Double.greatestFiniteMagnitude
        for other in solution.points.indices where other != index {
            let vx = solution[other].x - from.x
            let vy = solution[other].y - from.y
            let along = vx * dx + vy * dy
            guard along > 0 else { continue }
            let across = abs(vx * dy - vy * dx)
            let score = along + across * 2
            if score < bestScore {
                bestScore = score
                best = other
            }
        }
        return best
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
        let contentW = solution.width + 2 * PharoVisualArea.margin
        let contentH = solution.height + 2 * PharoVisualArea.margin
        guard viewW > 0, viewH > 0, contentW > 0, contentH > 0 else { return }
        zoom = min(viewW / contentW, viewH / contentH, 1.0)
        panX = (viewW - contentW * zoom) / 2
        panY = (viewH - contentH * zoom) / 2
    }

    private func node(atScreen x: Double, _ y: Double) -> Int? {
        node(atWorld: (x - panX) / zoom, (y - panY) / zoom)
    }

    private func node(atWorld x: Double, _ y: Double) -> Int? {
        let nodeWidth = PharoGraphLayout.nodeWidth
        let nodeHeight = PharoGraphLayout.nodeHeight
        let m = PharoVisualArea.margin
        for index in solution.points.indices {
            let center = solution[index]
            let left = center.x + m - nodeWidth / 2
            let top = center.y + m - nodeHeight / 2
            if x >= left, x <= left + nodeWidth, y >= top, y <= top + nodeHeight {
                return index
            }
        }
        return nil
    }

    private func draw(_ ctx: Cairo.ContextRef, _ width: Double, _ height: Double) {
        if needsFit {
            fit()
            needsFit = false
        }

        cairo_save(ctx.context_ptr)
        cairo_translate(ctx.context_ptr, panX, panY)
        cairo_scale(ctx.context_ptr, zoom, zoom)

        let nodeWidth = PharoGraphLayout.nodeWidth
        let nodeHeight = PharoGraphLayout.nodeHeight
        let m = PharoVisualArea.margin
        let palette = PharoVizColors.current
        let brand = PharoVizColors.brand
        PharoVisualArea.setFont(ctx, size: 12)

        for edge in graph.edges where edge.from < solution.points.count && edge.to < solution.points.count {
            if edge.from == selected || edge.to == selected {
                setSource(ctx, brand)
                ctx.lineWidth = 2
            } else {
                setSource(ctx, palette.edge)
                ctx.lineWidth = 1
            }
            let a = solution[edge.from]
            let b = solution[edge.to]
            ctx.moveTo(a.x + m, a.y + m)
            ctx.lineTo(b.x + m, b.y + m)
            ctx.stroke()
        }

        for (index, node) in graph.nodes.enumerated() where index < solution.points.count {
            let center = solution[index]
            let x = center.x + m - nodeWidth / 2
            let y = center.y + m - nodeHeight / 2

            setSource(ctx, palette.nodeFill)
            ctx.rectangle(x: x, y: y, width: nodeWidth, height: nodeHeight)
            ctx.fill()

            if selected == index {
                setSource(ctx, brand)
                ctx.lineWidth = 2
            } else if hovered == index {
                setSource(ctx, palette.borderHover)
                ctx.lineWidth = 1.5
            } else {
                setSource(ctx, palette.border)
                ctx.lineWidth = 1
            }
            ctx.rectangle(x: x, y: y, width: nodeWidth, height: nodeHeight)
            ctx.stroke()

            setSource(ctx, palette.nodeText)
            let label = PharoVisualArea.fit(node.label, into: nodeWidth - 12, ctx: ctx)
            label.withCString { text in
                let extents = ctx.textExtents(text)
                ctx.moveTo(x + (nodeWidth - extents.width) / 2, y + (nodeHeight + extents.height) / 2)
                ctx.showText(text)
            }
        }

        cairo_restore(ctx.context_ptr)
    }
}
