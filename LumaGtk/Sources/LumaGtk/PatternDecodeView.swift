import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import GLibObject
import Gtk
import LumaCore

enum PatternDecodeSizing {
    case capped
    case fill
}

@MainActor
final class PatternDecodeView {
    let widget: Box

    var onTruncated: (() -> Void)?

    private let engine: Engine
    private let sessionID: UUID
    private let onPlacementsChanged: ([PatternPlacement]) -> Void

    private let hexView: HexView
    private let hexScroller: ScrolledWindow
    private let treeScroller: ScrolledWindow
    private let treeList: ListBox

    private var data: Data
    private var baseAddress: UInt64?
    private var placements: [PatternPlacement]
    private var summaries: [String: PatternSummary] = [:]
    private var results: [UUID: PlacementResult] = [:]
    private var locations: [UUID: PatternLocation] = [:]
    private var visualizations: [UUID: NodeVisualization] = [:]
    private var visualizerAnchors: [UUID: Widget] = [:]
    private var openPopover: Popover?
    private var expanded: Set<UUID> = []
    private var rows: [TreeRow] = []
    private var selectedID: UUID?
    private var isSelectingProgrammatically = false
    private var decodeTask: Task<Void, Never>?

    private static let cappedHeight = 400
    private static let treeInset = 4

    init(
        engine: Engine,
        sessionID: UUID,
        data: Data,
        baseAddress: UInt64?,
        placements: [PatternPlacement],
        sizing: PatternDecodeSizing,
        onPlacementsChanged: @escaping ([PatternPlacement]) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.data = data
        self.baseAddress = baseAddress
        self.placements = placements
        self.onPlacementsChanged = onPlacementsChanged
        expanded = Set(placements.map(\.id))

        hexView = HexView(bytes: data, baseAddress: baseAddress ?? 0)
        hexView.widget.vexpand = false
        hexView.widget.valign = .start

        hexScroller = ScrolledWindow()
        hexScroller.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        hexScroller.set(child: hexView.widget)

        treeList = ListBox()
        treeList.selectionMode = .single
        treeList.add(cssClass: "luma-pattern-tree")
        treeList.marginTop = Self.treeInset
        treeList.marginBottom = Self.treeInset

        treeScroller = ScrolledWindow()
        treeScroller.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        treeScroller.set(child: treeList)
        treeScroller.hexpand = true
        treeScroller.setSizeRequest(width: 360, height: -1)

        widget = Box(orientation: .horizontal, spacing: 16)
        widget.append(child: hexScroller)
        widget.append(child: treeScroller)

        for scroller in [hexScroller, treeScroller] {
            switch sizing {
            case .capped:
                scroller.propagateNaturalHeight = true
                scroller.maxContentHeight = Self.cappedHeight
                scroller.valign = .start
            case .fill:
                scroller.vexpand = true
            }
        }

        hexView.onCaretMove = { [weak self] index in self?.selectNode(at: index) }
        hexView.menuSections = { [weak self] in self?.placementMenuSections() ?? [] }
        installTreeHandlers()
        showTree()
        decode()
    }

    func setData(_ data: Data, baseAddress: UInt64?) {
        self.data = data
        self.baseAddress = baseAddress
        hexView.setBytes(data, baseAddress: baseAddress ?? 0)
        decode()
    }

    private func selectNode(at index: Int) {
        let hits = locations.values.filter { $0.range.contains(index) }
        guard let innermost = hits.min(by: { ($0.range.count, -$0.ancestors.count) < ($1.range.count, -$1.ancestors.count) }) else {
            return
        }
        let hidden = innermost.ancestors.filter { !expanded.contains($0) }
        expanded.formUnion(innermost.ancestors)
        if !hidden.isEmpty {
            rebuildRows()
        }
        select(innermost.node.id, revealingHex: false)
    }

    private func placementMenuSections() -> [[ContextMenu.Item]] {
        guard let baseAddress, target != nil, !engine.patterns.sources.isEmpty else { return [] }
        let caret = hexView.caret
        let label = String(format: "Decode at 0x%llx as…", baseAddress &+ UInt64(caret))
        return [[.init(label) { [weak self] in self?.presentPlacementMenu(caret: caret) }]]
    }

