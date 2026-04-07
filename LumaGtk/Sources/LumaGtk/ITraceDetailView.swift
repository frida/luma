import Foundation
import Gtk
import LumaCore

@MainActor
final class ITraceDetailView {
    let widget: Box

    private let capture: ITraceCaptureRecord
    private let otherCaptures: [ITraceCaptureRecord]
    private let bodyContainer: Box
    private let entriesBox: Box
    private let entriesScroll: ScrolledWindow
    private var entryRows: [ListBoxRow] = []
    private var decoded: DecodedITrace?
    private var cfgView: ITraceCFGView?
    private var modeSwitcher: Box?
    private var listToggle: ToggleButton?
    private var graphToggle: ToggleButton?

    init(capture: ITraceCaptureRecord, otherCaptures: [ITraceCaptureRecord] = []) {
        self.capture = capture
        self.otherCaptures = otherCaptures

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

        if !otherCaptures.isEmpty {
            let compareRow = Box(orientation: .horizontal, spacing: 8)
            compareRow.marginTop = 6
            let compareButton = Button(label: "Compare with\u{2026}")
            let captureForCompare = capture
            let othersForCompare = otherCaptures
            let formatterForCompare = formatter
            compareButton.onClicked { [weak compareButton] _ in
                MainActor.assumeIsolated {
                    guard let compareButton else { return }
                    Self.presentComparePopover(
                        anchor: compareButton,
                        capture: captureForCompare,
                        others: othersForCompare,
                        formatter: formatterForCompare
                    )
                }
            }
            compareRow.append(child: compareButton)
            widget.append(child: compareRow)
        }

        bodyContainer = Box(orientation: .vertical, spacing: 8)
        bodyContainer.hexpand = true
        bodyContainer.vexpand = true
        bodyContainer.marginTop = 12
        widget.append(child: bodyContainer)

        entriesBox = Box(orientation: .vertical, spacing: 0)
        entriesBox.hexpand = true
        entriesScroll = ScrolledWindow()
        entriesScroll.hexpand = true
        entriesScroll.vexpand = true
        entriesScroll.set(child: entriesBox)

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
            bodyContainer.append(child: makeTimeline(functionCalls: decoded.functionCalls))
            bodyContainer.append(child: makeModeSwitcher())
            populateEntries(decoded.entries)
            bodyContainer.append(child: entriesScroll)
        }
    }

    private func makeModeSwitcher() -> Box {
        let row = Box(orientation: .horizontal, spacing: 0)
        row.halign = .start
        row.marginTop = 4
        row.add(cssClass: "linked")

        let list = ToggleButton()
        list.label = "List"
        list.active = true
        let graph = ToggleButton()
        graph.label = "Graph"
        graph.set(group: ToggleButtonRef(list.toggle_button_ptr))

        list.onToggled { [weak self] btn in
            MainActor.assumeIsolated {
                guard btn.active else { return }
                self?.showListMode()
            }
        }
        graph.onToggled { [weak self] btn in
            MainActor.assumeIsolated {
                guard btn.active else { return }
                self?.showGraphMode()
            }
        }

        row.append(child: list)
        row.append(child: graph)
        listToggle = list
        graphToggle = graph
        modeSwitcher = row
        return row
    }

    private func showListMode() {
        if let cfgWidget = cfgView?.widget {
            cfgWidget.visible = false
        }
        entriesScroll.visible = true
    }

    private func showGraphMode() {
        if cfgView == nil, let decoded {
            buildCFGView(from: decoded)
        }
        entriesScroll.visible = false
        if let cfgWidget = cfgView?.widget {
            cfgWidget.visible = true
        }
    }

    private func buildCFGView(from decoded: DecodedITrace) {
        guard !decoded.functionCalls.isEmpty else { return }
        var sections: [(entries: ArraySlice<TraceEntry>, section: Int)] = []
        for (i, call) in decoded.functionCalls.enumerated() {
            let slice = decoded.entries[call.startIndex..<call.endIndex]
            sections.append((entries: slice, section: i))
        }
        let graph = CFGGraph.buildAllFunctions(sections: sections, currentSection: 0)

        var infoMap: [CFGGraph.NodeKey: NodeRegisterInfo] = [:]
        for (i, call) in decoded.functionCalls.enumerated() {
            for entryIdx in call.startIndex..<call.endIndex {
                guard entryIdx < decoded.registerStates.count else { continue }
                let key = CFGGraph.nodeKey(
                    address: decoded.entries[entryIdx].blockAddress, section: i)
                let stateBefore = entryIdx > 0
                    ? decoded.registerStates[entryIdx - 1]
                    : RegisterState(values: [:], changed: [])
                infoMap[key] = NodeRegisterInfo(
                    stateBeforeBlock: stateBefore,
                    stateAfterBlock: decoded.registerStates[entryIdx],
                    writes: decoded.entries[entryIdx].registerWrites
                )
            }
        }

        let view = ITraceCFGView(graph: graph, nodeRegisterInfo: infoMap)
        cfgView = view
        bodyContainer.append(child: view.widget)
    }

    private func makeTimeline(functionCalls: [TraceFunctionCall]) -> ScrolledWindow {
        let row = Box(orientation: .horizontal, spacing: 2)
        row.marginTop = 4
        row.marginBottom = 4

        for call in functionCalls {
            let button = Button(label: "\(call.shortName) · \(call.entryCount)")
            let width = max(40, call.entryCount * 4)
            button.setSizeRequest(width: width, height: 28)
            let bucket = abs(stableHash(call.functionName)) % 8
            button.add(cssClass: "luma-itrace-fn-\(bucket)")
            let startIndex = call.startIndex
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.jumpToEntry(index: startIndex)
                }
            }
            row.append(child: button)
        }

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.setSizeRequest(width: -1, height: 44)
        scroll.set(child: row)
        return scroll
    }

    private func populateEntries(_ entries: [TraceEntry]) {
        var child = entriesBox.firstChild
        while let current = child {
            child = current.nextSibling
            entriesBox.remove(child: current)
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
            label.selectable = true
            row.set(child: label)
            entriesBox.append(child: row)
            entryRows.append(row)
        }
    }

    private func jumpToEntry(index: Int) {
        guard index >= 0, index < entryRows.count else { return }
        _ = entryRows[index].grabFocus()
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

        listBox.onRowSelected { [weak popover, weak anchor] _, row in
            MainActor.assumeIsolated {
                guard let row, let anchor else { return }
                let index = Int(row.index)
                guard index >= 0, index < others.count else { return }
                popover?.popdown()
                ITraceDiffView.present(from: anchor, left: capture, right: others[index])
            }
        }

        let scroll = ScrolledWindow()
        scroll.setSizeRequest(width: 320, height: 240)
        scroll.set(child: listBox)

        popover.set(child: WidgetRef(scroll.widget_ptr))
        popover.set(parent: anchor)
        popover.popup()
    }

    private func stableHash(_ s: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Int(truncatingIfNeeded: hash)
    }
}
