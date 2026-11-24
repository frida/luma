import CCairo
import CGraphene
import CGtk
import Cairo
import Foundation
import struct Graphene.RectRef
import Gtk
import GtkSource
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

    var chatOrigin: () -> PharoChatOrigin? = { nil }
    private var foundChatOrigins: [Int: PharoChatOrigin] = [:]
    private var chatOriginSearch: Task<Void, Never>?

    private var maximizedView: PharoColumnView?
    private let maximizedOverlay: Overlay
    private var maximizedPanel: Box?

    private weak var engine: Engine?
    private let runtime: PharoRuntime
    private let highlight: (GtkSource.Buffer) -> Void
    private let state = PharoColumnState()
    private let columns: Box
    private let scroll: ScrolledWindow
    private let arrowArea: DrawingArea
    private var pointingFromY: Double?
    private var leadingStack: Box?
    private let leadingTriangleHalf = 8.0
    private var columnWidth = 380
    private let columnsInset = 12
    private var columnViews: [PharoColumnView] = []
    private var columnAnchors: [(depth: Int, widget: WidgetRef)] = []

    private enum ScrollGoal {
        case none
        case newest
        case column(Int)
        case origin
    }

    private var scrollGoal: ScrollGoal = .none
    private var scrollScheduled = false
    private var autoScrolling = false

    init(
        engine: Engine, runtime: PharoRuntime, maximizingOver maximizedOverlay: Overlay, highlight: @escaping (GtkSource.Buffer) -> Void
    ) {
        self.engine = engine
        self.runtime = runtime
        self.maximizedOverlay = maximizedOverlay
        self.highlight = highlight

        // A fixed arrow down the left edge points from the snippet that opened
        // the inspection into its first column, so it stays put as the columns
        // scroll under it.
        arrowArea = DrawingArea()
        arrowArea.setSizeRequest(width: 22, height: -1)
        arrowArea.vexpand = true
        arrowArea.visible = false

        widget = Box(orientation: .horizontal, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        // The columns sit inside the same inset the page keeps above its top
        // snippet, so cards on both sides start at the same height and a scroll
        // to the end leaves matching air past the last column.
        columns = Box(orientation: .horizontal, spacing: 0)
        columns.hexpand = true
        columns.vexpand = true
        columns.marginTop = columnsInset
        columns.marginBottom = columnsInset
        columns.marginEnd = columnsInset

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        // External, not never: the columns still clip and scroll, the page just
        // draws its own thumb for them instead of GTK's scrollbar.
        scroll.setPolicy(hscrollbarPolicy: .external, vscrollbarPolicy: .never)
        scroll.set(child: columns)

        widget.append(child: arrowArea)
        widget.append(child: scroll)

        arrowArea.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated { self?.drawArrow(ctx, Double(width), Double(height)) }
        }
        scroll.hadjustment?.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScroll() }
        }
        scroll.hadjustment?.onValueChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.autoScrolling else { return }
                if case .newest = self.scrollGoal { self.scrollGoal = .none }
            }
        }
    }

    /// Point the leading arrow at the vertical center of the snippet that opened
    /// this inspection, measured in this pane's own space.
    func pointArrow(fromCenterOf source: WidgetRef) {
        var bounds = graphene_rect_t()
        let ok = withUnsafeMutablePointer(to: &bounds) { pointer in
            source.computeBounds(target: WidgetRef(widget), outBounds: RectRef(pointer))
        }
        pointingFromY = ok ? Double(bounds.origin.y + bounds.size.height / 2) : nil
        positionLeadingConnector()
        arrowArea.queueDraw()
    }

    /// The snippet's connector into the first column: a triangle when that column
    /// stands open, but when it is collapsed the stack steps into the arrow's
    /// place. Its own down-triangle -- not the whole stack -- lines up with the
    /// snippet's center, the way the open arrow does, and the squares hang below.
    private func positionLeadingConnector() {
        if let stack = leadingStack, let y = pointingFromY {
            arrowArea.visible = false
            stack.valign = .start
            stack.marginTop = Int(max(0, y - Double(columnsInset) - leadingTriangleHalf))
        } else {
            arrowArea.visible = pointingFromY != nil && !state.objects.isEmpty
        }
    }

    private func drawArrow(_ ctx: Cairo.ContextRef, _ width: Double, _ height: Double) {
        guard let y = pointingFromY else { return }
        drawSeamTriangle(ctx, centerX: width / 2, centerY: y)
    }

    private func drawSeamTriangle(_ ctx: Cairo.ContextRef, centerX: Double, centerY: Double) {
        let color = PharoVizColors.current.edge
        ctx.setSource(red: color.r, green: color.g, blue: color.b, alpha: 1)
        let x = centerX - 4
        ctx.moveTo(x, centerY - 6)
        ctx.lineTo(x + 8, centerY)
        ctx.lineTo(x, centerY + 6)
        cairo_close_path(ctx.context_ptr)
        ctx.fill()
    }

    /// The strip stands over the whole page: a square for the page, then one
    /// per inspector column, with the current one drawn brightest.
    func drive(_ bar: PharoOverviewBar, naming pageName: String) {
        bar.slotCount = { [weak self] in 1 + (self?.columnCount ?? 0) }
        bar.isCurrent = { [weak self] slot in
            guard let self else { return false }
            return slot == 0 ? self.shownDepth == nil : self.shownDepth == slot - 1
        }
        bar.tooltip = { [weak self] slot in
            guard let self else { return "" }
            return slot == 0 ? pageName : self.printString(at: slot - 1)
        }
        bar.activate = { [weak self] slot in
            guard let self else { return }
            if slot == 0 { self.focusPage() } else { self.reveal(depth: slot - 1) }
        }
        bar.adjustment = { [weak self] in self?.contentAdjustment }
        contentAdjustment?.onValueChanged { _ in
            MainActor.assumeIsolated { bar.refresh() }
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
            scrollGoal = .none
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
        scrollToOrigin()
        onChanged?()
    }

    private func scrollToNewest() {
        scroll(toward: .newest)
    }

    private func scrollToColumn(_ depth: Int) {
        scroll(toward: .column(depth))
    }

    private func scrollToOrigin() {
        scroll(toward: .origin)
    }

    private func scroll(toward goal: ScrollGoal) {
        scrollGoal = goal
        scheduleScroll()
    }

    // Scroll from a task the "changed" signal schedules, so it runs after layout
    // -- a new column's width only lands in the adjustment once allocation
    // settles, and poking it synchronously reads a stale upper and misses.
    private func scheduleScroll() {
        guard !scrollScheduled else { return }
        if case .none = scrollGoal { return }
        scrollScheduled = true
        Task { @MainActor in
            self.scrollScheduled = false
            self.applyScroll()
        }
    }

    private func applyScroll() {
        guard let adjustment = scroll.hadjustment, adjustment.pageSize > 0 else { return }
        let target: Double?
        switch scrollGoal {
        case .none: target = nil
        case .newest: target = leadingColumnOffset(showingNewestIn: adjustment)
        case .origin: target = adjustment.lower
        case .column(let depth): target = columnOffset(depth)
        }
        guard let target else { return }
        autoScrolling = true
        adjustment.value = target
        autoScrolling = false
        if case .newest = scrollGoal {} else { scrollGoal = .none }
    }

    private func leadingColumnOffset(showingNewestIn adjustment: AdjustmentRef) -> Double {
        let padding = Double(columns.marginEnd - columnsInset)
        let end = max(adjustment.upper - padding - adjustment.pageSize, adjustment.lower)
        guard let leading = columnAnchors.compactMap({ columnOffset($0.depth) }).filter({ $0 >= end }).min() else { return end }
        columns.marginEnd = columnsInset + Int((leading - end).rounded(.up))
        return leading
    }

    private func columnOffset(_ depth: Int) -> Double? {
        guard let anchor = columnAnchors.first(where: { $0.depth == depth })?.widget else { return nil }
        var bounds = graphene_rect_t()
        let ok = withUnsafeMutablePointer(to: &bounds) { pointer in
            anchor.computeBounds(target: columns, outBounds: RectRef(pointer))
        }
        return ok ? Double(bounds.origin.x) : nil
    }

    private func render() {
        clear(columns)
        columns.marginEnd = columnsInset
        columnViews.removeAll()
        columnAnchors.removeAll()
        leadingStack = nil

        if state.objects.isEmpty {
            pointingFromY = nil
            arrowArea.visible = false
            maximizedView = nil
            presentMaximized(nil)
        }

        if !state.objects.isEmpty {
            if let handle = state.maximized, let depth = state.objects.firstIndex(where: { $0.handle == handle }) {
                // The blown-up pane is laid over the whole playground by the page,
                // so it leaves the columns behind it empty rather than filling
                // only this side.
                let view = maximizedColumn(at: depth, handle: handle)
                maximizedView = view
                presentMaximized(view.widget)
            } else {
                maximizedView = nil
                presentMaximized(nil)
                var depth = 0
                var previousWasExpanded = false
                while depth < state.objects.count {
                    if state.isCollapsed(state.objects[depth].handle) {
                        let start = depth
                        while depth < state.objects.count, state.isCollapsed(state.objects[depth].handle) { depth += 1 }
                        let stack = collapsedStack(from: start, to: depth, hasFollowingExpanded: depth < state.objects.count)
                        if start == 0 {
                            leadingStack = stack
                        }
                        columns.append(child: stack)
                        for buried in start..<depth { columnAnchors.append((buried, WidgetRef(stack))) }
                        previousWasExpanded = false
                    } else {
                        if previousWasExpanded { columns.append(child: drillArrow()) }
                        let view = column(at: depth)
                        view.widget.setSizeRequest(width: columnWidth, height: -1)
                        columns.append(child: view.widget)
                        columnAnchors.append((depth, WidgetRef(view.widget)))
                        previousWasExpanded = true
                        depth += 1
                    }
                }
            }
        }
        positionLeadingConnector()
        findChatOrigins()
        onChanged?()
    }

    /// A blown-up pane covers the page and the columns both, floating over the
    /// paned rather than filling only the inspector side.
    private func presentMaximized(_ content: Widget?) {
        if let existing = maximizedPanel {
            maximizedOverlay.removeOverlay(widget: existing)
            maximizedPanel = nil
        }
        guard let content else { return }

        let panel = Box(orientation: .vertical, spacing: 0)
        panel.add(cssClass: "luma-pharo-maximized")
        panel.hexpand = true
        panel.vexpand = true
        panel.halign = .fill
        panel.valign = .fill
        panel.marginTop = 8
        panel.marginBottom = 8
        panel.marginStart = 8
        panel.marginEnd = 8
        content.hexpand = true
        content.vexpand = true
        panel.append(child: content)

        maximizedOverlay.addOverlay(widget: panel)
        maximizedPanel = panel
    }

    /// The triangle between two expanded columns, drawn the same size and given
    /// the same width as the one from the snippet into the first column, so the
    /// seams read alike wherever they fall.
    private func drillArrow() -> DrawingArea {
        let area = DrawingArea()
        area.setSizeRequest(width: 22, height: -1)
        area.vexpand = true
        area.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated {
                self?.drawSeamTriangle(ctx, centerX: Double(width) / 2, centerY: Double(height) / 2)
            }
        }
        return area
    }

    private func triangleGlyph(_ glyph: String) -> Label {
        let label = Label(str: glyph)
        label.add(cssClass: "dim-label")
        label.add(cssClass: "caption")
        return label
    }

    /// The views own the row and header handlers, so they have to outlive this
    /// call; keeping only their widgets would let them deallocate and leave the
    /// drill and pane actions dead.
    /// The blown-up pane restores before it drills or closes, so the overlay
    /// drops away and the columns behind it take over, the way the SwiftUI
    /// maximized pane hands back to its carousel.
    private func maximizedColumn(at depth: Int, handle: Int) -> PharoColumnView {
        let object = state.objects[depth]
        let view = PharoColumnView(engine: engine, runtime: runtime, object: object, isMaximized: true, highlight: highlight)
        view.chatOrigin = { [weak self] in self?.chatOriginOfColumn(at: depth) }
        view.onDrill = { [weak self] element in
            guard let self else { return }
            self.state.toggleMaximized(handle)
            self.state.open(element, from: depth)
            self.render()
            self.scrollToNewest()
        }
        view.onClose = { [weak self] in
            guard let self else { return }
            self.state.toggleMaximized(handle)
            self.state.close(from: depth)
            self.render()
        }
        view.onMaximize = { [weak self] in
            guard let self else { return }
            self.state.toggleMaximized(handle)
            self.render()
        }
        return view
    }

    private func column(at depth: Int) -> PharoColumnView {
        let object = state.objects[depth]
        let view = PharoColumnView(engine: engine, runtime: runtime, object: object, isMaximized: false, highlight: highlight)
        view.chatOrigin = { [weak self] in self?.chatOriginOfColumn(at: depth) }
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

    private func chatOriginOfColumn(at depth: Int) -> PharoChatOrigin? {
        let host = chatOrigin()
        return foundChatOrigins[depth] ?? (depth == 0 ? host : host?.reached())
    }

    private func findChatOrigins() {
        chatOriginSearch?.cancel()
        foundChatOrigins = [:]
        guard let chats = engine?.objectChats else { return }
        let objects = state.objects
        chatOriginSearch = Task { [weak self] in
            var located: [PharoChatOrigin?] = []
            for object in objects {
                let location = try? await chats.location(of: object)
                guard !Task.isCancelled else { return }
                located.append(location.map { PharoChatOrigin.of($0.objectID, in: $0.chatID, chats: chats) })
            }
            var found: [Int: PharoChatOrigin] = [:]
            for depth in located.indices {
                if let opener = located[...depth].lastIndex(where: { $0 != nil }), let origin = located[opener] {
                    found[depth] = opener == depth ? origin : origin.reached()
                }
            }
            self?.foundChatOrigins = found
        }
    }

    private func collapsedStack(from start: Int, to end: Int, hasFollowingExpanded: Bool) -> Box {
        let gap = 8
        let connectorWidth = 8
        let miniatureWidth = 22

        let stack = Box(orientation: .vertical, spacing: 6)
        stack.valign = .center
        stack.halign = .start
        stack.marginStart = gap

        let triangle = triangleGlyph("\u{25BC}")
        triangle.setSizeRequest(width: miniatureWidth, height: -1)
        triangle.xalign = 0.5
        triangle.halign = .start
        stack.append(child: triangle)

        for depth in start..<end {
            let object = state.objects[depth]
            let miniature = Button()
            miniature.add(cssClass: "luma-pharo-miniature")
            miniature.setSizeRequest(width: miniatureWidth, height: 26)
            miniature.halign = .start
            miniature.valign = .center
            miniature.tooltipText = "Expand \(object.className)"
            miniature.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scrollGoal = .none
                    self.state.toggleCollapsed(object.handle)
                    self.state.show(depth)
                    self.render()
                }
            }
            if hasFollowingExpanded, depth == end - 1 {
                let row = Box(orientation: .horizontal, spacing: 0)
                row.halign = .start
                row.append(child: miniature)
                let connector = Box(orientation: .horizontal, spacing: 0)
                connector.add(cssClass: "luma-pharo-connector")
                connector.valign = .center
                connector.setSizeRequest(width: connectorWidth, height: 2)
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