    private static let menuTypeLimit = 8

    private func presentPlacementMenu(caret: Int) {
        guard let target else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var described: [String: PatternSummary] = [:]
            for source in engine.patterns.sources {
                described[source.id] = try? await engine.patternDecoder.summary(of: source, platform: target.platform, arch: target.arch)
            }
            var sections: [[ContextMenu.Item]] = []
            let recent = recentItems(caret: caret, summaries: described)
            if !recent.isEmpty {
                sections.append([.init("Recent", enabled: false) {}] + recent)
            }
            for source in engine.patterns.sources {
                guard let summary = described[source.id] else { continue }
                sections.append(items(for: source, summary: summary, caret: caret))
            }
            hexView.presentMenu(sections)
        }
    }

    private func recentItems(caret: Int, summaries: [String: PatternSummary]) -> [ContextMenu.Item] {
        let sources = engine.patterns.sources
        return engine.placementHistory.recent.compactMap { entry in
            guard let source = sources.first(where: { $0.id == entry.sourceID }),
                summaries[source.id]?.decodableTypes.contains(where: { $0.name == entry.typeName }) == true
            else { return nil }
            let label = sources.count > 1 ? "\(entry.typeName) (\(source.name))" : entry.typeName
            return .init(label) { [weak self] in
                self?.place(PatternPlacement(sourceID: source.id, typeName: entry.typeName, offset: caret))
            }
        }
    }

    private func items(for source: PatternSource, summary: PatternSummary, caret: Int) -> [ContextMenu.Item] {
        var items: [ContextMenu.Item] = [.init(source.name, enabled: false) {}]
        if let rootType = summary.rootType {
            items.append(
                .init("Run file") { [weak self] in
                    self?.place(PatternPlacement(sourceID: source.id, typeName: rootType, offset: 0))
                })
        }
        for type in summary.decodableTypes.prefix(Self.menuTypeLimit) {
            items.append(
                .init(type.name) { [weak self] in
                    self?.place(PatternPlacement(sourceID: source.id, typeName: type.name, offset: caret))
                })
        }
        if summary.decodableTypes.count > Self.menuTypeLimit {
            items.append(
                .init("All \(summary.decodableTypes.count) types…") { [weak self] in
                    self?.browseTypes(of: source, summary: summary, caret: caret)
                })
        }
        return items
    }

    private func browseTypes(of source: PatternSource, summary: PatternSummary, caret: Int) {
        SidebarBrowserPopover(
            items: summary.decodableTypes,
            placeholder: "Filter types",
            emptyMessage: "No matching types",
            groupName: { $0.kind.title },
            title: { $0.name },
            tooltip: { $0.kind.title },
            matches: { type, query in type.name.localizedCaseInsensitiveContains(query) },
            onChoose: { [weak self] type in
                self?.place(PatternPlacement(sourceID: source.id, typeName: type.name, offset: caret))
            }
        ).presentAnchored(to: hexView.widget)
    }

    private func place(_ placement: PatternPlacement) {
        placements.append(placement)
        expanded.insert(placement.id)
        engine.placementHistory.note(placement)
        onPlacementsChanged(placements)
        showTree()
        decode()
    }

    private func remove(_ placementID: UUID) {
        placements.removeAll { $0.id == placementID }
        onPlacementsChanged(placements)
        showTree()
        decode()
    }

    private func installTreeHandlers() {
        treeList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, !self.isSelectingProgrammatically, let row else { return }
                self.select(self.rows[Int(row.index)].id, revealingHex: true)
            }
        }

        treeList.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activate(self.rows[Int(row.index)].id)
            }
        }

        let keys = EventControllerKey()
        keys.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                self?.handleKey(Int32(truncatingIfNeeded: keyval)) ?? false
            }
        }
        treeList.add(controller: keys)
    }

    private func activate(_ id: UUID) {
        guard let visualization = visualizations[id], let anchor = visualizerAnchors[id] else { return }
        if case .button = visualization.inline {
            press(visualization, anchor: anchor)
        } else {
            presentVisualizer(visualization, anchor: anchor)
        }
    }

    private func press(_ visualization: NodeVisualization, anchor: Widget) {
        guard case .ready(.button(let function, _)) = visualization.outcome, let baseAddress, let target,
            let source = engine.patterns.source(withID: visualization.placement.sourceID)
        else { return }
        let placement = visualization.placement
        Task { @MainActor [weak self] in
            guard let self else { return }
            let output: Label
            do {
                let printed = try await engine.patternDecoder.callFunction(
                    function, on: visualization.nodeID, of: source, typeName: placement.typeName, data: bytes(at: placement),
                    address: baseAddress &+ UInt64(placement.offset), platform: target.platform, arch: target.arch)
                output = Label(str: printed.isEmpty ? "No output." : printed)
            } catch {
                output = Label(str: error.localizedDescription)
                output.add(cssClass: "error")
            }
            output.add(cssClass: "monospace")
            output.selectable = true
            output.marginStart = 10
            output.marginEnd = 10
            output.marginTop = 10
            output.marginBottom = 10
            present(output, owning: nil, from: anchor)
        }
    }

    private func presentVisualizer(_ visualization: NodeVisualization, anchor: Widget) {
        switch visualization.outcome {
        case .ready(let ready):
            let view = PatternVisualizationWidget(ready)
            present(view.widget, owning: view, from: anchor)
        case .failed(let message):
            let failure = Label(str: message)
            failure.add(cssClass: "error")
            failure.marginStart = 12
            failure.marginEnd = 12
            failure.marginTop = 12
            failure.marginBottom = 12
            present(failure, owning: nil, from: anchor)
        }
    }

    private func present(_ content: Widget, owning view: AnyObject?, from anchor: Widget) {
        openPopover?.popdown()
        let popover = Popover()
        popover.autohide = true
        popover.position = .bottom
        popover.set(parent: anchor)
        popover.set(child: content)
        if let view {
            GLibObject.ObjectRef(raw: popover.ptr).setDataFull(
                key: "luma-visualization", data: Unmanaged.passRetained(view).toOpaque(),
                destroy: { data in Unmanaged<AnyObject>.fromOpaque(data!).release() })
        }
        popover.onClosed { [weak self] closed in
            MainActor.assumeIsolated {
                closed.unparent()
                if self?.openPopover?.ptr == closed.ptr {
                    self?.openPopover = nil
                }
            }
        }
        openPopover = popover
        popover.popup()
    }

    private func handleKey(_ keyval: Int32) -> Bool {
        guard let current = rows.firstIndex(where: { $0.id == selectedID }) else { return false }
        let row = rows[current]
        let isExpanded = expanded.contains(row.id)
        switch keyval {
        case Gdk.keyLeft:
            if row.isExpandable && isExpanded {
                toggle(row.id)
            } else if let parent = row.parent {
                select(parent, revealingHex: true)
            }
            return true
        case Gdk.keyRight:
            if row.isExpandable && !isExpanded {
                toggle(row.id)
            } else if row.isExpandable, rows.indices.contains(current + 1) {
                select(rows[current + 1].id, revealingHex: true)
            }
            return true
        default:
            return false
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
        rebuildRows()
    }

    private func select(_ id: UUID, revealingHex: Bool) {
        selectedID = id
        hexView.emphasis = locations[id]?.annotation
        if revealingHex, let location = locations[id] {
            reveal(hexView.rowSpan(containing: location.range.lowerBound), in: hexScroller)
        }
        guard let index = rows.firstIndex(where: { $0.id == id }), let row = treeList.getRowAt(index: index) else { return }
        isSelectingProgrammatically = true
        treeList.select(row: row)
        isSelectingProgrammatically = false
        let rowHeight = Double(treeList.height) / Double(rows.count)
        reveal((Double(Self.treeInset) + Double(index) * rowHeight, rowHeight), in: treeScroller)
    }

    private func reveal(_ span: (top: Double, height: Double), in scroller: ScrolledWindow) {
        let adjustment = scroller.vadjustment!
        if span.top < adjustment.value {
            adjustment.value = span.top
        } else if span.top + span.height > adjustment.value + adjustment.pageSize {
            adjustment.value = span.top + span.height - adjustment.pageSize
        }
    }

    private func showTree() {
        treeScroller.visible = !placements.isEmpty
    }

    private func decode() {
        decodeTask?.cancel()
        guard let baseAddress, let target else { return }
        let placements = placements
        decodeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var results: [UUID: PlacementResult] = [:]
            var described: [String: PatternSummary] = [:]
            for placement in placements {
                guard let source = engine.patterns.source(withID: placement.sourceID) else { continue }
                described[source.id] = try? await engine.patternDecoder.summary(of: source, platform: target.platform, arch: target.arch)
                do {
                    let value = try await engine.patternDecoder.decode(
                        source, typeName: placement.typeName, data: bytes(at: placement), address: baseAddress &+ UInt64(placement.offset),
                        platform: target.platform, arch: target.arch)
                    results[placement.id] = .decoded(value)
                } catch {
                    results[placement.id] = .failed(error.localizedDescription)
                }
            }
            guard !Task.isCancelled else { return }
            summaries = described
            show(results, base: baseAddress)
            if results.values.contains(where: \.isTruncated) {
                onTruncated?()
            }
        }
    }

    private var target: LumaCore.ProcessNode.ProcessInfo? {
        engine.node(forSessionID: sessionID)?.processInfo
    }

    private func bytes(at placement: PatternPlacement) -> Data {
        data.suffix(from: data.startIndex + min(placement.offset, data.count))
    }

    private func show(_ results: [UUID: PlacementResult], base: UInt64) {
        let remap = PatternNodeRemap(from: Self.roots(of: self.results), to: Self.roots(of: results), placements: Set(placements.map(\.id)))
        self.results = results
        expanded = Set(expanded.compactMap(remap.callAsFunction))
        selectedID = selectedID.flatMap(remap.callAsFunction)
        var located: [UUID: PatternLocation] = [:]
        for placement in placements {
            if case .decoded(let root) = results[placement.id] {
                PatternLocation.locateFields(of: root, under: placement.id, base: base, into: &located)
            }
        }
        locations = located
        visualizations = [:]
        for placement in placements {
            if case .decoded(let root) = results[placement.id] {
                visualize(root, root: root, placement: placement)
            }
        }
        hexView.annotations = located.values.filter(\.isLeaf).map(\.annotation)
        hexView.emphasis = selectedID.flatMap { located[$0] }?.annotation
        rebuildRows()
    }

    private static func roots(of results: [UUID: PlacementResult]) -> [UUID: DecodedPattern] {
        results.compactMapValues { result in
            guard case .decoded(let root) = result else { return nil }
            return root
        }
    }

    private func visualize(_ node: DecodedPattern, root: DecodedPattern, placement: PatternPlacement) {
        if let visualizer = node.visualizer {
            let outcome: NodeVisualization.Outcome
            do {
                outcome = .ready(try PatternVisualization(visualizer, of: node, in: root))
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            visualizations[node.id] = NodeVisualization(
                placement: placement, nodeID: node.nodeID, presentation: visualizer.presentation, outcome: outcome)
        }
        for child in node.children {
            visualize(child, root: root, placement: placement)
        }
    }

    private func rebuildRows() {
        openPopover?.popdown()
        rows = visibleRows
        visualizerAnchors = [:]
        treeList.removeAll()
        for row in rows {
            treeList.append(child: makeRow(row))
        }
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }),
            let row = treeList.getRowAt(index: index)
        {
            isSelectingProgrammatically = true
            treeList.select(row: row)
            isSelectingProgrammatically = false
        }
    }

    private var visibleRows: [TreeRow] {
        var rows: [TreeRow] = []
        for placement in placements {
            guard case .decoded(let root) = results[placement.id] else {
                rows.append(TreeRow(id: placement.id, parent: nil, depth: 0, isExpandable: false, kind: .placement(placement)))
                continue
            }
            let children = root.visibleChildren
            rows.append(TreeRow(id: placement.id, parent: nil, depth: 0, isExpandable: !children.isEmpty, kind: .placement(placement)))
            if expanded.contains(placement.id) {
                appendRows(for: children, parent: placement.id, depth: 1, to: &rows)
            }
        }
        return rows
    }

    private func appendRows(for nodes: [DecodedPattern], parent: UUID, depth: Int, to rows: inout [TreeRow]) {
        for node in nodes {
            let children = node.visibleChildren
            rows.append(TreeRow(id: node.id, parent: parent, depth: depth, isExpandable: !children.isEmpty, kind: .node(node)))
            if expanded.contains(node.id) {
                appendRows(for: children, parent: node.id, depth: depth + 1, to: &rows)
            }
        }
    }

    private func makeRow(_ row: TreeRow) -> ListBoxRow {
        let content = Box(orientation: .horizontal, spacing: 6)
        content.marginStart = 4 + row.depth * 14
        content.marginEnd = 4
        content.append(child: makeChevron(for: row))
        switch row.kind {
        case .placement(let placement):
            fillPlacementRow(content, placement: placement)
        case .node(let node):
            fillNodeRow(content, node: node)
        }
        let listRow = ListBoxRow()
        listRow.set(child: content)
        listRow.add(cssClass: "luma-pattern-row")
        listRow.setSizeRequest(width: -1, height: Int(HexView.rowHeight.rounded(.up)))
        return listRow
    }

    private func makeChevron(for row: TreeRow) -> Button {
        let chevron = Button(iconName: expanded.contains(row.id) ? "pan-down-symbolic" : "pan-end-symbolic")
        chevron.add(cssClass: "flat")
        chevron.add(cssClass: "luma-pattern-chevron")
        chevron.opacity = row.isExpandable ? 1 : 0
        chevron.sensitive = row.isExpandable
        chevron.focusable = false
        let id = row.id
        chevron.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle(id) }
        }
        return chevron
    }

    private func fillPlacementRow(_ content: Box, placement: PatternPlacement) {
        content.append(child: Self.label(title(of: placement), classes: ["luma-pattern-name"]))
        content.append(child: Self.label(String(format: "@ 0x%llx", (baseAddress ?? 0) &+ UInt64(placement.offset)), classes: ["dim-label"]))
        if case .failed(let message) = results[placement.id] {
            let failure = Self.label(message, classes: ["error"])
            failure.ellipsize = .end
            failure.tooltipText = message
            content.append(child: failure)
        }
        content.append(child: Self.spacer())
        let remove = Button(iconName: "window-close-symbolic")
        remove.add(cssClass: "flat")
        remove.add(cssClass: "luma-pattern-chevron")
        remove.focusable = false
        let id = placement.id
        remove.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.remove(id) }
        }
        content.append(child: remove)
    }

    private func title(of placement: PatternPlacement) -> String {
        guard summaries[placement.sourceID]?.rootType == placement.typeName, let source = engine.patterns.source(withID: placement.sourceID)
        else { return placement.typeName }
        return source.name
    }

    private func fillNodeRow(_ content: Box, node: DecodedPattern) {
        if let location = locations[node.id] {
            content.append(child: Self.swatch(location.color))
        }
        content.append(child: Self.label(node.displayName ?? node.name, classes: ["luma-pattern-name"]))
        content.append(child: Self.label(node.typeName, classes: ["dim-label"]))
        content.append(child: Self.spacer())
        if let visualization = visualizations[node.id] {
            appendVisualization(visualization, of: node, to: content)
        } else {
            content.append(child: summary(of: node))
        }
        content.tooltipText = node.comment ?? String(format: "0x%llx", node.address)
    }

    private func appendVisualization(_ visualization: NodeVisualization, of node: DecodedPattern, to content: Box) {
        if let inline = visualization.inline {
            let widget = inline.make { [weak self] anchor in
                self?.press(visualization, anchor: anchor)
            }
            visualizerAnchors[node.id] = widget
            content.append(child: widget)
            return
        }
        content.append(child: summary(of: node))
        let button = Button(iconName: visualization.iconName)
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-pattern-chevron")
        button.focusable = false
        button.tooltipText = "Visualize"
        button.onClicked { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button else { return }
                self.presentVisualizer(visualization, anchor: button)
            }
        }
        visualizerAnchors[node.id] = button
        content.append(child: button)
    }

    private func summary(of node: DecodedPattern) -> Label {
        let value = Self.label(node.summary, classes: node.truncated ? ["error"] : [])
        value.ellipsize = .end
        return value
    }

    private static func label(_ text: String, classes: [String]) -> Label {
        let label = Label(str: text)
        label.xalign = 0
        label.add(cssClass: "monospace")
        label.add(cssClass: "luma-pattern-text")
        for name in classes {
            label.add(cssClass: name)
        }
        return label
    }

    private static func spacer() -> Box {
        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        return spacer
    }

    private static func swatch(_ color: GdkRGBA) -> DrawingArea {
        let swatch = DrawingArea()
        swatch.setSizeRequest(width: 8, height: 8)
        swatch.valign = .center
        swatch.setDrawFunc { _, ctx, width, height in
            MainActor.assumeIsolated {
                drawSwatch(color, on: ctx, width: Double(width), height: Double(height))
            }
        }
        return swatch
    }

    private static func drawSwatch(_ color: GdkRGBA, on ctx: Cairo.ContextRef, width: Double, height: Double) {
        let cr: UnsafeMutablePointer<cairo_t> = ctx._ptr
        let radius = 2.0
        cairo_new_sub_path(cr)
        cairo_arc(cr, width - radius, radius, radius, -.pi / 2, 0)
        cairo_arc(cr, width - radius, height - radius, radius, 0, .pi / 2)
        cairo_arc(cr, radius, height - radius, radius, .pi / 2, .pi)
        cairo_arc(cr, radius, radius, radius, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
        color.setSource(on: cr)
        cairo_fill(cr)
    }
}

