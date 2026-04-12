import CCairo
import CGraphene
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk
import LumaCore

struct NodeRegisterInfo {
    let stateBeforeBlock: RegisterState
    let stateAfterBlock: RegisterState
    let writes: [RegisterWrite]
}

@MainActor
final class ITraceCFGView {
    let widget: Box

    var onSelect: ((CFGGraph.NodeKey) -> Void)?
    var onNavigateFunction: ((Int) -> Void)?
    var onJumpToFunction: ((Int) -> Void)?

    private let decoded: DecodedITrace
    private let arch: String
    private let windowRadius: Int
    private let disasmProvider: ((UInt64, Int) async -> StyledText)?

    private var graph: CFGGraph = CFGGraph(nodes: [:], edges: [], entryKey: 0)
    private var nodeRegisterInfo: [CFGGraph.NodeKey: NodeRegisterInfo] = [:]
    private var windowStart: Int = 0
    private var selectedCallIndex: Int

    private let overlay: Overlay
    private let drawingArea: DrawingArea
    private let fixed: Fixed
    private let container: Box

    private var nodeWidgets: [CFGGraph.NodeKey: Box] = [:]
    private var nodeInstructionList: [CFGGraph.NodeKey: ListBox] = [:]
    private var nodeInstructionRows: [CFGGraph.NodeKey: [ListBoxRow]] = [:]
    private var suppressRowSelection = false
    private var nodeHeights: [CFGGraph.NodeKey: Double] = [:]
    private var selectedKey: CFGGraph.NodeKey?
    private var selectedInstructionLine: Int = 0
    private var registerPopover: Popover?
    private var registerPopoverScroll: ScrolledWindow?

    private var disasmCache: [UInt64: StyledText] = [:]
    private var disasmFetchTask: Task<Void, Never>?

    private var panX: Double = 0
    private var panY: Double = 0
    private var zoom: Double = 1.0

    private var offsetBaseX: Double = 0
    private var offsetBaseY: Double = 0

    private let nodeWidth: Double = 360
    private let baseNodeHeight: Double = 30
    private let padding: Double = 20

    init(
        decoded: DecodedITrace,
        arch: String,
        selectedCallIndex: Int,
        windowRadius: Int = 10,
        disasmProvider: ((UInt64, Int) async -> StyledText)?
    ) {
        self.decoded = decoded
        self.arch = arch
        self.selectedCallIndex = selectedCallIndex
        self.windowRadius = windowRadius
        self.disasmProvider = disasmProvider

        let root = Box(orientation: .vertical, spacing: 0)
        root.hexpand = true
        root.vexpand = true
        root.focusable = true
        self.container = root

        let overlayWidget = Overlay()
        overlayWidget.hexpand = true
        overlayWidget.vexpand = true
        self.overlay = overlayWidget

        let area = DrawingArea()
        area.hexpand = true
        area.vexpand = true
        self.drawingArea = area

        let fixedContainer = Fixed()
        fixedContainer.hexpand = true
        fixedContainer.vexpand = true
        self.fixed = fixedContainer

        overlayWidget.set(child: WidgetRef(area.widget_ptr))
        overlayWidget.addOverlay(widget: fixedContainer)

        root.append(child: overlayWidget)
        self.widget = root

        area.setDrawFunc { [weak self] _, ctx, _, _ in
            MainActor.assumeIsolated {
                self?.draw(ctx: ctx)
            }
        }

        installGestures()
        installKeyController()
        rebuildGraph(forCallIndex: selectedCallIndex)
    }

    // MARK: - Public API

    func setSelectedCall(index: Int) {
        guard index != selectedCallIndex else { return }
        selectedCallIndex = index
        rebuildGraph(forCallIndex: index)
        focus()
    }

    func setSelectedNode(key: CFGGraph.NodeKey?) {
        select(key: key, notify: false)
    }

    func focus() {
        if selectedKey == nil {
            let entryKey = graph.entryKey
            if graph.nodes[entryKey] != nil {
                select(key: entryKey, line: 0, notify: false)
            }
        }
        if let key = selectedKey, let node = graph.nodes[key] {
            panToNode(node)
        }
        _ = container.grabFocus()
    }

    func focusLast() {
        let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
        if let last = sorted.last {
            let line = max(0, (nodeInstructionRows[last.key]?.count ?? 1) - 1)
            select(key: last.key, line: line, notify: false)
            panToNode(last)
        }
        _ = container.grabFocus()
    }

    func invalidateDisasm() {
        disasmFetchTask?.cancel()
        disasmFetchTask = nil
        disasmCache.removeAll()
        fetchDisasmForNodes()
    }

