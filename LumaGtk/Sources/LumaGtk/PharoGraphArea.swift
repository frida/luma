import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk
import LumaCore
import SwiftyPharo

/// A `mondrian` graph the reader can walk: click a node to select it and again
/// to drill, arrow keys to step to the neighbour in a direction, Return to
/// drill, Escape to let go. The selected node and its edges wear the brand
/// colour; a hovered one lightens. Mirrors the SwiftUI graph over the shared
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

    init(graph: PharoGraph) {
        self.graph = graph
        solution = PharoGraphLayout(
            nodeCount: graph.nodes.count,
            edges: graph.edges.map { .init(from: $0.from, to: $0.to) },
            kind: .init(graph.layout)
        ).solve()

        area = DrawingArea()
        area.contentWidth = Int(solution.width + 2 * PharoVisualArea.margin)
        area.contentHeight = Int(solution.height + 2 * PharoVisualArea.margin)
        area.hexpand = true
        area.vexpand = true
        area.focusable = true
        area.canFocus = true

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: WidgetRef(area.widget_ptr))
        widget = Box(orientation: .vertical, spacing: 0)
        widget.append(child: scroll)

        area.setDrawFunc { [weak self] _, ctx, _, _ in
            MainActor.assumeIsolated { self?.draw(ctx) }
        }

        let click = GestureClick()
        click.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated { self?.activate(at: x, y) }
        }
        area.install(controller: click)

        let motion = EventControllerMotion()
        motion.onMotion { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.setHovered(self?.node(at: x, y)) }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.setHovered(nil) }
        }
        area.install(controller: motion)

        let keys = EventControllerKey()
        keys.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated { self?.handleKey(keyval) ?? false }
        }
        area.install(controller: keys)
    }

    private func activate(at x: Double, _ y: Double) {
        _ = area.grabFocus()
        guard let index = node(at: x, y) else { return }
        if selected == index {
            onDrill?(index)
        } else {
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

    private func node(at x: Double, _ y: Double) -> Int? {
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

    private func draw(_ ctx: Cairo.ContextRef) {
        let nodeWidth = PharoGraphLayout.nodeWidth
        let nodeHeight = PharoGraphLayout.nodeHeight
        let m = PharoVisualArea.margin
        PharoVisualArea.setFont(ctx, size: 12)

        for edge in graph.edges where edge.from < solution.points.count && edge.to < solution.points.count {
            if edge.from == selected || edge.to == selected {
                ctx.setSource(red: 0.937, green: 0.392, blue: 0.337, alpha: 0.9)
            } else {
                ctx.setSource(red: 0.5, green: 0.5, blue: 0.56, alpha: 0.8)
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

            ctx.setSource(red: 0.16, green: 0.20, blue: 0.27, alpha: 1)
            ctx.rectangle(x: x, y: y, width: nodeWidth, height: nodeHeight)
            ctx.fill()

            if selected == index {
                ctx.setSource(red: 0.937, green: 0.392, blue: 0.337, alpha: 1)
                ctx.lineWidth = 2
            } else if hovered == index {
                ctx.setSource(red: 0.75, green: 0.76, blue: 0.80, alpha: 1)
                ctx.lineWidth = 1.5
            } else {
                ctx.setSource(red: 0.42, green: 0.44, blue: 0.50, alpha: 1)
                ctx.lineWidth = 1
            }
            ctx.rectangle(x: x, y: y, width: nodeWidth, height: nodeHeight)
            ctx.stroke()
            ctx.lineWidth = 1

            ctx.setSource(red: 0.9, green: 0.9, blue: 0.93, alpha: 1)
            let label = PharoVisualArea.fit(node.label, into: nodeWidth - 12, ctx: ctx)
            label.withCString { text in
                let extents = ctx.textExtents(text)
                ctx.moveTo(x + (nodeWidth - extents.width) / 2, y + (nodeHeight + extents.height) / 2)
                ctx.showText(text)
            }
        }
    }
}
