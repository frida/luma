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
    private let clearButton: Button
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

        clearButton = Button(label: "Clear")
        clearButton.add(cssClass: "flat")
        inputRow.append(child: clearButton)

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
        clearButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearHistory()
            }
        }

        let keyController = EventControllerKey()
        keyController.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                self?.handleKeyPress(keyval: keyval) ?? false
            }
        }
        inputEntry.install(controller: keyController)

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
            let common = longestCommonPrefix(suggestions)
            guard !common.isEmpty else { return }
            self.applyCompletion(to: code, suggestion: common)
        }
    }

    private func applyCompletion(to code: String, suggestion: String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._$"))
        let scalars = Array(code.unicodeScalars)
        var start = scalars.count
        while start > 0, allowed.contains(scalars[start - 1]) {
            start -= 1
        }
        let token = String(String.UnicodeScalarView(scalars[start..<scalars.count]))
        let before = String(String.UnicodeScalarView(scalars[0..<start]))

        let newToken: String
        if let dotIdx = token.lastIndex(of: ".") {
            let baseExpr = String(token[..<dotIdx])
            let lastSegment: String
            if let sugDot = suggestion.lastIndex(of: ".") {
                lastSegment = String(suggestion[suggestion.index(after: sugDot)...])
            } else {
                lastSegment = suggestion
            }
            newToken = baseExpr + "." + lastSegment
        } else {
            newToken = suggestion
        }

        replaceInput(with: before + newToken)
    }

    private func clearHistory() {
        cells.removeAll()
        historyCursor = 0
        draftBeforeHistory = ""
        refresh()
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
        scrollToBottomSoon()
    }

    private func scrollToBottomSoon() {
        Task { @MainActor in
            guard let adj = cellsScroll.vadjustment else { return }
            let target = adj.upper - adj.pageSize
            if target > adj.value {
                adj.value = target
            }
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

        attachContextMenu(to: column, cell: cell)

        return column
    }

    private func attachContextMenu(to anchor: Box, cell: LumaCore.REPLCell) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.onPressed { [weak anchor, weak self] _, _, _, _ in
            MainActor.assumeIsolated {
                guard let anchor, let self else { return }
                self.presentCellContextMenu(at: anchor, cell: cell)
            }
        }
        anchor.install(controller: gesture)
    }

    private func presentCellContextMenu(at anchor: Widget, cell: LumaCore.REPLCell) {
        let popover = Popover()
        popover.autohide = true

        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let addButton = Button(label: "Add to Notebook")
        addButton.add(cssClass: "flat")
        addButton.onClicked { [weak popover, weak self] _ in
            MainActor.assumeIsolated {
                popover?.popdown()
                self?.addCellToNotebook(cell)
            }
        }
        box.append(child: addButton)

        popover.set(child: WidgetRef(box.widget_ptr))
        popover.set(parent: anchor)
        popover.popup()
    }

    private func addCellToNotebook(_ cell: LumaCore.REPLCell) {
        guard let engine else { return }
        let processName = engine.sessions.first { $0.id == sessionID }?.processName ?? ""

        let details: String
        var binary: Data? = nil
        var jsValue: LumaCore.JSInspectValue? = nil
        switch cell.result {
        case .text(let s):
            details = s
        case .js(let v):
            details = ""
            jsValue = v
        case .binary(let data, let meta):
            details = meta?.typedArray ?? ""
            binary = data
        }

        var entry = LumaCore.NotebookEntry(
            title: cell.code,
            details: details,
            binaryData: binary,
            sessionID: sessionID,
            processName: processName
        )
        if let jsValue {
            entry.jsValue = jsValue
        }
        engine.addNotebookEntry(entry)
    }

    private func format(result: LumaCore.REPLCell.Result) -> String {
        switch result {
        case .text(let s):
            return s
        case .js(let value):
            return value.prettyDescription()
        case .binary(let data, let meta):
            let kind = meta?.typedArray ?? "binary"
            let header = "<\(kind) \(data.count) bytes>\n"
            return header + Self.formatHexdumpPreview(data: data, maxLines: 4)
        }
    }

    private static func formatHexdumpPreview(data: Data, maxLines: Int) -> String {
        if data.isEmpty {
            return "<no data>"
        }
        let bytes = [UInt8](data)
        let total = bytes.count
        let cap = min(total, maxLines * 16)
        var out = ""
        var i = 0
        while i < cap {
            out += String(format: "0x%016llx  ", UInt64(i))
            var hexPart = ""
            var asciiPart = ""
            for col in 0..<16 {
                let idx = i + col
                if col == 8 {
                    hexPart += " "
                }
                if idx < cap {
                    let b = bytes[idx]
                    hexPart += String(format: "%02x", b)
                    if (0x20...0x7e).contains(b) {
                        asciiPart.append(Character(UnicodeScalar(b)))
                    } else {
                        asciiPart.append(".")
                    }
                } else {
                    hexPart += "  "
                    asciiPart.append(" ")
                }
                if col != 15 {
                    hexPart += " "
                }
            }
            out += hexPart + "  |" + asciiPart + "|\n"
            i += 16
        }
        if total > cap {
            out += "\u{2026} (total \(total) bytes)"
        }
        return out
    }

    private func clearChildren(of container: Box) {
        var child = container.firstChild
        while let current = child {
            child = current.nextSibling
            container.remove(child: current)
        }
    }
}
