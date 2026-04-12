import CGLib
import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class ITraceDetailView {
    let widget: Box

    private let capture: ITraceCaptureRecord
    private let otherCaptures: [ITraceCaptureRecord]
    private let engine: Engine
    private let sessionID: UUID
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
    fileprivate var isDarkMode: Bool = ThemeWatcher.isDarkMode()
    private var themeSignalID: gulong = 0

    init(
        capture: ITraceCaptureRecord,
        otherCaptures: [ITraceCaptureRecord] = [],
        engine: Engine,
        sessionID: UUID
    ) {
        self.capture = capture
        self.otherCaptures = otherCaptures
        self.engine = engine
        self.sessionID = sessionID

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true
        widget.marginStart = 16
        widget.marginEnd = 16
        widget.marginTop = 12
        widget.marginBottom = 12

        let titleLabel = Label(str: capture.displayName)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-3")
        widget.append(child: titleLabel)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        let captionLabel = Label(
            str: "captured \(formatter.string(from: capture.capturedAt)) · lost \(capture.lost)"
        )
        captionLabel.halign = .start
        captionLabel.add(cssClass: "dim-label")
        captionLabel.add(cssClass: "caption")
        widget.append(child: captionLabel)

        var pendingCompareButton: Button?
        if !otherCaptures.isEmpty {
            let compareRow = Box(orientation: .horizontal, spacing: 8)
            compareRow.marginTop = 6
            let btn = Button(label: "Compare with\u{2026}")
            pendingCompareButton = btn
            compareRow.append(child: btn)
            widget.append(child: compareRow)
        }

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

        let spinner = Spinner()
        spinner.start()
        let loading = Box(orientation: .horizontal, spacing: 8)
        loading.halign = .center
        loading.marginTop = 24
        loading.append(child: spinner)
        let loadingLabel = Label(str: "Decoding capture\u{2026}")
        loading.append(child: loadingLabel)
        bodyContainer.append(child: loading)

        let traceData = capture.traceData
        let metadataJSON = capture.metadataJSON
        Task { @MainActor [weak self] in
            await Task.yield()
            let result: Result<DecodedITrace, Error>
            do {
                let decoded = try ITraceDecoder.decode(traceData: traceData, metadataJSON: metadataJSON)
                result = .success(decoded)
            } catch {
                result = .failure(error)
            }
            self?.applyDecodeResult(result)
        }

        themeSignalID = ThemeWatcher.subscribe(owner: self) { detail in
            detail.handleThemeChanged()
        }

        let modeKey = EventControllerKey()
        modeKey.propagationPhase = GTK_PHASE_CAPTURE
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
            let captureForCompare = capture
            let othersForCompare = otherCaptures
            let formatterForCompare = formatter
            btn.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let button = self?.compareButton else { return }
                    Self.presentComparePopover(
                        anchor: button,
                        capture: captureForCompare,
                        others: othersForCompare,
                        formatter: formatterForCompare
                    )
                }
            }
        }
    }

    deinit {
        ThemeWatcher.unsubscribe(handlerID: themeSignalID)
    }

    fileprivate func handleThemeChanged() {
        let now = ThemeWatcher.isDarkMode()
        guard now != isDarkMode else { return }
        isDarkMode = now
        cfgView?.invalidateDisasm()
    }

    private func applyDecodeResult(_ result: Result<DecodedITrace, Error>) {
        var child = bodyContainer.firstChild
        while let current = child {
            child = current.nextSibling
            bodyContainer.remove(child: current)
        }

        switch result {
        case .failure(let error):
            let errorLabel = Label(str: "Failed to decode capture: \(error)")
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
            buildCFGView(from: decoded)
            applyMode()
        }
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
                let dark = await MainActor.run { self?.isDarkMode ?? false }
                return await d.disassemble(at: addr, size: size, isDarkMode: dark, withFlags: false)
            }
        }

        let arch = engine.session(id: sessionID)?.processInfo?.arch ?? ""
        let view = ITraceCFGView(
            decoded: decoded,
            arch: arch,
            selectedCallIndex: selectedCallIndex,
            disasmProvider: provider
        )
        view.onSelect = { [weak self] key in
            MainActor.assumeIsolated {
                self?.scrollToEntry(matchingNodeKey: key)
            }
        }
        view.onJumpToFunction = { [weak self] index in
            MainActor.assumeIsolated {
                guard let self, let decoded = self.decoded else { return }
                let target = index < 0 ? decoded.functionCalls.count - 1 : index
                guard target >= 0, target < decoded.functionCalls.count else { return }
                self.selectedCallIndex = target
                self.cfgView?.setSelectedCall(index: target)
                self.timeline?.setSelected(index: target)
            }
        }
        view.onNavigateFunction = { [weak self] direction in
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
        capture: ITraceCaptureRecord,
        others: [ITraceCaptureRecord],
        formatter: DateFormatter
    ) {
        let popover = Popover()
        popover.autohide = true

        let listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")

        for other in others {
            let row = ListBoxRow()
            let label = Label(
                str: "\(other.displayName) \u{00B7} \(formatter.string(from: other.capturedAt))"
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
                ITraceDiffView.present(from: anchor, left: capture, right: others[index])
            }
        }

        let scroll = ScrolledWindow()
        scroll.setSizeRequest(width: 320, height: 240)
        scroll.add(cssClass: "luma-popover-scroll")
        scroll.set(child: listBox)

        popover.set(child: WidgetRef(scroll.widget_ptr))
        popover.set(parent: anchor)
        popover.popup()
    }

}