private enum PlacementResult {
    case decoded(DecodedPattern)
    case failed(String)

    var isTruncated: Bool {
        guard case .decoded(let root) = self else { return false }
        return root.truncated
    }
}

private struct NodeVisualization {
    let placement: PatternPlacement
    let nodeID: UInt
    let presentation: DecodedVisualizer.Presentation
    let outcome: Outcome

    enum Outcome {
        case ready(PatternVisualization)
        case failed(String)
    }

    var inline: PatternInlineVisualization? {
        guard presentation == .inline, case .ready(let ready) = outcome else { return nil }
        return PatternInlineVisualization(ready)
    }

    var iconName: String {
        guard case .ready(let ready) = outcome else { return "dialog-warning-symbolic" }
        switch ready {
        case .image, .bitmap:
            return "image-x-generic-symbolic"
        case .sound:
            return "audio-x-generic-symbolic"
        case .timestamp:
            return "x-office-calendar-symbolic"
        case .coordinates:
            return "mark-location-symbolic"
        case .disassembly:
            return "utilities-terminal-symbolic"
        default:
            return "view-reveal-symbolic"
        }
    }
}

private struct TreeRow {
    let id: UUID
    let parent: UUID?
    let depth: Int
    let isExpandable: Bool
    let kind: Kind

