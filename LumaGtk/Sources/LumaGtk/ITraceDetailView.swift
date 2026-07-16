import Adw
import CGLib
import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class ITraceDetailView {
    let widget: Box

    private var trace: ITrace
    private let otherTraces: [ITrace]
    private let engine: Engine
    private let sessionID: Foundation.UUID
    private let bodyContainer: Box
    private let entriesList: ListBox
    private let entriesScroll: ScrolledWindow
    private var entryRows: [ListBoxRow] = []
    private var decoded: DecodedITrace?
    private var disassembler: TraceDisassembler?
    private var cfgView: ITraceCFGView?
    private var timeline: ITraceTimeline?
    private var selectedCallIndex: Int = 0
    private var showingGraph = true
    private var compareButton: Button?
    private var stopButton: Button?
    private var lastDecodedSize: Int = 0
    private var redecodeTask: Task<Void, Never>?
    private var captionLabel: Label?
    private let baseCaption: String
    private var serverTotalSize: Int = 0
    private var invalidationListener: Task<Void, Never>?
    fileprivate var appearance: Appearance = ThemeWatcher.currentAppearance()
    private var themeSignalID: gulong = 0

    init(
        trace: ITrace,
        otherTraces: [ITrace] = [],
        engine: Engine,
        sessionID: Foundation.UUID
    ) {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium

        self.trace = trace
        self.otherTraces = otherTraces
        self.engine = engine
        self.sessionID = sessionID
        self.baseCaption = "started \(formatter.string(from: trace.startedAt)) · lost \(trace.lost)"

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true
        widget.marginStart = 16
        widget.marginEnd = 16
        widget.marginTop = 12
        widget.marginBottom = 12

        let headerRow = Box(orientation: .horizontal, spacing: 8)
        headerRow.hexpand = true

        let headerLeft = Box(orientation: .vertical, spacing: 0)
        headerLeft.hexpand = true

        let titleRow = Box(orientation: .horizontal, spacing: 8)
        titleRow.halign = .start
        let titleLabel = Label(str: trace.displayName)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-3")
        titleRow.append(child: titleLabel)
        headerLeft.append(child: titleRow)

        let captionLabel = Label(str: baseCaption)
        captionLabel.halign = .start
        captionLabel.add(cssClass: "dim-label")
        captionLabel.add(cssClass: "caption")
        headerLeft.append(child: captionLabel)
        self.captionLabel = captionLabel

        headerRow.append(child: headerLeft)

        let stopButton = Button(label: "Stop")
        stopButton.valign = .center
        stopButton.add(cssClass: "destructive-action")
        stopButton.visible = trace.isRunning && Self.isThreadOrigin(trace.origin)
        let traceID = trace.id
        let stopSessionID = sessionID
        stopButton.onClicked { [weak engine] _ in
            MainActor.assumeIsolated {
                guard let engine else { return }
                Task { @MainActor in
                    await engine.stopThreadTrace(traceID: traceID, sessionID: stopSessionID)
                }
            }
        }
        headerRow.append(child: stopButton)
        self.stopButton = stopButton

        var pendingCompareButton: Button?
        if !otherTraces.isEmpty {
            let btn = Button(label: "Compare with\u{2026}")
            btn.valign = .center
            pendingCompareButton = btn
            headerRow.append(child: btn)
        }

        widget.append(child: headerRow)

        bodyContainer = Box(orientation: .vertical, spacing: 8)
        bodyContainer.hexpand = true
        bodyContainer.vexpand = true
        bodyContainer.marginTop = 12
        widget.append(child: bodyContainer)

        entriesList = ListBox()
        entriesList.hexpand = true
        entriesList.selectionMode = .single
        entriesList.add(cssClass: "boxed-list")
        entriesScroll = ScrolledWindow()
        entriesScroll.hexpand = true
        entriesScroll.vexpand = true
        entriesScroll.set(child: entriesList)

        let spinner = makeSpinner()
        let loading = Box(orientation: .horizontal, spacing: 8)
        loading.halign = .center
        loading.marginTop = 24
        loading.append(child: spinner)
        let loadingLabel = Label(str: "Decoding trace\u{2026}")
        loading.append(child: loadingLabel)
        bodyContainer.append(child: loading)

        let metadataJSON = trace.metadataJSON
        let initialSize = trace.dataSize
        let sid = sessionID
        let eng = engine
        Task { @MainActor [weak self] in
            await Task.yield()
            if initialSize == 0 {
                self?.showWaitingState()
                return
            }
            if initialSize > Self.firstPaintBytes {
                if let preview = try? await eng.loadTraceDataPrefix(traceID: traceID, sessionID: sid, length: Self.firstPaintBytes),
                    let decoded = try? ITraceDecoder.decode(traceData: preview, metadataJSON: metadataJSON)
                {
                    self?.applyDecodeResult(.success(decoded))
                }
            }
            let result: Result<DecodedITrace, Error>
            do {
                let traceData = try await eng.loadTraceData(
                    traceID: traceID,
                    sessionID: sid,
                    expectedSize: initialSize,
                    onProgress: { [weak self] loaded, total in
                        self?.updateProgress(loaded: loaded, total: total)
                    }
                )
                self?.updateProgress(loaded: nil, total: nil)
                let decoded = try ITraceDecoder.decode(traceData: traceData, metadataJSON: metadataJSON)
                self?.lastDecodedSize = traceData.count
                result = .success(decoded)
            } catch {
                self?.updateProgress(loaded: nil, total: nil)
                result = .failure(error)
            }
            self?.applyDecodeResult(result)
        }

        themeSignalID = ThemeWatcher.subscribe(owner: self) { detail in
            detail.handleThemeChanged()
        }

        invalidationListener = Task { @MainActor [weak self, weak engine, traceID] in
            guard let stream = engine?.traceCacheInvalidations else { return }
            for await invalidation in stream where invalidation.traceID == traceID {
                guard let self else { return }
                self.serverTotalSize = invalidation.knownTotalSize
                self.scheduleRedecode()
            }
        }

        let modeKey = EventControllerKey()
        modeKey.propagationPhase = .capture
        modeKey.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                guard keyval == 0x020 else { return false }
                self?.toggleMode()
                return true
            }
        }
        widget.install(controller: modeKey)

        if let btn = pendingCompareButton {
            self.compareButton = btn
            let traceForCompare = trace
            let othersForCompare = otherTraces
            let formatterForCompare = formatter
            btn.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let button = self?.compareButton else { return }
                    guard let self else { return }
                    Self.presentComparePopover(
                        anchor: button,
                        trace: traceForCompare,
                        others: othersForCompare,
                        formatter: formatterForCompare,
                        engine: self.engine,
                        sessionID: self.sessionID
                    )
                }
            }
        }
    }

    func update(with trace: ITrace) {
        let previousSize = self.trace.dataSize
        self.trace = trace
        stopButton?.visible = trace.isRunning && Self.isThreadOrigin(trace.origin)
        if trace.dataSize != previousSize {
            scheduleRedecode()
        }
    }

    private func scheduleRedecode() {
        redecodeTask?.cancel()
        redecodeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.startRedecode()
        }
    }

    private func startRedecode() {
        let expected = max(trace.dataSize, serverTotalSize)
        guard expected != lastDecodedSize else { return }
        let traceID = trace.id
        let metadataJSON = trace.metadataJSON
        let sid = sessionID
        let eng = engine
        Task { @MainActor [weak self] in
            await Task.yield()
            let result: Result<DecodedITrace, Error>
            do {
                let traceData = try await eng.loadTraceData(traceID: traceID, sessionID: sid, expectedSize: expected)
                let decoded = try ITraceDecoder.decode(traceData: traceData, metadataJSON: metadataJSON)
                self?.lastDecodedSize = traceData.count
                result = .success(decoded)
            } catch {
                result = .failure(error)
            }
            self?.applyDecodeResult(result)
        }
    }

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeSignalID)
        invalidationListener?.cancel()
    }

    fileprivate func handleThemeChanged() {
        let now = ThemeWatcher.currentAppearance()
        guard now != appearance else { return }
        appearance = now
        cfgView?.invalidateDisasm()
    }

    private func showWaitingState() {
        while let child = bodyContainer.firstChild {
            bodyContainer.remove(child: child)
        }

        let waiting = Box(orientation: .vertical, spacing: 8)
        waiting.halign = .center
        waiting.valign = .center
        waiting.marginTop = 24
        waiting.marginBottom = 24

        let icon = Gtk.Image(iconName: "media-record-symbolic")
        icon.add(cssClass: "error")
        waiting.append(child: icon)

        let label = Label(str: "Waiting for trace data\u{2026}")
        label.add(cssClass: "dim-label")
        waiting.append(child: label)

        bodyContainer.append(child: waiting)
    }

    private func applyDecodeResult(_ result: Result<DecodedITrace, Error>) {
        while let child = bodyContainer.firstChild {
            bodyContainer.remove(child: child)
        }

        switch result {
        case .failure(let error):
            let errorLabel = Label(str: "Failed to decode trace: \(error)")
            errorLabel.halign = .start
            errorLabel.wrap = true
            errorLabel.add(cssClass: "error")
            bodyContainer.append(child: errorLabel)

        case .success(let decoded):
            self.decoded = decoded
            if let session = engine.session(id: sessionID), let processInfo = session.processInfo {
                self.disassembler = TraceDisassembler(
                    decoded: decoded,
                    processInfo: processInfo,
                    liveNode: engine.node(forSessionID: sessionID)
                )
            }
            if decoded.functionCalls.isEmpty {
                appendEmptyCFGState(isRecording: trace.isRunning)
                return
            }
            let timeline = ITraceTimeline(
                functionCalls: decoded.functionCalls,
                totalEntryCount: decoded.entries.count
            )
            timeline.onSelect = { [weak self] callIndex in
                guard let self, let decoded = self.decoded else { return }
                let call = decoded.functionCalls[callIndex]
                self.jumpToEntry(index: call.startIndex)
                self.selectedCallIndex = callIndex
                self.cfgView?.setSelectedCall(index: callIndex)
            }
            self.timeline = timeline
            bodyContainer.append(child: timeline.widget)
            populateEntries(decoded.entries)
            bodyContainer.append(child: entriesScroll)
            if let existingCFG = cfgView {
                existingCFG.update(decoded: decoded)
                bodyContainer.append(child: existingCFG.widget)
            } else {
                buildCFGView(from: decoded)
            }
            applyMode()
        }
    }

    private func appendEmptyCFGState(isRecording: Bool) {
        let empty = Box(orientation: .vertical, spacing: 8)
        empty.halign = .center
        empty.valign = .center
        empty.hexpand = true
        empty.vexpand = true

        let icon = Gtk.Image(iconName: isRecording ? "media-record-symbolic" : "view-grid-symbolic")
        icon.pixelSize = 32
        if isRecording { icon.add(cssClass: "error") } else { icon.add(cssClass: "dim-label") }
        empty.append(child: icon)

        let title = Label(str: isRecording ? "Recording\u{2026}" : "No control-flow data")
        title.add(cssClass: "title-4")
        empty.append(child: title)

        let detail = Label(str: isRecording
            ? "Waiting for the first executed instructions to arrive."
            : "This trace finished without capturing any executed instructions.")
        detail.add(cssClass: "dim-label")
        detail.wrap = true
        detail.justify = .center
        empty.append(child: detail)

        bodyContainer.append(child: empty)
    }

    private func toggleMode() {
        showingGraph.toggle()
        applyMode()
    }

    private func applyMode() {
        entriesScroll.visible = !showingGraph
        cfgView?.widget.visible = showingGraph
        if showingGraph {
            cfgView?.focus()
        } else if let selected = entriesList.selectedRow {
            _ = selected.grabFocus()
        } else if let first = entryRows.first {
            _ = first.grabFocus()
        }
    }

    private func buildCFGView(from decoded: DecodedITrace) {
        guard !decoded.functionCalls.isEmpty else { return }

        let disassembler = self.disassembler
        let provider: ((UInt64, Int) async -> StyledText)? = disassembler.map { d in
            { [weak self] addr, size in
                let appearance = await MainActor.run { self?.appearance ?? .light }
                return await d.disassemble(at: addr, size: size, appearance: appearance, withFlags: false)
            }
        }
        let addressesProvider: ((UInt64, Int) async -> [UInt64])? = disassembler.map { d in
            { addr, size in
                await d.instructionAddresses(at: addr, size: size)
            }
        }

        let view = ITraceCFGView(
            decoded: decoded,
            engine: engine,
            sessionID: sessionID,
            selectedCallIndex: selectedCallIndex,
            disasmProvider: provider,
            instructionAddressesProvider: addressesProvider
        )
        view.onSelect = { [weak self] key in
            MainActor.assumeIsolated {
                self?.scrollToEntry(matchingNodeKey: key)
            }
        }
        view.onJumpToFunction = { [weak self] (index: Int) in
            MainActor.assumeIsolated {
                guard let self, let decoded = self.decoded else { return }
                let target = index < 0 ? decoded.functionCalls.count - 1 : index
                guard target >= 0, target < decoded.functionCalls.count else { return }
                self.selectedCallIndex = target
                self.cfgView?.setSelectedCall(index: target)
                self.timeline?.setSelected(index: target)
            }
        }
        view.onNavigateFunction = { [weak self] (direction: Int) in
            MainActor.assumeIsolated {
                guard let self, let decoded = self.decoded else { return }
                let newIdx = self.selectedCallIndex + direction
                guard newIdx >= 0, newIdx < decoded.functionCalls.count else { return }
                self.selectedCallIndex = newIdx
                self.cfgView?.setSelectedCall(index: newIdx)
                self.timeline?.setSelected(index: newIdx)
            }
        }
        cfgView = view
        bodyContainer.append(child: view.widget)
    }

    private func scrollToEntry(matchingNodeKey key: CFGGraph.NodeKey) {
        guard let decoded else { return }
        let addr = CFGGraph.nodeAddress(key)
        for (i, entry) in decoded.entries.enumerated() where entry.blockAddress == addr {
            jumpToEntry(index: i)
            return
        }
    }

    private func populateEntries(_ entries: [TraceEntry]) {
        while let row = entriesList.firstChild {
            entriesList.remove(child: row)
        }
        entryRows.removeAll(keepingCapacity: true)
        entryRows.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            let row = ListBoxRow()
            row.focusable = true
            let text = String(
                format: "#%d  0x%016llx  %@  [+%d writes]",
                index,
                entry.blockAddress,
                entry.blockName,
                entry.registerWrites.count
            )
            let label = Label(str: text)
            label.halign = .start
            label.add(cssClass: "monospace")
            label.marginStart = 8
            label.marginEnd = 8
            label.marginTop = 1
            label.marginBottom = 1
            row.set(child: label)
            entriesList.append(child: row)
            entryRows.append(row)
        }
    }

    private func jumpToEntry(index: Int) {
        guard index >= 0, index < entryRows.count else { return }
        let row = entryRows[index]
        entriesList.select(row: row)
        _ = row.grabFocus()
    }

    private static func presentComparePopover(
        anchor: Widget,
        trace: ITrace,
        others: [ITrace],
        formatter: DateFormatter,
        engine: Engine,
        sessionID: Foundation.UUID
    ) {
        let popover = Popover()
        popover.autohide = true

        let listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")

        for other in others {
            let row = ListBoxRow()
            let label = Label(
                str: "\(other.displayName) \u{00B7} \(formatter.string(from: other.startedAt))"
            )
            label.halign = .start
            label.marginStart = 8
            label.marginEnd = 8
            label.marginTop = 4
            label.marginBottom = 4
            row.set(child: label)
            listBox.append(child: row)
        }

        listBox.onRowActivated { [popover, weak anchor] _, row in
            MainActor.assumeIsolated {
                guard let anchor else { return }
                let index = Int(row.index)
                guard index >= 0, index < others.count else { return }
                popover.popdown()
                ITraceDiffView.present(from: anchor, left: trace, right: others[index], engine: engine, sessionID: sessionID)
            }
        }

        let scroll = ScrolledWindow()
        scroll.setSizeRequest(width: 320, height: 240)
        scroll.add(cssClass: "luma-popover-scroll")
        scroll.set(child: listBox)

        popover.set(child: WidgetRef(scroll.widget_ptr))
        popover.set(parent: anchor)
        popover.onClosed { _ in
            MainActor.assumeIsolated {
                gtk_widget_unparent(popover.widget_ptr)
            }
        }
        popover.popup()
    }

    private static func isThreadOrigin(_ origin: ITrace.Origin) -> Bool {
        if case .thread = origin { return true }
        return false
    }

    private func updateProgress(loaded: Int?, total: Int?) {
        guard let captionLabel else { return }
        if let loaded, let total {
            captionLabel.setText(str: "\(baseCaption) · loading \(Self.formatBytes(loaded)) of \(Self.formatBytes(total))")
        } else {
            captionLabel.setText(str: baseCaption)
        }
    }

    private static func formatBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    private static let firstPaintBytes: Int = 256 * 1024
}
