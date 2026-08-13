import CGraphene
import CGtk
import Foundation
import struct Graphene.RectRef
import Gtk
import LumaCore
import SwiftyPharo

/// A moldable inspection drawn as Miller columns: each drilled object a column
/// beside the last, any pane shrunk to a stack of miniatures or blown up to
/// fill. The overview strip that reaches the columns lives above the whole page
/// with the playground, not here. Mirrors the SwiftUI inspector.
@MainActor
final class PharoColumnsView {
    let widget: Box

    /// Called after the columns change, so the page can rebuild its strip and
    /// show or hide this pane.
    var onChanged: (() -> Void)?

    private let runtime: PharoRuntime
    private let state = PharoColumnState()
    private let columns: Box
    private let scroll: ScrolledWindow
    private var columnWidth = 380
    private var columnViews: [PharoColumnView] = []
    private var columnAnchors: [(depth: Int, widget: WidgetRef)] = []
    private var pendingScrollToNewest = false

    init(runtime: PharoRuntime) {
        self.runtime = runtime

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        columns = Box(orientation: .horizontal, spacing: 0)
        columns.hexpand = true
        columns.vexpand = true

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        // External, not never: the columns still clip and scroll, the page just
        // draws its own thumb for them instead of GTK's scrollbar.
        scroll.setPolicy(hscrollbarPolicy: .external, vscrollbarPolicy: .never)
        scroll.set(child: columns)
        widget.append(child: scroll)

        scroll.hadjustment?.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPendingScroll() }
        }
    }

    var isEmpty: Bool { state.objects.isEmpty }
    var columnCount: Int { state.objects.count }
    var shownDepth: Int? { state.shown }
    var contentAdjustment: AdjustmentRef? { scroll.hadjustment }

    func printString(at depth: Int) -> String {
        guard depth >= 0, depth < state.objects.count else { return "" }
        return state.objects[depth].printString
    }

    func present(_ object: PharoObject) {
        state.startOver(at: object)
        render()
        scrollToNewest()
    }

    func clearAll() {
        state.clear()
        render()
    }

    /// Reach the column at a depth: a collapsed one expands, any other scrolls
    /// into view and becomes the current column.
    func reveal(depth: Int) {
        guard depth >= 0, depth < state.objects.count else { return }
        if state.isCollapsed(state.objects[depth].handle) {
            state.toggleCollapsed(state.objects[depth].handle)
            state.show(depth)
            render()
            return
        }
        state.show(depth)
        scrollToColumn(depth)
        onChanged?()
    }

    func focusPage() {
        state.show(nil)
        onChanged?()
    }

    private func scrollToNewest() {
        pendingScrollToNewest = true
        applyPendingScroll()
    }

    private func applyPendingScroll() {
        guard pendingScrollToNewest, let adjustment = scroll.hadjustment, adjustment.pageSize > 0 else { return }
        adjustment.value = max(adjustment.upper - adjustment.pageSize, adjustment.lower)
        pendingScrollToNewest = false
    }

    private func scrollToColumn(_ depth: Int) {
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

    private func render() {
        clear(columns)
        columnViews.removeAll()
        columnAnchors.removeAll()

        if !state.objects.isEmpty {
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
        }
        onChanged?()
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
            guard let self else { return }
            self.state.open(element, from: depth)
            self.render()
            self.scrollToNewest()
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
                    guard let self else { return }
                    self.state.toggleCollapsed(object.handle)
                    self.state.show(depth)
                    self.render()
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

    private func clear(_ box: Box) {
        while let existing = box.getFirstChild() {
            box.remove(child: existing)
        }
    }
}
