import CCairo
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

    private let decoded: DecodedITrace
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
    private var nodeInstructionBox: [CFGGraph.NodeKey: Box] = [:]
    private var nodeHeights: [CFGGraph.NodeKey: Double] = [:]
    private var selectedKey: CFGGraph.NodeKey?

    private var disasmCache: [UInt64: StyledText] = [:]
    private var disasmFetchTask: Task<Void, Never>?

    private var panX: Double = 0
    private var panY: Double = 0
    private var zoom: Double = 1.0

    private var offsetBaseX: Double = 0
    private var offsetBaseY: Double = 0

    private var hoverPopover: Popover?
    private var hoverKey: CFGGraph.NodeKey?
    private var hoverDelayTask: Task<Void, Never>?

    private let nodeWidth: Double = 360
    private let baseNodeHeight: Double = 40
    private let instructionLineHeight: Double = 14
    private let titleRowHeight: Double = 22
    private let padding: Double = 40

    init(
        decoded: DecodedITrace,
        selectedCallIndex: Int,
        windowRadius: Int = 10,
        disasmProvider: ((UInt64, Int) async -> StyledText)?
    ) {
        self.decoded = decoded
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

        let resetButton = Button(label: "Reset view")
        resetButton.halign = .end
        resetButton.valign = .start
        resetButton.marginTop = 6
        resetButton.marginEnd = 6
        resetButton.add(cssClass: "osd")
        overlayWidget.addOverlay(widget: resetButton)

        root.append(child: overlayWidget)
        self.widget = root

        resetButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetView()
            }
        }

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
    }

    func setSelectedNode(key: CFGGraph.NodeKey?) {
        select(key: key, notify: false)
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
        for (_, box) in nodeWidgets {
            fixed.remove(widget: box)
        }
        nodeWidgets.removeAll(keepingCapacity: true)
        nodeInstructionBox.removeAll(keepingCapacity: true)
        nodeHeights.removeAll(keepingCapacity: true)
        selectedKey = nil
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
        box.append(child: nameLabel)

        let visitLabel = Label(str: "\(node.visitCount)\u{00D7}")
        visitLabel.halign = .start
        visitLabel.add(cssClass: "dim-label")
        visitLabel.add(cssClass: "caption")
        box.append(child: visitLabel)

        if let diff = registerDiffText(for: node.key) {
            let regLabel = Label(str: diff)
            regLabel.halign = .start
            regLabel.add(cssClass: "caption")
            regLabel.add(cssClass: "monospace")
            regLabel.add(cssClass: "luma-cfg-regdiff")
            regLabel.ellipsize = .end
            regLabel.setSizeRequest(width: Int(nodeWidth) - 20, height: -1)
            box.append(child: regLabel)
        }

        let instructions = Box(orientation: .vertical, spacing: 0)
        instructions.halign = .start
        box.append(child: instructions)
        nodeInstructionBox[node.key] = instructions

        let click = GestureClick()
        click.button = 1
        let key = node.key
        click.onPressed { [weak self] _, _, _, _ in
            MainActor.assumeIsolated {
                self?.select(key: key, notify: true)
                _ = self?.container.grabFocus()
            }
        }
        box.add(controller: click)

        let motion = EventControllerMotion()
        motion.onEnter { [weak self] _, _, _ in
            MainActor.assumeIsolated {
                self?.scheduleHover(key: key)
            }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelHover(key: key)
            }
        }
        box.add(controller: motion)

        return box
    }

    private func registerDiffText(for key: CFGGraph.NodeKey) -> String? {
        guard let info = nodeRegisterInfo[key] else { return nil }
        if info.writes.isEmpty {
            return nil
        }
        let parts = info.writes.prefix(2).map {
            String(format: "%@=0x%llx", $0.registerName, $0.value)
        }
        return parts.joined(separator: " ")
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

        let (minX, minY, maxX, maxY) = boundsOfGraph()
        offsetBaseX = padding - minX
        offsetBaseY = padding - minY

        let contentW = Int((maxX - minX) + 2 * padding)
        let contentH = Int((maxY - minY) + 2 * padding)
        drawingArea.contentWidth = contentW
        drawingArea.contentHeight = contentH
        fixed.setSizeRequest(width: contentW, height: contentH)
        overlay.setSizeRequest(width: contentW, height: contentH)

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

        guard !toFetch.isEmpty else {
            relayout()
            return
        }

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
        guard let instrBox = nodeInstructionBox[key] else { return }

        var child = instrBox.firstChild
        while let current = child {
            child = current.nextSibling
            instrBox.remove(child: current)
        }

        let lines = splitLines(styled)
        for line in lines {
            let label = Label(str: "")
            label.setMarkup(str: StyledTextPango.markup(for: line))
            label.halign = .start
            label.add(cssClass: "monospace")
            label.add(cssClass: "caption")
            label.add(cssClass: "luma-cfg-instr")
            label.ellipsize = .end
            label.setSizeRequest(width: Int(nodeWidth) - 16, height: -1)
            instrBox.append(child: label)
        }

        let lineCount = max(1, lines.count)
        let newHeight =
            titleRowHeight
            + (registerDiffText(for: key) != nil ? 16 : 0)
            + 16 /* visit row */
            + Double(lineCount) * instructionLineHeight
            + 10
        nodeHeights[key] = newHeight

        if relayoutAfter {
            relayout()
        }
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

    private func select(key: CFGGraph.NodeKey?, notify: Bool) {
        if let prev = selectedKey, let prevBox = nodeWidgets[prev] {
            prevBox.remove(cssClass: "selected")
        }
        selectedKey = key
        if let key, let box = nodeWidgets[key] {
            box.add(cssClass: "selected")
        }
        drawingArea.queueDraw()
        if notify, let key {
            onSelect?(key)
        }
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
        container.add(controller: drag)

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
        container.add(controller: motionForPos)

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
                    // Anchor under cursor: worldX = (mx - panX) / oldZoom; keep worldX
                    // at the same screen point after zoom: newPanX = mx - worldX * newZoom.
                    let worldX = (lastMouseX - self.panX) / oldZoom
                    let worldY = (lastMouseY - self.panY) / oldZoom
                    self.zoom = newZoom
                    self.panX = lastMouseX - worldX * newZoom
                    self.panY = lastMouseY - worldY * newZoom
                } else {
                    self.panX -= dx * 30
                    self.panY -= dy * 30
                }
                self.repositionNodes()
                self.drawingArea.queueDraw()
                return true
            }
        }
        container.add(controller: scroll)
    }

    private func resetView() {
        panX = 0
        panY = 0
        zoom = 1.0
        repositionNodes()
        drawingArea.queueDraw()
    }

    // MARK: - Hover popover

    private func scheduleHover(key: CFGGraph.NodeKey) {
        if hoverKey == key { return }
        hoverKey = key
        hoverDelayTask?.cancel()
        hoverDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            guard let self, self.hoverKey == key else { return }
            self.showHoverPopover(key: key)
        }
    }

    private func cancelHover(key: CFGGraph.NodeKey) {
        if hoverKey == key {
            hoverKey = nil
            hoverDelayTask?.cancel()
            hoverDelayTask = nil
            hoverPopover?.popdown()
        }
    }

    private func showHoverPopover(key: CFGGraph.NodeKey) {
        guard let node = graph.nodes[key], let anchor = nodeWidgets[key] else { return }
        hoverPopover?.popdown()

        let pop = Popover()
        pop.autohide = false
        pop.canFocus = false

        let content = Box(orientation: .vertical, spacing: 2)
        content.marginStart = 8
        content.marginEnd = 8
        content.marginTop = 6
        content.marginBottom = 6

        let name = Label(str: node.name)
        name.halign = .start
        name.add(cssClass: "heading")
        name.add(cssClass: "monospace")
        content.append(child: name)

        let meta = Label(
            str: String(
                format: "0x%llx · %d bytes · %d visits",
                node.address, node.size, node.visitCount))
        meta.halign = .start
        meta.add(cssClass: "dim-label")
        meta.add(cssClass: "caption")
        content.append(child: meta)

        if let info = nodeRegisterInfo[key], !info.writes.isEmpty {
            let hdr = Label(str: "Register writes")
            hdr.halign = .start
            hdr.add(cssClass: "caption-heading")
            content.append(child: hdr)
            for w in info.writes.prefix(3) {
                let l = Label(str: String(format: "  %@ = 0x%llx", w.registerName, w.value))
                l.halign = .start
                l.add(cssClass: "monospace")
                l.add(cssClass: "caption")
                content.append(child: l)
            }
        }

        pop.set(child: WidgetRef(content.widget_ptr))
        pop.set(parent: anchor)
        pop.popup()
        hoverPopover = pop
    }

    // MARK: - Keyboard

    private func installKeyController() {
        let key = EventControllerKey()
        key.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return false }
                switch keyval {
                case 0xff51: self.moveSelection(dx: -1, dy: 0); return true
                case 0xff53: self.moveSelection(dx: 1, dy: 0); return true
                case 0xff52: self.moveSelection(dx: 0, dy: -1); return true
                case 0xff54: self.moveSelection(dx: 0, dy: 1); return true
                case 0xff0d:
                    if let k = self.selectedKey { self.onSelect?(k) }
                    return true
                case 0xff1b:
                    self.select(key: nil, notify: false)
                    return true
                default:
                    return false
                }
            }
        }
        container.add(controller: key)
    }

    private func moveSelection(dx: Int, dy: Int) {
        guard !graph.nodes.isEmpty else { return }
        guard let current = selectedKey.flatMap({ graph.nodes[$0] }) else {
            if let first = graph.nodes.values.min(by: { $0.position.y < $1.position.y }) {
                select(key: first.key, notify: true)
            }
            return
        }

        var best: CFGGraph.Node?
        var bestScore = Double.infinity
        for node in graph.nodes.values where node.key != current.key {
            let ddx = node.position.x - current.position.x
            let ddy = node.position.y - current.position.y
            if dx != 0 {
                if (dx > 0 && ddx <= 0) || (dx < 0 && ddx >= 0) { continue }
            }
            if dy != 0 {
                if (dy > 0 && ddy <= 0) || (dy < 0 && ddy >= 0) { continue }
            }
            let score = ddx * ddx + ddy * ddy
            if score < bestScore {
                bestScore = score
                best = node
            }
        }
        if let best {
            select(key: best.key, notify: true)
        }
    }
}
