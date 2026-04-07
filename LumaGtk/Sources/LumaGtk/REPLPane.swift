import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class REPLPane {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let cellsBox: Box
    private let cellsScroll: ScrolledWindow
    private let inputEntry: Entry
    private let runButton: Button
    private let timeFormatter: DateFormatter

    private var cells: [LumaCore.REPLCell] = []
    private var observation: StoreObservation?
    private var historyCursor: Int = 0
    private var draftBeforeHistory: String = ""
    private var completionTask: Task<Void, Never>?

    init(engine: Engine, sessionID: UUID) {
        self.engine = engine
        self.sessionID = sessionID

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        cellsBox = Box(orientation: .vertical, spacing: 4)
        cellsBox.marginStart = 16
        cellsBox.marginEnd = 16
        cellsBox.marginTop = 12
        cellsBox.marginBottom = 12
        cellsBox.hexpand = true

        cellsScroll = ScrolledWindow()
        cellsScroll.hexpand = true
        cellsScroll.vexpand = true
        cellsScroll.set(child: cellsBox)
        widget.append(child: cellsScroll)

        widget.append(child: Separator(orientation: .horizontal))

        let inputRow = Box(orientation: .horizontal, spacing: 8)
        inputRow.marginStart = 12
        inputRow.marginEnd = 12
        inputRow.marginTop = 6
        inputRow.marginBottom = 6

        let prompt = Label(str: "›")
        prompt.add(cssClass: "monospace")
        prompt.add(cssClass: "dim-label")
        inputRow.append(child: prompt)

        inputEntry = Entry()
        inputEntry.hexpand = true
        inputEntry.placeholderText = "Enter JavaScript\u{2026}"
        inputRow.append(child: inputEntry)

        runButton = Button(label: "Run")
        runButton.add(cssClass: "suggested-action")
        inputRow.append(child: runButton)

        widget.append(child: inputRow)

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        inputEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated {
                self?.submit()
            }
        }
        runButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.submit()
            }
        }

        let keyController = EventControllerKey()
        keyController.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                self?.handleKeyPress(keyval: keyval) ?? false
            }
        }
        inputEntry.add(controller: keyController)

        loadCells()
        observation = engine.store.observeREPLCells(sessionID: sessionID) { [weak self] newCells in
            Task { @MainActor in
                self?.cells = newCells
                self?.refresh()
            }
        }
        refresh()
        updateInputState()
    }


    func updateInputState() {
        let isAttached = engine?.node(forSessionID: sessionID) != nil
        inputEntry.sensitive = isAttached
        runButton.sensitive = isAttached
        if !isAttached {
            inputEntry.placeholderText = "Session detached — re-establish to continue."
        } else {
            inputEntry.placeholderText = "Enter JavaScript\u{2026}"
        }
    }

    private func loadCells() {
        guard let engine else { return }
        cells = (try? engine.store.fetchREPLCells(sessionID: sessionID)) ?? []
        historyCursor = orderedHistory.count
    }

    private var orderedHistory: [LumaCore.REPLCell] {
        cells
            .filter { !$0.isSessionBoundary }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func submit() {
        let raw = inputEntry.text ?? ""
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let node = engine?.node(forSessionID: sessionID) else {
            return
        }
        inputEntry.text = ""
        historyCursor = orderedHistory.count + 1
        draftBeforeHistory = ""
        Task { @MainActor in
            await node.evalInREPL(code)
        }
    }

    // MARK: - History + completion

    private func handleKeyPress(keyval: UInt) -> Bool {
        let key = Int32(keyval)
        if key == Gdk.keyUp {
            historyPrevious()
            return true
        }
        if key == Gdk.keyDown {
            historyNext()
            return true
        }
        if key == Gdk.keyTab {
            requestCompletion()
            return true
        }
        return false
    }

    private func historyPrevious() {
        let history = orderedHistory
        guard !history.isEmpty else { return }
        if historyCursor == history.count {
            draftBeforeHistory = inputEntry.text ?? ""
        }
        if historyCursor > 0 {
            historyCursor -= 1
        }
        replaceInput(with: history[historyCursor].code)
    }

    private func historyNext() {
        let history = orderedHistory
        guard !history.isEmpty else { return }
        if historyCursor < history.count - 1 {
            historyCursor += 1
            replaceInput(with: history[historyCursor].code)
        } else {
            historyCursor = history.count
            replaceInput(with: draftBeforeHistory)
            draftBeforeHistory = ""
        }
    }

    private func replaceInput(with text: String) {
        inputEntry.text = text
        inputEntry.position = -1
    }

    private func requestCompletion() {
        guard let node = engine?.node(forSessionID: sessionID) else { return }
        let code = inputEntry.text ?? ""
        let cursor = code.count
        completionTask?.cancel()
        completionTask = Task { @MainActor in
            let suggestions = await node.completeInREPL(code: code, cursor: cursor)
            guard !Task.isCancelled, !suggestions.isEmpty else { return }
            // Insert the longest common prefix of all suggestions, or the
            // single suggestion if only one was returned. The SwiftUI app
            // shows a popdown picker; we keep it minimal here.
            let common = longestCommonPrefix(suggestions)
            guard !common.isEmpty else { return }
            self.replaceInput(with: code + common)
        }
    }

    private func longestCommonPrefix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    private func refresh() {
        clearChildren(of: cellsBox)
        for cell in cells.sorted(by: { $0.timestamp < $1.timestamp }) {
            cellsBox.append(child: makeRow(for: cell))
        }
    }

    private func makeRow(for cell: LumaCore.REPLCell) -> Widget {
        if cell.isSessionBoundary {
            let bar = Box(orientation: .horizontal, spacing: 8)
            bar.marginTop = 6
            bar.marginBottom = 6
            let separator = Separator(orientation: .horizontal)
            separator.hexpand = true
            separator.valign = .center
            let label = Label(str: cell.code)
            label.add(cssClass: "dim-label")
            label.add(cssClass: "caption")
            bar.append(child: separator)
            bar.append(child: label)
            return bar
        }

        let column = Box(orientation: .vertical, spacing: 2)
        column.hexpand = true

        let codeRow = Box(orientation: .horizontal, spacing: 8)
        let prompt = Label(str: "›")
        prompt.add(cssClass: "monospace")
        prompt.add(cssClass: "dim-label")
        codeRow.append(child: prompt)
        let codeLabel = Label(str: cell.code)
        codeLabel.add(cssClass: "monospace")
        codeLabel.halign = .start
        codeLabel.hexpand = true
        codeLabel.wrap = true
        codeLabel.selectable = true
        codeRow.append(child: codeLabel)
        column.append(child: codeRow)

        let resultWidget: Widget
        if case .js(let value) = cell.result, let engine {
            resultWidget = JSInspectValueWidget.make(value: value, engine: engine, sessionID: sessionID)
        } else {
            let label = Label(str: format(result: cell.result))
            label.add(cssClass: "monospace")
            label.halign = .start
            label.hexpand = true
            label.wrap = true
            label.selectable = true
            resultWidget = label
        }
        resultWidget.marginStart = 16
        resultWidget.halign = .start
        column.append(child: resultWidget)

        return column
    }

    private func format(result: LumaCore.REPLCell.Result) -> String {
        switch result {
        case .text(let s):
            return s
        case .js(let value):
            return value.prettyDescription()
        case .binary(let data, let meta):
            let kind = meta?.typedArray ?? "binary"
            return "<\(kind) \(data.count) bytes>"
        }
    }

    private func clearChildren(of container: Box) {
        var child = container.firstChild
        while let current = child {
            child = current.nextSibling
            container.remove(child: current)
        }
    }
}