    // MARK: - Graph build

    private func rebuildGraph(forCallIndex callIdx: Int) {
        disasmFetchTask?.cancel()
        disasmFetchTask = nil

        let calls = decoded.functionCalls
        guard !calls.isEmpty else {
            clearNodes()
            graph = CFGGraph(nodes: [:], edges: [], entryKey: 0)
            drawingArea.queueDraw()
            return
        }

        let lo = max(0, callIdx - windowRadius)
        let hi = min(calls.count, callIdx + windowRadius + 1)
        windowStart = lo

        var sections: [(entries: ArraySlice<TraceEntry>, section: Int)] = []
        for i in lo..<hi {
            let slice = decoded.entries[calls[i].startIndex..<calls[i].endIndex]
            sections.append((entries: slice, section: i))
        }

        graph = CFGGraph.buildAllFunctions(sections: sections, currentSection: callIdx)
        nodeRegisterInfo = Self.buildRegisterInfoMap(decoded: decoded, range: lo..<hi)

        clearNodes()
        buildNodeWidgets(currentSection: callIdx)
        relayout()
        fetchDisasmForNodes()
    }

    private static func buildRegisterInfoMap(
        decoded: DecodedITrace,
        range: Swift.Range<Int>
    ) -> [CFGGraph.NodeKey: NodeRegisterInfo] {
        var map: [CFGGraph.NodeKey: NodeRegisterInfo] = [:]
        for i in range {
            let call = decoded.functionCalls[i]
            for entryIdx in call.startIndex..<call.endIndex {
                guard entryIdx < decoded.registerStates.count else { continue }
                let key = CFGGraph.nodeKey(
                    address: decoded.entries[entryIdx].blockAddress, section: i)
                let stateBefore = entryIdx > 0
                    ? decoded.registerStates[entryIdx - 1]
                    : RegisterState(values: [:], changed: [])
                map[key] = NodeRegisterInfo(
                    stateBeforeBlock: stateBefore,
                    stateAfterBlock: decoded.registerStates[entryIdx],
                    writes: decoded.entries[entryIdx].registerWrites
                )
            }
        }
        return map
    }

    // MARK: - Node widgets

    private func clearNodes() {
        dismissRegisterPopover()
        for (_, box) in nodeWidgets {
            fixed.remove(widget: box)
        }
        nodeWidgets.removeAll(keepingCapacity: true)
        nodeInstructionList.removeAll(keepingCapacity: true)
        nodeInstructionRows.removeAll(keepingCapacity: true)
        nodeHeights.removeAll(keepingCapacity: true)
        selectedKey = nil
        selectedInstructionLine = 0
    }

    private func buildNodeWidgets(currentSection: Int) {
        for (key, node) in graph.nodes {
            let box = makeNodeBox(node: node, currentSection: currentSection)
            nodeWidgets[key] = box
            nodeHeights[key] = baseNodeHeight
            fixed.put(widget: box, x: 0, y: 0)
        }
    }

