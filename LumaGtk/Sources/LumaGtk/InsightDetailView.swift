import Adw
import CCairo
import CGraphene
import CGtk
import Cairo
import Foundation
import Gdk
import struct Graphene.PointRef
import Gtk
import LumaCore
import Pango

@MainActor
final class InsightDetailView {
    static var copyFeedback: ((String) -> Void)?

    func handleInsightUpdated(_ updated: LumaCore.AddressInsight) {
        guard updated.id == insight.id else { return }
        let prevResolved = insight.lastResolvedAddress
        insight = updated
        if updated.lastResolvedAddress != prevResolved {
            scheduleRefresh()
        }
    }

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
    private let spinner: Spinner
    private var spinnerTask: Task<Void, Never>?

    private let disasmHost: Box
    private let disasmScroll: ScrolledWindow
    private let disasmContentOverlay: Overlay
    private let disasmBox: Box
    private let flowArea: DrawingArea
    private var hexView: HexView?

    private var disasmLines: [DisassemblyLine] = []
    private var disasmRows: [Box] = []
    private var addressLabelsByAddress: [UInt64: Label] = [:]
    private var decorationsBoxesByAddress: [UInt64: Box] = [:]
    private var noteIndicatorsByAddress: [UInt64: Gtk.Image] = [:]
    private var selectedIndex: Int? = nil
    private var hoveredIndex: Int? = nil
    private var pulsingIndex: Int? = nil
    private var pulseTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var refreshDebounce: Task<Void, Never>?
    private var isLoadingMore = false
    private var disasmScope: DisassemblyScope = .span
    private var appearance: Appearance = .light
    private var themeSignalID: gulong = 0
    private var valueChangedHandler: gulong = 0
    private var lastNodeAvailable: Bool = false

    private let refreshBar: Box
    private let rereadButton: Button
    private let reanalyzeButton: Button

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

        refreshBar = Box(orientation: .horizontal, spacing: 6)
        refreshBar.halign = .end
        refreshBar.valign = .start
        refreshBar.marginTop = 4
        refreshBar.marginEnd = 8
        refreshBar.marginStart = 8
        rereadButton = Button(iconName: "view-refresh-symbolic")
        rereadButton.tooltipText = "Drop cached bytes for this view and refetch."
        rereadButton.hasFrame = false
        reanalyzeButton = Button(iconName: "emblem-synchronizing-symbolic")
        reanalyzeButton.tooltipText = "Drop disassembly analysis for this address's module."
        reanalyzeButton.hasFrame = false
        refreshBar.append(child: rereadButton)
        refreshBar.append(child: reanalyzeButton)

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
        contentOverlay.addOverlay(widget: refreshBar)

