import CCairo
import CGraphene
import CGtk
import Cairo
import Foundation
import struct Graphene.RectRef
import Gtk
import LumaCore
import SwiftyPharo

/// A moldable inspection drawn as Miller columns: each drilled object a column
/// beside the last, any pane shrunk to a strip or blown up to fill, and a pager
/// strip over them that marks and reaches each column. Mirrors the SwiftUI
/// inspector against the same runtime.
@MainActor
final class PharoColumnsView {
    let widget: Box

    private let runtime: PharoRuntime
    private let state = PharoColumnState()
    private let strip: Box
    private let squaresRow: Box
    private let thumb: DrawingArea
    private let columns: Box
    private let scroll: ScrolledWindow
    private var columnWidth = 380
    private var columnViews: [PharoColumnView] = []
    private var columnAnchors: [(depth: Int, widget: WidgetRef)] = []
    private var thumbHovered = false
    private var thumbDragBase = 0.0

    init(runtime: PharoRuntime) {
        self.runtime = runtime

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        squaresRow = Box(orientation: .horizontal, spacing: 3)
        squaresRow.halign = .center

        thumb = DrawingArea()
        thumb.setSizeRequest(width: -1, height: 8)
        thumb.hexpand = true

        strip = Box(orientation: .vertical, spacing: 3)
        strip.halign = .center
        strip.marginTop = 4
        strip.marginBottom = 4
        strip.append(child: squaresRow)
        strip.append(child: thumb)

        columns = Box(orientation: .horizontal, spacing: 0)
        columns.hexpand = true
        columns.vexpand = true

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        // External, not never: the columns still clip and scroll, we just draw
        // our own thumb for them instead of GTK's scrollbar.
        scroll.setPolicy(hscrollbarPolicy: .external, vscrollbarPolicy: .never)
        scroll.set(child: columns)

        widget.append(child: strip)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: scroll)