    enum Kind {
        case placement(PatternPlacement)
        case node(DecodedPattern)
    }
}

extension PatternLocation {
    var color: GdkRGBA {
        PatternPalette.color(for: tint)
    }

    var annotation: HexAnnotation {
        HexAnnotation(id: node.id, range: range, color: color)
    }
}

enum PatternPalette {
    private static let colors: [GdkRGBA] = [
        GdkRGBA(red: 0.21, green: 0.52, blue: 0.89, alpha: 1),
        GdkRGBA(red: 0.2, green: 0.82, blue: 0.48, alpha: 1),
        GdkRGBA(red: 1, green: 0.47, blue: 0, alpha: 1),
        GdkRGBA(red: 0.57, green: 0.25, blue: 0.67, alpha: 1),
        GdkRGBA(red: 0.86, green: 0.54, blue: 0.87, alpha: 1),
        GdkRGBA(red: 0.13, green: 0.56, blue: 0.64, alpha: 1),
        GdkRGBA(red: 0.96, green: 0.83, blue: 0.18, alpha: 1),
        GdkRGBA(red: 0.88, green: 0.11, blue: 0.14, alpha: 1),
    ]

    static func color(for tint: PatternTint) -> GdkRGBA {
        switch tint {
        case .palette(let index):
            return colors[index % colors.count]
        case .rgb(let red, let green, let blue):
            return GdkRGBA(red: Float(red) / 255, green: Float(green) / 255, blue: Float(blue) / 255, alpha: 1)
        }
    }
}