        spinner = makeSpinner()

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
        disasmScroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)

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

        appearance = ThemeWatcher.currentAppearance()
        themeSignalID = ThemeWatcher.subscribe(owner: self) { view in
            view.handleThemeChanged()
        }

        rereadButton.onClicked { [weak self] _ in MainActor.assumeIsolated { self?.rereadBytes() } }
        reanalyzeButton.onClicked { [weak self] _ in MainActor.assumeIsolated { self?.reanalyzeModule() } }

        applySessionState()
        scheduleRefresh()

        engine.onAddressNoteChanged = { [weak self] change in
            MainActor.assumeIsolated {
                self?.handleAddressNoteChanged(change)
            }
        }
    }

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeSignalID)
    }

    private func handleAddressNoteChanged(_ change: AddressNoteChange) {
        guard let engine else { return }
        let affectedNote: AddressNote?
        switch change {
        case .noteAdded(let note), .noteUpdated(let note), .noteRemoved(let note):
            affectedNote = note.sessionID == sessionID ? note : nil
        case .messageAppended, .messageEdited, .messageRemoved:
            return
        }
        guard let note = affectedNote,
            let address = engine.resolveSync(sessionID: sessionID, anchor: note.anchor)
        else { return }
        updateNoteIndicator(at: address)
    }

    private func updateNoteIndicator(at address: UInt64) {
        guard let decorationsBox = decorationsBoxesByAddress[address] else { return }
        let noteCount = engine?.addressAnnotations[sessionID]?[address]?.noteCount ?? 0
        if noteCount > 0 {
            let bubble = noteIndicatorsByAddress[address] ?? installNoteIndicator(in: decorationsBox, address: address)
            bubble.tooltipText = "\(noteCount) thread\(noteCount == 1 ? "" : "s")"
        } else if let bubble = noteIndicatorsByAddress.removeValue(forKey: address) {
            decorationsBox.remove(child: bubble)
        }
    }

    private func installNoteIndicator(in decorationsBox: Box, address: UInt64) -> Gtk.Image {
        let bubble = Gtk.Image(iconName: "mail-unread-symbolic")
        bubble.pixelSize = 12
        bubble.add(cssClass: "luma-disasm-note-bubble")
        bubble.valign = .center
        let click = GestureClick()
        click.set(button: 1)
        click.onPressed { [weak self] _, _, _, _ in
            MainActor.assumeIsolated {
                guard let self, let anchor = self.addressLabelsByAddress[address] else { return }
                if let rowIndex = self.disasmLines.firstIndex(where: { $0.address == address }) {
                    self.selectRow(at: rowIndex, focus: true)
                }
                self.openNotePopover(anchoredAt: anchor, address: address)
            }
        }
        bubble.install(controller: click)
        decorationsBox.append(child: bubble)
        noteIndicatorsByAddress[address] = bubble
        return bubble
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
            let gatingActive = engine.isGatingActive(forDeviceID: current.deviceID)
            let banner = SessionDetachedBanner.make(
                for: current,
                gatingActive: gatingActive,
                canReattach: engine.canTakeHosting(current),
                onReattach: { [weak self] in self?.owner?.reestablishSession(id: current.id) },
                onDisarm: { [weak engine] in
                    Task { @MainActor in await engine?.disarmSession(id: current.id) }
                },
                onArm: { [weak self] in self?.owner?.presentArmDialog(session: current) },
                onResumeGating: { [weak engine] in
                    Task { @MainActor in await engine?.resumeGating(forSessionID: current.id) }
                }
            )
            bannerSlot.append(child: banner)
            currentBanner = banner
        }

        let nodeAvailable = engine.node(forSessionID: sessionID) != nil
        if nodeAvailable && !lastNodeAvailable {
            scheduleRefresh()
        }
        lastNodeAvailable = nodeAvailable

        rereadButton.sensitive = nodeAvailable
        reanalyzeButton.sensitive = nodeAvailable && enclosingModule() != nil
    }

    private func enclosingModule() -> LumaCore.ProcessModule? {
        guard let engine else { return nil }
        if let resolved = insight.lastResolvedAddress,
            let module = engine.enclosingModule(at: resolved, sessionID: sessionID)
        {
            return module
        }
        if case .moduleOffset(let name, _) = insight.anchor {
            return engine.modulesSnapshot(forSessionID: sessionID).first { $0.name == name }
        }
        return nil
    }

    private func rereadBytes() {
        guard let engine, let resolved = insight.lastResolvedAddress else { return }
        let byteCount = insight.byteCount
        let sid = sessionID
        Task { @MainActor in
            await engine.invalidateInsightRange(sessionID: sid, address: resolved, byteCount: byteCount)
            scheduleRefresh()
        }
    }

    private func reanalyzeModule() {
        guard let engine, let module = enclosingModule() else { return }
        engine.invalidateModule(sessionID: sessionID, modulePath: module.path)
        scheduleRefresh()
    }

    func requestFocus() {
        if insight.kind == .disassembly {
            _ = disasmBox.grabFocus()
        }
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
        while let cur = contentHost.firstChild {
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
        addressLabelsByAddress.removeAll()
        decorationsBoxesByAddress.removeAll()
        noteIndicatorsByAddress.removeAll()
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

        scheduleSpinner()

        let anchor = insight.anchor
        let byteCount = insight.byteCount
        let kind = insight.kind
        let reader = engine.memoryReader(forSessionID: sessionID)

        loadTask = Task { @MainActor in
            defer { setSpinnerVisible(false) }

            guard let resolved = await engine.resolve(sessionID: sessionID, anchor: anchor, hint: insight.lastResolvedAddress) else {
                if Task.isCancelled { return }
                showErrorLabel("Unable to resolve address while detached.")
                return
            }
            if Task.isCancelled { return }

            engine.recordInsightResolution(insight, resolved: resolved)

            switch kind {
            case .memory:
                do {
                    let bytes = try await reader.read(at: resolved, count: byteCount)
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
                do {
                    _ = try await reader.read(at: resolved, count: 1)
                } catch {
                    if Task.isCancelled { return }
                    showErrorLabel(error.localizedDescription)
                    return
                }
                let page = await disassembler.disassemblePage(
                    DisassemblyRequest(address: resolved, count: Self.initialChunk, appearance: self.appearance)
                )
                if Task.isCancelled { return }

                self.disasmScope = page.scope
                let lines = page.lines
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
                _ = self.disasmBox.grabFocus()
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
        guard disasmScope == .span else { return }
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
                DisassemblyRequest(address: start, count: Self.moreChunk, appearance: self.appearance)
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
        if key == Gdk.keyHome {
            selectRow(at: 0, focus: true); return true
        }
        if key == Gdk.keyEnd {
            selectRow(at: disasmLines.count - 1, focus: true)
            loadMore()
            return true
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
        let rowHeight = Double(disasmBox.height) / Double(disasmRows.count)
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

    private func makeDecorationsBox(address: UInt64) -> Box {
        let decorationsBox = Box(orientation: .horizontal, spacing: 3)
        decorationsBox.halign = .end
        decorationsBox.valign = .center
        decorationsBox.setSizeRequest(width: 16, height: 16)
        decorationsBoxesByAddress[address] = decorationsBox

        let annotation = engine?.addressAnnotations[sessionID]?[address]
        for deco in (annotation?.decorations ?? []).prefix(3) {
            let dot = Label(str: "●")
            dot.add(cssClass: "luma-disasm-decoration")
            if let help = deco.help, !help.isEmpty {
                dot.tooltipText = help
            }
            decorationsBox.append(child: dot)
        }
        let noteCount = annotation?.noteCount ?? 0
        if noteCount > 0 {
            let bubble = installNoteIndicator(in: decorationsBox, address: address)
            bubble.tooltipText = "\(noteCount) thread\(noteCount == 1 ? "" : "s")"
        }
        return decorationsBox
    }

    private func makeDisasmRow(line: DisassemblyLine) -> Box {
        let row = Box(orientation: .horizontal, spacing: 10)
        row.add(cssClass: "luma-disasm-row")
        row.focusable = true
        row.marginStart = Int(Self.rowLeftGutter)
        row.marginEnd = 12
        row.marginTop = 2
        row.marginBottom = 2
        row.setSizeRequest(width: -1, height: 16)

        row.append(child: makeDecorationsBox(address: line.address))

        let addrLabel = Label(str: line.addressText.plainText)
        addrLabel.add(cssClass: "monospace")
        addrLabel.add(cssClass: "dim-label")
        addrLabel.halign = .start
        addrLabel.xalign = 0
        addrLabel.ellipsize = EllipsizeMode.end
        addrLabel.widthChars = 18
        addrLabel.maxWidthChars = 18
        addressLabelsByAddress[line.address] = addrLabel

        attachAddressMenu(to: addrLabel, address: line.address)

        row.append(child: addrLabel)

        let bytesLabel = Label(str: line.bytesText.plainText)
        bytesLabel.add(cssClass: "monospace")
        bytesLabel.add(cssClass: "dim-label")
        bytesLabel.halign = .start
        bytesLabel.xalign = 0
        bytesLabel.ellipsize = EllipsizeMode.end
        bytesLabel.widthChars = 18
        bytesLabel.maxWidthChars = 18
        row.append(child: bytesLabel)

        let asmRow = Box(orientation: .horizontal, spacing: 6)
        asmRow.hexpand = true
        asmRow.halign = .fill
        asmRow.setSizeRequest(width: 240, height: -1)

        asmRow.append(child: makeAsmBox(line.asmText))

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
            commentLabel.xalign = 0
            commentLabel.ellipsize = EllipsizeMode.end
            commentLabel.selectable = true
            commentLabel.widthChars = 50
            commentLabel.maxWidthChars = 50
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

    private func makeAsmBox(_ asm: StyledText) -> Box {
        let box = Box(orientation: .horizontal, spacing: 0)
        for segment in asm.addressSegments() {
            let label = Label(str: "")
            label.setMarkup(str: StyledTextPango.markup(for: segment.text))
            label.add(cssClass: "monospace")
            label.halign = .start
            label.xalign = 0
            label.selectable = true
            if let address = segment.address {
                attachAddressMenu(to: label, address: address)
            }
            box.append(child: label)
        }
        return box
    }

    private func attachAddressMenu(to label: Label, address: UInt64) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.propagationPhase = .capture
        gesture.onPressed { [weak self] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = gesture.set(state: .claimed)
                let (tx, ty) = self.translatePoint(x: x, y: y, from: label, to: self.widget)
                self.showAddressMenu(anchor: label, x: tx, y: ty, address: address)
            }
        }
        label.install(controller: gesture)
    }

    private func containsPrintedTarget(_ asm: StyledText, target: UInt64) -> Bool {
        let s = asm.plainText.lowercased()
        let hex = String(format: "0x%llx", target).lowercased()
        return s.contains(hex)
    }

    // MARK: - Context menu

    private func translatePoint<Src: WidgetProtocol, Dst: WidgetProtocol>(
        x: Double,
        y: Double,
        from src: Src,
        to dst: Dst
    ) -> (x: Double, y: Double) {
        var source = graphene_point_t(x: Float(x), y: Float(y))
        var destination = graphene_point_t(x: 0, y: 0)
        _ = withUnsafeMutablePointer(to: &source) { srcPtr in
            withUnsafeMutablePointer(to: &destination) { dstPtr in
                src.computePoint(target: dst, point: PointRef(srcPtr), outPoint: PointRef(dstPtr))
            }
        }
        return (Double(destination.x), Double(destination.y))
    }

    private func showAddressMenu(anchor: Widget, x: Double, y: Double, address: UInt64) {
        guard let engine else { return }

        let navigation: [[ContextMenu.Item]] = [[
            .init("Notes & AI…") { [weak self] in
                self?.openNotePopover(anchoredAt: anchor, address: address)
            },
            .init("Go to Function Start") { [weak self] in
                Task { @MainActor in
                    await self?.goToFunctionStart(address: address)
                }
            }
        ]]

        AddressActionMenu.present(
            at: widget, x: x, y: y, engine: engine, sessionID: sessionID, address: address,
            value: String(format: "0x%llx", address), extraSections: navigation)
    }

    private func openNotePopover(anchoredAt anchor: Widget, address: UInt64) {
        guard let engine else { return }
        let popover = AddressNotePopover(engine: engine, sessionID: sessionID, address: address)
        popover.presentAnchored(to: anchor, pointingX: anchorContentWidth(anchor))
    }

    private func anchorContentWidth(_ anchor: Widget) -> Int {
        if let label = anchor as? Label, let text = label.label {
            let layoutPtr = gtk_widget_create_pango_layout(anchor.widget_ptr, text)
            defer { if let p = layoutPtr { g_object_unref(p) } }
            var w: Int32 = 0
            if let layoutPtr {
                pango_layout_get_pixel_size(layoutPtr, &w, nil)
            }
            if w > 0 { return Int(w) }
        }
        return Int(anchor.width)
    }

    private func goToFunctionStart(address: UInt64) async {
        guard let engine, let dis = engine.disassembler(forSessionID: sessionID) else { return }
        guard let target = await dis.findFunctionStart(containing: address) else {
            InsightDetailView.copyFeedback?(
                "No function containing \(String(format: "0x%llx", address))"
            )
            return
        }
        do {
            let insight = try engine.getOrCreateInsight(sessionID: sessionID, pointer: target, kind: .disassembly)
            AddressActionMenu.navigator?(sessionID, insight.id)
        } catch {
            AddressActionMenu.errorReporter?("Can\u{2019}t open function: \(error.localizedDescription)")
        }
    }

    // MARK: - Theme

    fileprivate func handleThemeChanged() {
        let previous = appearance
        appearance = ThemeWatcher.currentAppearance()
        if appearance != previous {
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
        let rowHeight = Double(disasmBox.height) / Double(disasmRows.count)
        guard rowHeight > 0 else { return }

        let indexByAddr: [UInt64: Int] = Dictionary(
            disasmLines.enumerated().map { ($0.element.address, $0.offset) },
            uniquingKeysWith: { first, _ in first }
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