        installThumb()
    }

    private func installThumb() {
        thumb.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated { self?.drawThumb(ctx, Double(width), Double(height)) }
        }
        if let adjustment = scroll.hadjustment {
            adjustment.onValueChanged { [weak self] _ in
                MainActor.assumeIsolated { self?.thumb.queueDraw() }
            }
            adjustment.onChanged { [weak self] _ in
                MainActor.assumeIsolated { self?.thumb.queueDraw() }
            }
        }
        let drag = GestureDrag()
        drag.onDragBegin { [weak self] _, _, _ in
            MainActor.assumeIsolated { self?.thumbDragBase = self?.scroll.hadjustment?.value ?? 0 }
        }
        drag.onDragUpdate { [weak self] _, offsetX, _ in
            MainActor.assumeIsolated {
                guard let self, let adjustment = self.scroll.hadjustment else { return }
                let track = Double(self.thumb.width)
                guard track > 0 else { return }
                adjustment.value = self.thumbDragBase + offsetX / track * adjustment.upper
            }
        }
        thumb.install(controller: drag)
        let motion = EventControllerMotion()
        motion.onEnter { [weak self] _, _, _ in
            MainActor.assumeIsolated { self?.thumbHovered = true; self?.thumb.queueDraw() }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.thumbHovered = false; self?.thumb.queueDraw() }
        }
        thumb.install(controller: motion)
    }

    private func drawThumb(_ ctx: Cairo.ContextRef, _ width: Double, _ height: Double) {
        guard let adjustment = scroll.hadjustment else { return }
        let upper = max(adjustment.upper, 1)
        let page = adjustment.pageSize > 0 ? adjustment.pageSize : upper
        let fractionVisible = min(page / upper, 1)
        let fractionLeading = min(adjustment.value / upper, 1 - fractionVisible)
        let thumbWidth = max(width * fractionVisible, 12)
        let thumbX = min(width * fractionLeading, width - thumbWidth)
        let y = height / 2
        if thumbHovered {
            ctx.setSource(red: 0.937, green: 0.392, blue: 0.337, alpha: 1)
        } else {
            ctx.setSource(red: 0.55, green: 0.55, blue: 0.6, alpha: 0.6)
        }
        capsule(ctx, x: thumbX, y: y - 1.5, width: thumbWidth, height: 3)
        ctx.fill()
    }

    private func capsule(_ ctx: Cairo.ContextRef, x: Double, y: Double, width: Double, height: Double) {
        let radius = height / 2
        cairo_new_sub_path(ctx.context_ptr)
        cairo_arc(ctx.context_ptr, x + width - radius, y + radius, radius, -.pi / 2, .pi / 2)
        cairo_arc(ctx.context_ptr, x + radius, y + radius, radius, .pi / 2, 3 * .pi / 2)
        cairo_close_path(ctx.context_ptr)
    }

    func present(_ object: PharoObject) {
        state.startOver(at: object)
        render()
    }

    func showMessage(_ text: String) {
        state.clear()
        clear(squaresRow)
        clear(columns)
        strip.visible = false
        columnViews.removeAll()
        columnAnchors.removeAll()
        placeholder(text)
    }

    private func placeholder(_ text: String) {
        let label = Label(str: text)
        label.marginStart = 12
        label.marginTop = 12
        label.xalign = 0
        label.yalign = 0
        label.selectable = true
        label.wrap = true
        label.hexpand = true
        label.add(cssClass: "monospace")
        columns.append(child: label)
    }

    private func render() {
        clear(squaresRow)
        clear(columns)
        columnViews.removeAll()
        columnAnchors.removeAll()

        guard !state.objects.isEmpty else {
            strip.visible = false
            placeholder("Evaluate a snippet with Ctrl+Return to open its result here.")
            return
        }

        if let handle = state.maximized, let depth = state.objects.firstIndex(where: { $0.handle == handle }) {
            let view = column(at: depth, maximized: true)
            columns.append(child: view.widget)
            columnAnchors.append((depth, WidgetRef(view.widget)))
        } else {
            var depth = 0
            var previousWasExpanded = false
            while depth < state.objects.count {
                if state.isCollapsed(state.objects[depth].handle) {
                    let start = depth
                    while depth < state.objects.count, state.isCollapsed(state.objects[depth].handle) { depth += 1 }
                    let stack = collapsedStack(from: start, to: depth, hasFollowingExpanded: depth < state.objects.count)
                    columns.append(child: stack)
                    for buried in start..<depth { columnAnchors.append((buried, WidgetRef(stack))) }
                    previousWasExpanded = false
                } else {
                    if previousWasExpanded { columns.append(child: drillArrow()) }
                    let view = column(at: depth, maximized: false)
                    view.widget.setSizeRequest(width: columnWidth, height: -1)
                    columns.append(child: view.widget)
                    columnAnchors.append((depth, WidgetRef(view.widget)))
                    previousWasExpanded = true
                    depth += 1
                }
            }
        }
        renderStrip()
    }

    /// The triangle between two expanded columns, centred down the seam, that
    /// marks the drill from the left column into the right.
    private func drillArrow() -> Image {
        let arrow = Image(iconName: "pan-end-symbolic")
        arrow.add(cssClass: "dim-label")
        arrow.vexpand = true
        arrow.valign = .center
        arrow.marginStart = 2
        arrow.marginEnd = 2
        return arrow
    }

    /// The views own the row and header handlers, so they have to outlive this
    /// call; keeping only their widgets would let them deallocate and leave the
    /// drill and pane actions dead.
    private func column(at depth: Int, maximized: Bool) -> PharoColumnView {
        let object = state.objects[depth]
        let view = PharoColumnView(runtime: runtime, object: object, isMaximized: maximized)
        columnViews.append(view)
        view.onDrill = { [weak self] element in
            self?.state.open(element, from: depth)
            self?.render()
        }
        view.onClose = { [weak self] in
            self?.state.close(from: depth)
            self?.render()
        }
        view.onCollapse = { [weak self] in
            self?.state.toggleCollapsed(object.handle)
            self?.render()
        }
        view.onMaximize = { [weak self] in
            self?.state.toggleMaximized(object.handle)
            self?.render()
        }
        return view
    }

    /// Consecutive collapsed columns fold into one stack of miniatures under a
    /// downward triangle; the last one draws an edge to the expanded column that
    /// follows. Clicking a miniature expands it.
    private func collapsedStack(from start: Int, to end: Int, hasFollowingExpanded: Bool) -> Box {
        let stack = Box(orientation: .vertical, spacing: 6)
        stack.valign = .center
        stack.marginStart = 8
        stack.marginEnd = 8

        let triangle = Image(iconName: "pan-down-symbolic")
        triangle.add(cssClass: "dim-label")
        stack.append(child: triangle)

        for depth in start..<end {
            let object = state.objects[depth]
            let miniature = Button()
            miniature.add(cssClass: "luma-pharo-miniature")
            miniature.setSizeRequest(width: 22, height: 26)
            miniature.tooltipText = "Expand \(object.className)"
            miniature.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.state.toggleCollapsed(object.handle)
                    self?.render()
                }
            }
            if hasFollowingExpanded, depth == end - 1 {
                let row = Box(orientation: .horizontal, spacing: 0)
                row.append(child: miniature)
                let connector = Box(orientation: .horizontal, spacing: 0)
                connector.add(cssClass: "luma-pharo-connector")
                connector.valign = .center
                connector.setSizeRequest(width: 10, height: 2)
                row.append(child: connector)
                stack.append(child: row)
            } else {
                stack.append(child: miniature)
            }
        }
        return stack
    }

    /// A square per column that reaches it: a collapsed one expands, any other
    /// scrolls into view. The last, deepest column wears the brand colour.
    private func renderStrip() {
        strip.visible = state.objects.count > 1
        guard state.objects.count > 1 else { return }
        for (depth, object) in state.objects.enumerated() {
            let square = Button()
            square.add(cssClass: "luma-pharo-strip")
            square.setSizeRequest(width: 22, height: 12)
            square.tooltipText = object.printString
            if depth == state.objects.count - 1 {
                square.add(cssClass: "current")
            }
            square.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.reveal(depth: depth) }
            }
            squaresRow.append(child: square)
        }
        thumb.queueDraw()
    }

    private func reveal(depth: Int) {
        guard depth < state.objects.count else { return }
        if state.isCollapsed(state.objects[depth].handle) {
            state.toggleCollapsed(state.objects[depth].handle)
            render()
            return
        }
        guard let anchor = columnAnchors.first(where: { $0.depth == depth })?.widget,
              let adjustment = scroll.hadjustment
        else { return }
        var bounds = graphene_rect_t()
        let ok = withUnsafeMutablePointer(to: &bounds) { pointer in
            anchor.computeBounds(target: columns, outBounds: RectRef(pointer))
        }
        guard ok else { return }
        adjustment.value = Double(bounds.origin.x)
    }

    private func clear(_ box: Box) {
        while let existing = box.getFirstChild() {
            box.remove(child: existing)
        }
    }
}