    private func makeNodeBox(node: CFGGraph.Node, currentSection: Int) -> Box {
        let box = Box(orientation: .vertical, spacing: 0)
        box.setSizeRequest(width: Int(nodeWidth), height: -1)
        box.add(cssClass: "luma-cfg-node")
        box.add(cssClass: "luma-cfg-section-\(node.section % 8)")
        if node.section == currentSection {
            box.add(cssClass: "luma-cfg-section-current")
        }
        box.halign = .start
        box.valign = .start

        let nameLabel = Label(str: shortName(node.name))
        nameLabel.halign = .start
        nameLabel.add(cssClass: "caption-heading")
        nameLabel.add(cssClass: "monospace")
        nameLabel.ellipsize = .end
        nameLabel.setSizeRequest(width: Int(nodeWidth) - 20, height: -1)
        nameLabel.marginBottom = 4
        box.append(child: nameLabel)

        let instructions = ListBox()
        instructions.selectionMode = .single
        instructions.add(cssClass: "luma-cfg-instr-list")
        instructions.hexpand = true
        let listKey = node.key
        instructions.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, !self.suppressRowSelection, let row else { return }
                let line = Int(row.index)
                self.selectLine(key: listKey, line: line, notify: true)
                _ = self.container.grabFocus()
            }
        }
        box.append(child: instructions)
        nodeInstructionList[node.key] = instructions

        return box
    }

    private func shortName(_ name: String) -> String {
        if let bang = name.firstIndex(of: "!") {
            return String(name[name.index(after: bang)...])
        }
        return name
    }

    // MARK: - Layout

    private func relayout() {
        let keys = graph.nodes
        graph.assignPositions { [nodeHeights, baseNodeHeight] key in
            nodeHeights[key] ?? baseNodeHeight
        }
        _ = keys

        let (minX, minY, _, _) = boundsOfGraph()
        offsetBaseX = padding - minX
        offsetBaseY = padding - minY

        repositionNodes()
        drawingArea.queueDraw()
    }

    private func boundsOfGraph() -> (Double, Double, Double, Double) {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for node in graph.nodes.values {
            let h = nodeHeights[node.key] ?? baseNodeHeight
            minX = min(minX, node.position.x - nodeWidth / 2)
            minY = min(minY, node.position.y - h / 2)
            maxX = max(maxX, node.position.x + nodeWidth / 2)
            maxY = max(maxY, node.position.y + h / 2)
        }
        if !minX.isFinite { return (0, 0, nodeWidth, baseNodeHeight) }
        return (minX, minY, maxX, maxY)
    }

    private func repositionNodes() {
        for (key, node) in graph.nodes {
            guard let box = nodeWidgets[key] else { continue }
            let h = nodeHeights[key] ?? baseNodeHeight
            let x = (node.position.x - nodeWidth / 2 + offsetBaseX) * zoom + panX
            let y = (node.position.y - h / 2 + offsetBaseY) * zoom + panY
            fixed.move(widget: box, x: CDouble(x), y: CDouble(y))
        }
    }

    // MARK: - Disasm fetch

    private func fetchDisasmForNodes() {
        guard let provider = disasmProvider else { return }
        var toFetch: [(CFGGraph.NodeKey, UInt64, Int)] = []
        for (key, node) in graph.nodes {
            if disasmCache[node.address] == nil {
                toFetch.append((key, node.address, node.size))
            } else {
                applyDisasm(key: key, styled: disasmCache[node.address]!, relayoutAfter: false)
            }
        }

        relayout()

        guard !toFetch.isEmpty else { return }

        disasmFetchTask = Task { @MainActor [weak self] in
            for (key, addr, size) in toFetch {
                if Task.isCancelled { return }
                guard let self else { return }
                if self.disasmCache[addr] == nil {
                    let styled = await provider(addr, size)
                    if Task.isCancelled { return }
                    self.disasmCache[addr] = styled
                }
                if let styled = self.disasmCache[addr] {
                    self.applyDisasm(key: key, styled: styled, relayoutAfter: false)
                }
            }
            if Task.isCancelled { return }
            self?.relayout()
        }
    }

    private func applyDisasm(key: CFGGraph.NodeKey, styled: StyledText, relayoutAfter: Bool) {
        guard let instrList = nodeInstructionList[key] else { return }

        suppressRowSelection = true
        defer { suppressRowSelection = false }

        while let row = instrList.firstChild {
            instrList.remove(child: row)
        }

        let lines = splitLines(styled)
        var rows: [ListBoxRow] = []
        rows.reserveCapacity(lines.count)
        for line in lines {
            let row = ListBoxRow()
            row.add(cssClass: "luma-cfg-instr")
            let label = Label(str: "")
            label.setMarkup(str: StyledTextPango.markup(for: line))
            label.halign = .start
            label.xalign = 0
            label.hexpand = true
            label.add(cssClass: "monospace")
            label.add(cssClass: "caption")
            label.ellipsize = .end
            label.marginStart = 4
            label.marginEnd = 4
            row.set(child: label)
            instrList.append(child: row)
            rows.append(row)
        }
        nodeInstructionRows[key] = rows

        if selectedKey == key {
            applyLineHighlight(key: key)
        }

        var natH: gint = 0
        nodeWidgets[key]?.measure(orientation: GTK_ORIENTATION_VERTICAL, for: -1, natural: &natH)
        let newHeight = natH > 0 ? Double(natH) : baseNodeHeight
        nodeHeights[key] = newHeight

        if relayoutAfter {
            relayout()
        }
    }

    private func applyLineHighlight(key: CFGGraph.NodeKey) {
        guard let list = nodeInstructionList[key],
            let rows = nodeInstructionRows[key],
            selectedInstructionLine >= 0,
            selectedInstructionLine < rows.count
        else { return }
        suppressRowSelection = true
        list.select(row: rows[selectedInstructionLine])
        suppressRowSelection = false
    }

    private func clearLineHighlight(key: CFGGraph.NodeKey) {
        guard let list = nodeInstructionList[key] else { return }
        suppressRowSelection = true
        list.unselectAll()
        suppressRowSelection = false
    }

    private func splitLines(_ styled: StyledText) -> [StyledText] {
        // StyledText has spans; build per-line subsets by splitting on "\n".
        var lines: [StyledText] = []
        var currentSpans: [StyledText.Span] = []
        for span in styled.spans {
            var remaining = span.text
            while let nl = remaining.firstIndex(of: "\n") {
                let head = String(remaining[..<nl])
                if !head.isEmpty {
                    currentSpans.append(
                        StyledText.Span(
                            text: head, foreground: span.foreground, isBold: span.isBold))
                }
                lines.append(StyledText(spans: currentSpans))
                currentSpans.removeAll(keepingCapacity: true)
                remaining = String(remaining[remaining.index(after: nl)...])
            }
            if !remaining.isEmpty {
                currentSpans.append(
                    StyledText.Span(
                        text: remaining, foreground: span.foreground, isBold: span.isBold))
            }
        }
        if !currentSpans.isEmpty {
            lines.append(StyledText(spans: currentSpans))
        }
        if lines.isEmpty {
            lines.append(StyledText(spans: []))
        }
        return lines
    }

    // MARK: - Selection

    private func select(key: CFGGraph.NodeKey?, line: Int = 0, notify: Bool) {
        if let prev = selectedKey, let prevBox = nodeWidgets[prev] {
            prevBox.remove(cssClass: "selected")
            clearLineHighlight(key: prev)
        }
        selectedKey = key
        selectedInstructionLine = line
        if let key, let box = nodeWidgets[key] {
            box.add(cssClass: "selected")
            applyLineHighlight(key: key)
        }
        drawingArea.queueDraw()
        if registerPopover != nil { updateRegisterPopover() }
        if notify, let key {
            onSelect?(key)
        }
        _ = container.grabFocus()
    }

    private func selectLine(key: CFGGraph.NodeKey, line: Int, notify: Bool) {
        if selectedKey == key {
            selectedInstructionLine = line
            applyLineHighlight(key: key)
            if registerPopover != nil { updateRegisterPopover() }
            return
        }
        select(key: key, line: line, notify: notify)
    }

    // MARK: - Drawing (edges)

    private func draw(ctx: Cairo.ContextRef) {
        cairo_save(ctx.context_ptr)
        cairo_translate(ctx.context_ptr, panX, panY)
        cairo_scale(ctx.context_ptr, zoom, zoom)

        for edge in graph.edges {
            guard
                let from = graph.nodes[edge.from],
                let to = graph.nodes[edge.to]
            else { continue }

            let fromH = nodeHeights[edge.from] ?? baseNodeHeight
            let toH = nodeHeights[edge.to] ?? baseNodeHeight

            let x1 = from.position.x + offsetBaseX
            let y1 = from.position.y + fromH / 2 + offsetBaseY
            let x2 = to.position.x + offsetBaseX
            let y2 = to.position.y - toH / 2 + offsetBaseY

            let width = min(8.0, max(1.0, log2(Double(edge.count) + 1)))
            ctx.lineWidth = width

            let highlighted: Bool = {
                guard let sel = selectedKey else { return false }
                return edge.from == sel || edge.to == sel
            }()

            if highlighted {
                ctx.setSource(red: 0.33, green: 0.55, blue: 0.93, alpha: 0.95)
            } else if edge.isCrossSection {
                ctx.setSource(red: 0.95, green: 0.65, blue: 0.2, alpha: 0.85)
            } else {
                ctx.setSource(red: 0.6, green: 0.6, blue: 0.62, alpha: 0.75)
            }

            if edge.isCrossSection {
                ctx.setDash([6.0, 4.0], offset: 0.0)
            } else {
                ctx.setDash([], offset: 0.0)
            }

            ctx.moveTo(x1, y1)
            ctx.lineTo(x2, y2)
            ctx.stroke()

            drawArrowHead(ctx: ctx, x1: x1, y1: y1, x2: x2, y2: y2, width: width)
        }

        cairo_restore(ctx.context_ptr)
    }

    private func drawArrowHead(
        ctx: Cairo.ContextRef,
        x1: Double, y1: Double, x2: Double, y2: Double, width: Double
    ) {
        let dx = x2 - x1
        let dy = y2 - y1
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0.001 else { return }
        let ux = dx / len
        let uy = dy / len
        let size = max(6.0, width * 2.5)
        let baseX = x2 - ux * size
        let baseY = y2 - uy * size
        let px = -uy
        let py = ux
        ctx.setDash([], offset: 0.0)
        ctx.moveTo(x2, y2)
        ctx.lineTo(baseX + px * size * 0.5, baseY + py * size * 0.5)
        ctx.lineTo(baseX - px * size * 0.5, baseY - py * size * 0.5)
        ctx.closePath()
        ctx.fill()
    }

    // MARK: - Gestures / Pan+Zoom

    private func installGestures() {
        let drag = GestureDrag()
        var lastX: Double = 0
        var lastY: Double = 0
        drag.onDragBegin { _, _, _ in
            MainActor.assumeIsolated {
                lastX = 0
                lastY = 0
            }
        }
        drag.onDragUpdate { [weak self] _, offX, offY in
            MainActor.assumeIsolated {
                guard let self else { return }
                let dx = offX - lastX
                let dy = offY - lastY
                lastX = offX
                lastY = offY
                self.panX += dx
                self.panY += dy
                self.repositionNodes()
                self.drawingArea.queueDraw()
            }
        }
        container.install(controller: drag)

        let scroll = EventControllerScroll(flags: .bothAxes)
        let motionForPos = EventControllerMotion()
        var lastMouseX: Double = 0
        var lastMouseY: Double = 0
        motionForPos.onMotion { _, x, y in
            MainActor.assumeIsolated {
                lastMouseX = x
                lastMouseY = y
            }
        }
        container.install(controller: motionForPos)

        scroll.onScroll { [weak self] controller, dx, dy in
            MainActor.assumeIsolated {
                guard let self else { return false }
                let state = controller.currentEventState
                let isCtrl = state.contains(.controlMask)
                if isCtrl {
                    let oldZoom = self.zoom
                    let factor = 1.0 - dy * 0.1
                    var newZoom = oldZoom * factor
                    newZoom = max(0.25, min(4.0, newZoom))
                    let worldX = (lastMouseX - self.panX) / oldZoom
                    let worldY = (lastMouseY - self.panY) / oldZoom
                    self.zoom = newZoom
                    self.panX = lastMouseX - worldX * newZoom
                    self.panY = lastMouseY - worldY * newZoom
                } else {
                    // SURFACE unit (trackpads) reports per-event pixel deltas;
                    // WHEEL unit reports discrete ticks that need to be scaled
                    // up to feel like normal scrolling.
                    let multiplier = controller.unit == GDK_SCROLL_UNIT_WHEEL ? 30.0 : 1.0
                    self.panX -= dx * multiplier
                    self.panY -= dy * multiplier
                }
                self.repositionNodes()
                self.drawingArea.queueDraw()
                return true
            }
        }
        container.install(controller: scroll)
    }

    private func panToNode(_ node: CFGGraph.Node) {
        let h = nodeHeights[node.key] ?? baseNodeHeight
        let nodeCX = (node.position.x + offsetBaseX) * zoom + panX
        let nodeCY = (node.position.y + offsetBaseY) * zoom + panY
        let halfW = nodeWidth / 2 * zoom
        let halfH = h / 2 * zoom
        let viewW = Double(container.allocatedWidth)
        let viewH = Double(container.allocatedHeight)
        guard viewW > 0, viewH > 0 else { return }

        // Keep the node within the central portion of the viewport
        let insetX = min(viewW * 0.15, 60)
        let insetY = min(viewH * 0.15, 60)
        var dx = 0.0
        var dy = 0.0

        if nodeCX - halfW < insetX {
            dx = insetX - (nodeCX - halfW)
        } else if nodeCX + halfW > viewW - insetX {
            dx = (viewW - insetX) - (nodeCX + halfW)
        }

        if nodeCY - halfH < insetY {
            dy = insetY - (nodeCY - halfH)
        } else if nodeCY + halfH > viewH - insetY {
            dy = (viewH - insetY) - (nodeCY + halfH)
        }

        if dx != 0 || dy != 0 {
            panX += dx
            panY += dy
            repositionNodes()
            drawingArea.queueDraw()
        }
    }



    // MARK: - Keyboard

    private func installKeyController() {
        let key = EventControllerKey()
        key.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return false }
                switch keyval {
                case 0xff51, 0x068:  // Left, h
                    self.onNavigateFunction?(-1); return true
                case 0xff53, 0x06c:  // Right, l
                    self.onNavigateFunction?(1); return true
                case 0xff52, 0x06b:  // Up, k
                    self.moveLine(by: -1); return true
                case 0xff54, 0x06a:  // Down, j
                    self.moveLine(by: 1); return true
                case 0x04a:  // J — jump to next block
                    self.jumpToBlock(direction: 1); return true
                case 0x04b:  // K — jump to previous block
                    self.jumpToBlock(direction: -1); return true
                case 0x067, 0xff50:  // g, Home
                    self.jumpToFirst(); return true
                case 0x047, 0xff57:  // G, End
                    self.jumpToLast(); return true
                case 0xff55:  // Page Up
                    self.jumpToBlock(direction: -1); return true
                case 0xff56:  // Page Down
                    self.jumpToBlock(direction: 1); return true
                case 0xff0d:
                    self.toggleRegisterPopover()
                    return true
                case 0xff1b:
                    if self.registerPopover != nil {
                        self.dismissRegisterPopover()
                    } else {
                        self.select(key: nil, notify: false)
                    }
                    return true
                default:
                    return false
                }
            }
        }
        container.install(controller: key)
    }

    private func jumpToFirst() {
        onJumpToFunction?(0)
        let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
        if let first = sorted.first {
            select(key: first.key, line: 0, notify: true)
            panToNode(first)
        }
    }

    private func jumpToLast() {
        onJumpToFunction?(-1)
        let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
        if let last = sorted.last {
            let line = max(0, (nodeInstructionRows[last.key]?.count ?? 1) - 1)
            select(key: last.key, line: line, notify: true)
            panToNode(last)
        }
    }

    private func jumpToBlock(direction: Int) {
        let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
        selectNextIn(sorted, direction: direction)
    }


    private func moveLine(by delta: Int) {
        guard !graph.nodes.isEmpty else { return }
        let hadPopover = registerPopover != nil
        guard let currentKey = selectedKey,
            let rows = nodeInstructionRows[currentKey],
            !rows.isEmpty
        else {
            let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
            selectNextIn(sorted, direction: delta > 0 ? 1 : -1)
            if hadPopover { showRegisterPopover() }
            return
        }
        let target = selectedInstructionLine + delta
        if target >= 0, target < rows.count {
            selectLine(key: currentKey, line: target, notify: false)
            return
        }
        let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
        selectNextIn(sorted, direction: delta > 0 ? 1 : -1)
        if hadPopover { showRegisterPopover() }
    }

    private func currentSectionNodes() -> [CFGGraph.Node] {
        let section: Int
        if let key = selectedKey, let node = graph.nodes[key] {
            section = node.section
        } else {
            section = selectedCallIndex
        }
        let current = graph.nodes.values.filter { $0.section == section }
        return current.isEmpty ? Array(graph.nodes.values) : current
    }

    private func selectNextIn(_ sorted: [CFGGraph.Node], direction: Int) {
        guard !sorted.isEmpty else { return }
        let currentIdx = sorted.firstIndex { $0.key == selectedKey }
        let nextIdx: Int
        if let currentIdx {
            let candidate = currentIdx + direction
            if candidate < 0 || candidate >= sorted.count {
                onNavigateFunction?(direction)
                if direction < 0 { focusLast() }
                return
            }
            nextIdx = candidate
        } else {
            nextIdx = direction > 0 ? 0 : sorted.count - 1
        }
        let node = sorted[nextIdx]
        let line = direction > 0 ? 0 : max(0, (nodeInstructionRows[node.key]?.count ?? 1) - 1)
        select(key: node.key, line: line, notify: true)
        panToNode(node)
    }

    // MARK: - Register popover

    private func toggleRegisterPopover() {
        if registerPopover != nil {
            dismissRegisterPopover()
        } else {
            showRegisterPopover()
        }
    }

    private static let registerPopoverChrome = 32
    private static let registerPopoverMargin = 16
    private static let registerPopoverMinWidth = 260
    private static let registerPopoverMinHeight = 180

    private func showRegisterPopover() {
        guard let key = selectedKey,
            let node = graph.nodes[key],
            nodeRegisterInfo[key] != nil,
            let anchor = nodeWidgets[key]
        else { return }

        dismissRegisterPopover()

        let inner = buildRegisterContent(for: key)
        let natural = naturalSize(of: inner)
        ensureRoomForRegisterPopover(node: node, contentWidth: natural.width)

        let scroll = ScrolledWindow()
        scroll.setPolicy(
            hscrollbarPolicy: PolicyType.automatic,
            vscrollbarPolicy: PolicyType.automatic
        )
        scroll.add(cssClass: "luma-popover-scroll")
        scroll.set(child: inner)
        applyScrollSize(scroll: scroll, node: node, contentSize: natural)

        let pop = Popover()
        pop.autohide = false
        pop.canFocus = false
        pop.position = .right
        pop.set(child: WidgetRef(scroll.widget_ptr))
        pop.set(parent: anchor)
        applyPopoverPointingTo(popover: pop, anchor: anchor)
        pop.popup()
        registerPopover = pop
        registerPopoverScroll = scroll
    }

    private func updateRegisterPopover() {
        guard let pop = registerPopover, let key = selectedKey,
            let node = graph.nodes[key],
            let anchor = nodeWidgets[key],
            nodeRegisterInfo[key] != nil
        else { return }
        let inner = buildRegisterContent(for: key)
        let natural = naturalSize(of: inner)
        registerPopoverScroll?.set(child: inner)
        registerPopoverScroll.flatMap {
            applyScrollSize(scroll: $0, node: node, contentSize: natural)
        }
        applyPopoverPointingTo(popover: pop, anchor: anchor)
    }

    private func naturalSize(of widget: Box) -> (width: Int, height: Int) {
        var natW: gint = 0
        var natH: gint = 0
        widget.measure(orientation: GTK_ORIENTATION_HORIZONTAL, for: -1, natural: &natW)
        widget.measure(orientation: GTK_ORIENTATION_VERTICAL, for: Int(natW), natural: &natH)
        return (Int(natW), Int(natH))
    }

    private func applyScrollSize(
        scroll: ScrolledWindow,
        node: CFGGraph.Node,
        contentSize: (width: Int, height: Int)
    ) {
        let avail = availableSizeRightOf(node: node)
        let width = min(contentSize.width, avail.width)
        let height = min(contentSize.height, avail.height)
        scroll.setSizeRequest(
            width: max(Self.registerPopoverMinWidth, width),
            height: max(Self.registerPopoverMinHeight, height)
        )
    }

    /// Right edge of `node` in the CFG container's coordinate system, computed
    /// from our internal pan/zoom state. Using this instead of
    /// `gtk_widget_compute_bounds` matters because compute_bounds returns the
    /// allocation from the *previous* layout pass, so a fresh `ensureRoom…`
    /// call won't see the panning we just applied.
    private func nodeRightInContainer(_ node: CFGGraph.Node) -> Double {
        return (node.position.x + nodeWidth / 2 + offsetBaseX) * zoom + panX
    }

    private func availableSizeRightOf(node: CFGGraph.Node) -> (width: Int, height: Int) {
        let chrome = Double(Self.registerPopoverChrome)
        let margin = Double(Self.registerPopoverMargin)
        var width = Self.registerPopoverMinWidth
        var height = Self.registerPopoverMinHeight
        let containerW = Double(container.allocatedWidth)
        let containerH = Double(container.allocatedHeight)
        if containerW > 0 {
            let nodeRight = nodeRightInContainer(node)
            let availW = containerW - nodeRight - chrome - margin
            width = max(Self.registerPopoverMinWidth, Int(availW))
        }
        if containerH > 0 {
            let availH = containerH - 2 * margin
            height = max(Self.registerPopoverMinHeight, Int(availH))
        }
        return (width, height)
    }

    private func ensureRoomForRegisterPopover(node: CFGGraph.Node, contentWidth: Int) {
        let containerW = Double(container.allocatedWidth)
        guard containerW > 0 else { return }
        let nodeRight = nodeRightInContainer(node)
        let chrome = Double(Self.registerPopoverChrome)
        let margin = Double(Self.registerPopoverMargin)
        let needed = Double(contentWidth) + chrome + margin
        let available = containerW - nodeRight
        if available < needed {
            panX -= (needed - available)
            repositionNodes()
            drawingArea.queueDraw()
        }
    }

    private func applyPopoverPointingTo(popover: Popover, anchor: Box) {
        // Pin to the node's vertical center so the popover stays put while
        // the user navigates instructions inside the same block. The arrow
        // ends up at the node's middle; the contents update to reflect the
        // selected instruction.
        let anchorWidth = anchor.allocatedWidth
        let anchorHeight = anchor.allocatedHeight
        guard anchorWidth > 0, anchorHeight > 0 else { return }
        var rect = GdkRectangle(
            x: gint(anchorWidth - 1),
            y: gint(anchorHeight / 2),
            width: 1,
            height: 1
        )
        withUnsafeMutablePointer(to: &rect) { ptr in
            gtk_popover_set_pointing_to(popover.popover_ptr, ptr)
        }
    }

    private func dismissRegisterPopover() {
        registerPopover?.popdown()
        registerPopover = nil
        registerPopoverScroll = nil
    }

    private func buildRegisterContent(for key: CFGGraph.NodeKey) -> Box {
        let info = nodeRegisterInfo[key]!

        let instrOffset = selectedInstructionLine * 4
        // The trace is a delta-encoded log of register writes, so very early
        // entries only have a handful of registers in their cumulative state.
        // Start from the most-complete snapshot we have (the trace's final
        // accumulated state), then override layer by layer with progressively
        // more accurate information so registers we *do* know about for this
        // instruction are correct, and the rest are at least populated.
        var values: [Int: UInt64] = decoded.registerStates.last?.values ?? [:]
        for (idx, val) in info.stateAfterBlock.values {
            values[idx] = val
        }
        for (idx, val) in info.stateBeforeBlock.values {
            values[idx] = val
        }
        var changed = Set<Int>()
        for write in info.writes where write.blockOffset <= instrOffset {
            values[write.registerIndex] = write.value
            if write.blockOffset == instrOffset {
                changed.insert(write.registerIndex)
            }
        }

        var nameToIdx: [String: Int] = [:]
        for (i, name) in decoded.registerNames.enumerated() {
            nameToIdx[name] = i
        }
        let layout = registerLayout(nameToIdx: nameToIdx, values: values)

        let outer = Box(orientation: .vertical, spacing: 4)
        outer.marginStart = 10
        outer.marginEnd = 10
        outer.marginTop = 8
        outer.marginBottom = 8

        appendRegisterRows(layout.gpr, into: outer, changed: changed)
        if !layout.vec.isEmpty {
            let separator = Separator(orientation: .horizontal)
            separator.marginTop = 4
            separator.marginBottom = 4
            outer.append(child: separator)
            appendRegisterRows(layout.vec, into: outer, changed: changed)
        }
        return outer
    }

    private func appendRegisterRows(
        _ rows: [[RegEntry]],
        into container: Box,
        changed: Set<Int>
    ) {
        for row in rows {
            let rowBox = Box(orientation: .horizontal, spacing: 12)
            for entry in row {
                let padded = entry.name.padding(toLength: 4, withPad: " ", startingAt: 0)
                let valueText = String(format: "0x%016llx", entry.value)
                let cell = Label(str: "\(padded): \(valueText)")
                cell.add(cssClass: "monospace")
                if changed.contains(entry.index) {
                    cell.add(cssClass: "luma-cfg-reg-changed")
                }
                cell.xalign = 0
                rowBox.append(child: cell)
            }
            container.append(child: rowBox)
        }
    }

    private struct RegEntry {
        let index: Int
        let name: String
        let value: UInt64
    }

    private struct RegisterLayout {
        let gpr: [[RegEntry]]
        let vec: [[RegEntry]]
    }

    private func registerLayout(
        nameToIdx: [String: Int],
        values: [Int: UInt64]
    ) -> RegisterLayout {
        func entry(_ name: String) -> RegEntry? {
            guard let idx = nameToIdx[name], let val = values[idx] else { return nil }
            return RegEntry(index: idx, name: name, value: val)
        }

        if arch == "arm64" {
            let arm64GPROrder: [[String]] = [
                ["x0", "x1", "x2", "x3"],
                ["x4", "x5", "x6", "x7"],
                ["x8", "x9", "x10", "x11"],
                ["x12", "x13", "x14", "x15"],
                ["x16", "x17", "x18", "x19"],
                ["x20", "x21", "x22", "x23"],
                ["x24", "x25", "x26", "x27"],
                ["x28", "fp", "lr"],
                ["sp", "pc", "nzcv"],
            ]
            let gpr = arm64GPROrder.compactMap { names -> [RegEntry]? in
                let row = names.compactMap { entry($0) }
                return row.isEmpty ? nil : row
            }

            var vec: [[RegEntry]] = []
            var vecRow: [RegEntry] = []
            for i in 0...31 {
                if let e = entry("v\(i)") {
                    vecRow.append(e)
                    if vecRow.count == 4 {
                        vec.append(vecRow)
                        vecRow.removeAll()
                    }
                }
            }
            if !vecRow.isEmpty { vec.append(vecRow) }

            return RegisterLayout(gpr: gpr, vec: vec)
        }

        let sorted = values.keys.sorted()
        var gpr: [[RegEntry]] = []
        var row: [RegEntry] = []
        for idx in sorted {
            guard idx < decoded.registerNames.count else { continue }
            row.append(RegEntry(index: idx, name: decoded.registerNames[idx], value: values[idx]!))
            if row.count == 4 {
                gpr.append(row)
                row.removeAll()
            }
        }
        if !row.isEmpty { gpr.append(row) }

        return RegisterLayout(gpr: gpr, vec: [])
    }
}
