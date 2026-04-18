import Adw
import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class InsightDetailView {
    static var copyFeedback: ((String) -> Void)?

    let widget: Box

    private weak var engine: Engine?
    private weak var owner: MainWindow?
    private let sessionID: UUID
    private var session: LumaCore.ProcessSession
    private var insight: LumaCore.AddressInsight

    private let bannerSlot: Box
    private var currentBanner: Widget?

    private let contentOverlay: Overlay
    private let contentHost: Box
    private let spinnerHost: Box
    private let spinner: Adw.Spinner
    private var spinnerTask: Task<Void, Never>?

    private let disasmHost: Box
    private let disasmScroll: ScrolledWindow
    private let disasmContentOverlay: Overlay
    private let disasmBox: Box
    private let flowArea: DrawingArea
    private var hexView: HexView?

    private var disasmLines: [DisassemblyLine] = []
    private var disasmRows: [Box] = []
    private var selectedIndex: Int? = nil
    private var hoveredIndex: Int? = nil
    private var pulsingIndex: Int? = nil
    private var pulseTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var refreshDebounce: Task<Void, Never>?
    private var isLoadingMore = false
    private var isDarkMode = false
    private var themeSignalID: gulong = 0
    private var valueChangedHandler: gulong = 0
    private var lastNodeAvailable: Bool = false

    private static let initialChunk = 64
    private static let moreChunk = 64
    private static let rowLeftGutter: Double = 54
    private static let flowEntryX: Double = 48
    private static let flowBaseX: Double = 12
    private static let flowLaneSpacing: Double = 6

    init(engine: Engine, session: LumaCore.ProcessSession, insight: LumaCore.AddressInsight, owner: MainWindow?) {
        self.engine = engine
        self.owner = owner
        self.sessionID = session.id
        self.session = session
        self.insight = insight

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        bannerSlot = Box(orientation: .vertical, spacing: 0)
        bannerSlot.hexpand = true
        widget.append(child: bannerSlot)

        contentOverlay = Overlay()
        contentOverlay.hexpand = true
        contentOverlay.vexpand = true
        widget.append(child: contentOverlay)

        contentHost = Box(orientation: .vertical, spacing: 0)
        contentHost.hexpand = true
        contentHost.vexpand = true
        contentHost.marginStart = 8
        contentHost.marginEnd = 8
        contentHost.marginTop = 8
        contentHost.marginBottom = 8
        contentOverlay.set(child: contentHost)

        spinner = Adw.Spinner()

        spinnerHost = Box(orientation: .horizontal, spacing: 0)
        spinnerHost.add(cssClass: "luma-loading-capsule")
        spinnerHost.halign = .center
        spinnerHost.valign = .center
        spinnerHost.marginTop = 16
        spinnerHost.marginBottom = 16
        spinnerHost.marginStart = 16
        spinnerHost.marginEnd = 16
        spinnerHost.append(child: spinner)
        spinnerHost.visible = false
        contentOverlay.addOverlay(widget: spinnerHost)

        disasmHost = Box(orientation: .vertical, spacing: 0)
        disasmHost.hexpand = true
        disasmHost.vexpand = true

        disasmScroll = ScrolledWindow()
        disasmScroll.hexpand = true
        disasmScroll.vexpand = true

        disasmContentOverlay = Overlay()
        disasmContentOverlay.hexpand = true
        disasmContentOverlay.vexpand = true

        disasmBox = Box(orientation: .vertical, spacing: 0)
        disasmBox.focusable = true
        disasmBox.hexpand = true
        disasmBox.vexpand = false
        disasmBox.halign = .start
        disasmContentOverlay.set(child: disasmBox)

        flowArea = DrawingArea()
        flowArea.hexpand = true
        flowArea.vexpand = true
        flowArea.canTarget = false
        flowArea.setDrawFunc { [weak self] _, ctx, _, _ in
            MainActor.assumeIsolated { self?.drawFlow(ctx: ctx) }
        }
        disasmContentOverlay.addOverlay(widget: flowArea)

        disasmScroll.set(child: disasmContentOverlay)
        disasmHost.append(child: disasmScroll)

        let keyController = EventControllerKey()
        keyController.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                self?.handleDisasmKey(keyval: keyval) ?? false
            }
        }
        disasmBox.install(controller: keyController)

        if let vadj = disasmScroll.vadjustment {
            vadj.onValueChanged { [weak self] adj in
                MainActor.assumeIsolated {
                    self?.handleScroll(adj: adj)
                }
            }
        }

        isDarkMode = ThemeWatcher.isDarkMode()
        themeSignalID = ThemeWatcher.subscribe(owner: self) { view in
            view.handleThemeChanged()
        }

        applySessionState()
        scheduleRefresh()
    }

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeSignalID)
    }

    // MARK: - Session banner

    func applySessionState() {
        guard let engine else { return }
        guard let current = engine.sessions.first(where: { $0.id == sessionID }) else { return }
        session = current

        if let existing = currentBanner {
            clearFocusIfInside(existing)
            bannerSlot.remove(child: existing)
            currentBanner = nil
        }
        if SessionDetachedBanner.shouldShow(for: current) {
            let banner = SessionDetachedBanner.make(for: current) { [weak self] in
                self?.owner?.reestablishSession(id: current.id)
            }
            bannerSlot.append(child: banner)
            currentBanner = banner
        }

        let nodeAvailable = engine.node(forSessionID: sessionID) != nil
        if nodeAvailable && !lastNodeAvailable {
            scheduleRefresh()
        }
        lastNodeAvailable = nodeAvailable
    }

    private func clearFocusIfInside<W: WidgetProtocol>(_ subtree: W) {
        guard let root = subtree.root else { return }
        guard let focused = root.focus else { return }
        if focused.widget_ptr == subtree.widget_ptr || focused.is_(ancestor: subtree) {
            root.focus = nil
        }
    }

    // MARK: - Content swap

    private func setContent(_ child: Widget) {
        var c = contentHost.firstChild
        while let cur = c {
            c = cur.nextSibling
            clearFocusIfInside(cur)
            contentHost.remove(child: cur)
        }
        contentHost.append(child: child)
    }

    private func showErrorLabel(_ text: String) {
        let label = Label(str: text)
        label.add(cssClass: "monospace")
        label.halign = .start
        label.valign = .start
        label.wrap = true
        label.selectable = true
        setContent(label)
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000)
            if Task.isCancelled { return }
            self.refresh()
        }
    }

    func refresh() {
        loadTask?.cancel()
        spinnerTask?.cancel()
        isLoadingMore = false
        disasmLines = []
        disasmRows = []
        selectedIndex = nil
        hoveredIndex = nil
        pulsingIndex = nil
        pulseTask?.cancel()
        clearChildren(of: disasmBox)
        flowArea.queueDraw()

        guard let engine else {
            setSpinnerVisible(false)
            showErrorLabel("Engine unavailable.")
            return
        }

        switch insight.kind {
        case .memory:
            let hex = HexView(bytes: Data())
            hexView = hex
            setContent(hex.widget)
        case .disassembly:
            hexView = nil
            setContent(disasmHost)
        }

        guard let node = engine.node(forSessionID: sessionID) else {
            setSpinnerVisible(false)
            showErrorLabel("Session detached.")
            return
        }

        scheduleSpinner()

        let anchor = insight.anchor
        let byteCount = insight.byteCount
        let kind = insight.kind

        loadTask = Task { @MainActor in
            defer { setSpinnerVisible(false) }

            let resolved: UInt64
            do {
                resolved = try await node.resolve(anchor)
            } catch {
                if Task.isCancelled { return }
                showErrorLabel(error.localizedDescription)
                return
            }
            if Task.isCancelled { return }

            insight.lastResolvedAddress = resolved
            try? engine.store.save(insight)

            switch kind {
            case .memory:
                do {
                    let bytes = try await node.readRemoteMemory(at: resolved, count: byteCount)
                    if Task.isCancelled { return }
                    hexView?.setBytes(Data(bytes), baseAddress: resolved)
                } catch {
                    if Task.isCancelled { return }
                    showErrorLabel(error.localizedDescription)
                }

            case .disassembly:
                guard let disassembler = engine.disassembler(forSessionID: sessionID) else {
                    showErrorLabel("Disassembler unavailable.")
                    return
                }
                let lines = await disassembler.disassemble(
                    DisassemblyRequest(address: resolved, count: Self.initialChunk, isDarkMode: self.isDarkMode)
                )
                if Task.isCancelled { return }

                self.disasmLines = lines
                for line in lines {
                    let row = self.makeDisasmRow(line: line)
                    self.disasmRows.append(row)
                    self.disasmBox.append(child: row)
                }
                self.flowArea.queueDraw()
                if !lines.isEmpty {
                    self.selectRow(at: 0, focus: false)
                }
            }
        }
    }

    private func scheduleSpinner() {
        spinnerTask?.cancel()
        spinnerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            setSpinnerVisible(true)
        }
    }

    private func setSpinnerVisible(_ visible: Bool) {
        if !visible {
            spinnerTask?.cancel()
            spinnerTask = nil
        }
        spinnerHost.visible = visible
    }

    // MARK: - Infinite scroll

    private func handleScroll(adj: AdjustmentRef) {
        guard !isLoadingMore else { return }
        guard insight.kind == .disassembly else { return }
        guard !disasmLines.isEmpty else { return }
        let distanceToBottom = adj.upper - (adj.value + adj.pageSize)
        if distanceToBottom < 40.0 {
            loadMore()
        }
    }

    private func loadMore() {
        guard !isLoadingMore else { return }
        guard insight.kind == .disassembly else { return }
        guard let last = disasmLines.last else { return }
        guard let engine, let disassembler = engine.disassembler(forSessionID: sessionID) else { return }

        isLoadingMore = true
        scheduleSpinner()

        let start = last.address
        Task { @MainActor in
            defer {
                isLoadingMore = false
                setSpinnerVisible(false)
            }

            let decoded = await disassembler.disassemble(
                DisassemblyRequest(address: start, count: Self.moreChunk, isDarkMode: self.isDarkMode)
            )
            if Task.isCancelled { return }
            guard !decoded.isEmpty else { return }

            var page = decoded
            page.removeFirst()
            guard !page.isEmpty else { return }

            for line in page {
                let row = makeDisasmRow(line: line)
                disasmLines.append(line)
                disasmRows.append(row)
                disasmBox.append(child: row)
            }
            flowArea.queueDraw()
        }
    }

    // MARK: - Keyboard

    private func handleDisasmKey(keyval: UInt) -> Bool {
        let key = Int32(keyval)
        guard !disasmLines.isEmpty else { return false }
        if key == Gdk.keyUp || key == Gdk.keyk {
            moveSelection(by: -1); return true
        }
        if key == Gdk.keyDown || key == Gdk.keyj {
            moveSelection(by: 1); return true
        }
        if key == Gdk.keyPageUp {
            moveSelection(by: -10); return true
        }
        if key == Gdk.keyPageDown {
            moveSelection(by: 10); return true
        }
        if key == Gdk.keyReturn {
            if let idx = selectedIndex {
                jumpFromLine(at: idx)
            }
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !disasmLines.isEmpty else { return }
        let current = selectedIndex ?? -1
        var next = current + delta
        if next < 0 { next = 0 }
        if next >= disasmLines.count { next = disasmLines.count - 1 }
        selectRow(at: next, focus: true)
        if next >= disasmLines.count - 1 {
            loadMore()
        }
    }

    private func selectRow(at index: Int, focus: Bool) {
        guard index >= 0, index < disasmRows.count else { return }
        if let prev = selectedIndex, prev >= 0, prev < disasmRows.count {
            disasmRows[prev].remove(cssClass: "selected")
        }
        selectedIndex = index
        let row = disasmRows[index]
        row.add(cssClass: "selected")
        if focus {
            _ = row.grabFocus()
        }
        scrollToCenter(index: index)
    }

    private func scrollToCenter(index: Int) {
        guard let adj = disasmScroll.vadjustment else { return }
        guard !disasmRows.isEmpty else { return }
        let rowHeight = Double(disasmRows[0].allocatedHeight)
        guard rowHeight > 0 else { return }
        let rowMidY = (Double(index) + 0.5) * rowHeight
        let target = rowMidY - adj.pageSize / 2.0
        adj.value = max(0, min(target, adj.upper - adj.pageSize))
    }

    // MARK: - Jumping

    private func candidateTarget(for line: DisassemblyLine) -> UInt64? {
        if let t = line.branchTarget { return t }
        if let t = line.callTarget { return t }
        return nil
    }

    private func jumpFromLine(at index: Int) {
        guard index >= 0, index < disasmLines.count else { return }
        let line = disasmLines[index]
        guard let target = candidateTarget(for: line) else { return }
        jumpTo(target: target)
    }

    private func jumpTo(target: UInt64) {
        if let destIndex = disasmLines.firstIndex(where: { $0.address == target }) {
            selectRow(at: destIndex, focus: true)
            startPulse(index: destIndex)
            return
        }
        guard let engine else { return }
        do {
            let newInsight = try engine.getOrCreateInsight(sessionID: sessionID, pointer: target, kind: .disassembly)
            AddressActionMenu.navigator?(sessionID, newInsight.id)
        } catch {
            AddressActionMenu.errorReporter?("Can\u{2019}t jump here: \(error.localizedDescription)")
        }
    }

    private func startPulse(index: Int) {
        guard index >= 0, index < disasmRows.count else { return }
        pulseTask?.cancel()
        if let prev = pulsingIndex, prev >= 0, prev < disasmRows.count, prev != index {
            disasmRows[prev].remove(cssClass: "pulsing")
        }
        pulsingIndex = index
        let row = disasmRows[index]
        row.add(cssClass: "pulsing")
        pulseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if Task.isCancelled { return }
            if self.pulsingIndex == index, index < self.disasmRows.count {
                self.disasmRows[index].remove(cssClass: "pulsing")
            }
            if self.pulsingIndex == index {
                self.pulsingIndex = nil
            }
        }
    }

    // MARK: - Row construction

    private func makeDisasmRow(line: DisassemblyLine) -> Box {
        let row = Box(orientation: .horizontal, spacing: 10)
        row.add(cssClass: "luma-disasm-row")
        row.focusable = true
        row.marginStart = Int(Self.rowLeftGutter)
        row.marginEnd = 12
        row.marginTop = 2
        row.marginBottom = 2

        let decorationsBox = Box(orientation: .horizontal, spacing: 3)
        decorationsBox.halign = .end
        decorationsBox.valign = .center
        decorationsBox.setSizeRequest(width: 16, height: -1)

        let decorations = engine?.addressAnnotations[sessionID]?[line.address]?.decorations ?? []
        for deco in decorations.prefix(3) {
            let dot = Label(str: "●")
            dot.add(cssClass: "luma-disasm-decoration")
            if let help = deco.help, !help.isEmpty {
                dot.tooltipText = help
            }
            decorationsBox.append(child: dot)
        }
        row.append(child: decorationsBox)

        let addrLabel = Label(str: line.addressText.plainText)
        addrLabel.add(cssClass: "monospace")
        addrLabel.add(cssClass: "dim-label")
        addrLabel.halign = .start
        addrLabel.setSizeRequest(width: 110, height: -1)

        let address = line.address
        let addrGesture = GestureClick()
        addrGesture.set(button: 3)
        addrGesture.propagationPhase = GTK_PHASE_CAPTURE
        addrGesture.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated {
                self?.showAddressMenu(at: addrLabel, x: x, y: y, address: address)
            }
        }
        addrLabel.install(controller: addrGesture)

        row.append(child: addrLabel)

        let bytesLabel = Label(str: line.bytesText.plainText)
        bytesLabel.add(cssClass: "monospace")
        bytesLabel.add(cssClass: "dim-label")
        bytesLabel.halign = .start
        bytesLabel.setSizeRequest(width: 88, height: -1)
        row.append(child: bytesLabel)

        let asmRow = Box(orientation: .horizontal, spacing: 6)
        asmRow.hexpand = true
        asmRow.halign = .start

        let asmLabel = Label(str: "")
        asmLabel.setMarkup(str: StyledTextPango.markup(for: line.asmText))
        asmLabel.add(cssClass: "monospace")
        asmLabel.halign = .start
        asmLabel.selectable = true
        asmRow.append(child: asmLabel)

        if let target = line.branchTarget ?? line.callTarget {
            let button = Button()
            button.add(cssClass: "flat")
            button.add(cssClass: "luma-disasm-jump")
            button.valign = .center
            if containsPrintedTarget(line.asmText, target: target) {
                let icon = Image(iconName: "go-jump-symbolic")
                icon.pixelSize = 12
                button.set(child: icon)
                button.tooltipText = String(format: "Jump to 0x%llx", target)
            } else {
                let label = Label(str: String(format: "@0x%llx", target))
                label.add(cssClass: "monospace")
                button.set(child: label)
                button.tooltipText = String(format: "Jump to 0x%llx", target)
            }
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.jumpTo(target: target)
                }
            }
            asmRow.append(child: button)
        }

        row.append(child: asmRow)

        if let comment = line.commentText, !comment.isEmpty {
            let commentLabel = Label(str: "")
            commentLabel.setMarkup(str: StyledTextPango.markup(for: comment))
            commentLabel.add(cssClass: "monospace")
            commentLabel.add(cssClass: "dim-label")
            commentLabel.halign = .start
            commentLabel.selectable = true
            commentLabel.setSizeRequest(width: 320, height: -1)
            row.append(child: commentLabel)
        }

        let click = GestureClick()
        click.set(button: 1)
        click.onPressed { [weak self] _, nPress, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let rowIndex = self.disasmRows.firstIndex(where: { $0 === row }) else { return }
                self.selectRow(at: rowIndex, focus: true)
                if nPress >= 2 {
                    self.jumpFromLine(at: rowIndex)
                }
            }
        }
        row.install(controller: click)

        let motion = EventControllerMotion()
        motion.onEnter { [weak self] _, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let idx = self.disasmRows.firstIndex(where: { $0 === row }) else { return }
                self.hoveredIndex = idx
            }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hoveredIndex = nil
            }
        }
        row.install(controller: motion)

        return row
    }

    private func containsPrintedTarget(_ asm: StyledText, target: UInt64) -> Bool {
        let s = asm.plainText.lowercased()
        let hex = String(format: "0x%llx", target).lowercased()
        return s.contains(hex)
    }

    // MARK: - Context menu

    private func showAddressMenu(at anchor: Widget, x: Double, y: Double, address: UInt64) {
        guard let engine else { return }

        var items: [ContextMenu.Item] = [
            .init("Copy Address") {
                let hex = String(format: "0x%llx", address)
                guard let display = gdk_display_get_default() else { return }
                let clipboard = gdk_display_get_clipboard(display)
                hex.withCString { gdk_clipboard_set_text(clipboard, $0) }
                InsightDetailView.copyFeedback?("Copied!")
            }
        ]

        for action in engine.addressActions(sessionID: sessionID, address: address) {
            items.append(ContextMenu.Item(action.title, destructive: action.role == .destructive) { [weak self] in
                Task { @MainActor in
                    guard let target = await action.perform() else { return }
                    self?.owner?.navigate(to: target)
                }
            })
        }

        ContextMenu.present([items], at: anchor, x: x, y: y)
    }

    // MARK: - Theme

    fileprivate func handleThemeChanged() {
        let wasDark = isDarkMode
        isDarkMode = ThemeWatcher.isDarkMode()
        if isDarkMode != wasDark {
            scheduleRefresh()
        }
    }

    // MARK: - Flow overlay

    private struct FlowEdge {
        let src: UInt64
        let dst: UInt64
        let sRow: Int
        let dRow: Int
        let lo: Int
        let hi: Int
    }

    private static let flowPalette: [(Double, Double, Double)] = [
        (0.90, 0.22, 0.27),  // red
        (0.95, 0.54, 0.13),  // orange
        (0.91, 0.75, 0.11),  // yellow
        (0.22, 0.72, 0.29),  // green
        (0.13, 0.77, 0.62),  // mint
        (0.10, 0.70, 0.75),  // teal
        (0.18, 0.80, 0.90),  // cyan
        (0.18, 0.45, 0.85),  // blue
        (0.33, 0.33, 0.80),  // indigo
        (0.58, 0.26, 0.70),  // purple
        (0.92, 0.30, 0.60),  // pink
        (0.52, 0.37, 0.26),  // brown
    ]

    private func drawFlow(ctx: Cairo.ContextRef) {
        guard !disasmLines.isEmpty, !disasmRows.isEmpty else { return }
        let rowHeight = Double(disasmRows[0].allocatedHeight)
        guard rowHeight > 0 else { return }

        let indexByAddr: [UInt64: Int] = Dictionary(
            uniqueKeysWithValues: disasmLines.enumerated().map { ($0.element.address, $0.offset) }
        )

        var edges: [FlowEdge] = []
        edges.reserveCapacity(disasmLines.count)
        for line in disasmLines {
            guard let dst = line.branchTarget,
                let s = indexByAddr[line.address],
                let d = indexByAddr[dst]
            else { continue }
            edges.append(FlowEdge(src: line.address, dst: dst, sRow: s, dRow: d, lo: min(s, d), hi: max(s, d)))
        }

        edges.sort { a, b in
            if a.lo != b.lo { return a.lo < b.lo }
            return (a.hi - a.lo) < (b.hi - b.lo)
        }

        var laneEnds: [Int] = []
        var laneForEdge: [Int] = Array(repeating: 0, count: edges.count)

        for i in edges.indices {
            let e = edges[i]
            var lane = 0
            while lane < laneEnds.count {
                if e.lo > laneEnds[lane] {
                    laneEnds[lane] = e.hi
                    break
                }
                lane += 1
            }
            if lane == laneEnds.count {
                laneEnds.append(e.hi)
            }
            laneForEdge[i] = lane
        }

        var colorForEdge: [Int] = Array(repeating: -1, count: edges.count)
        let paletteCount = Self.flowPalette.count

        func overlaps(_ a: FlowEdge, _ b: FlowEdge) -> Bool {
            !(a.hi < b.lo || b.hi < a.lo)
        }

        for i in edges.indices {
            var usedColors = Set<Int>()
            for j in edges.indices where j != i {
                guard colorForEdge[j] >= 0 else { continue }
                if overlaps(edges[i], edges[j]) && abs(laneForEdge[i] - laneForEdge[j]) <= 1 {
                    usedColors.insert(colorForEdge[j])
                }
            }
            for c in 0..<paletteCount {
                if !usedColors.contains(c) {
                    colorForEdge[i] = c
                    break
                }
            }
            if colorForEdge[i] == -1 {
                colorForEdge[i] = i % paletteCount
            }
        }

        ctx.lineWidth = 1.25

        for i in edges.indices {
            let e = edges[i]
            let y1 = (Double(e.sRow) + 0.5) * rowHeight
            let y2 = (Double(e.dRow) + 0.5) * rowHeight
            let x = Self.flowBaseX + Double(laneForEdge[i]) * Self.flowLaneSpacing
            let (r, g, b) = Self.flowPalette[colorForEdge[i]]

            ctx.setSource(red: r, green: g, blue: b, alpha: 0.9)
            ctx.moveTo(Self.flowEntryX, y1)
            ctx.lineTo(x, y1)
            ctx.lineTo(x, y2)
            ctx.lineTo(Self.flowEntryX, y2)
            ctx.stroke()

            let arrowSize: Double = 6
            ctx.setSource(red: r, green: g, blue: b, alpha: 1.0)
            ctx.moveTo(Self.flowEntryX, y2)
            ctx.lineTo(Self.flowEntryX - arrowSize, y2 - arrowSize * 0.65)
            ctx.lineTo(Self.flowEntryX - arrowSize, y2 + arrowSize * 0.65)
            ctx.closePath()
            ctx.fill()
        }
    }

    private func clearChildren(of box: Box) {
        while let child = box.firstChild {
            clearFocusIfInside(child)
            box.remove(child: child)
        }
    }
}
