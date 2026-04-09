import CGtk
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class REPLPane {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let bannerSlot: Box
    private var currentBanner: Widget?
    private let cellsBox: Box
    private let cellsScroll: ScrolledWindow
    private let inputEntry: Entry
    private let runButton: Button
    private let timeFormatter: DateFormatter
    private weak var owner: MainWindow?

    private var cells: [LumaCore.REPLCell] = []
    private var rowKeepers: [Any] = []
    private var historyCursor: Int = 0
    private var draftBeforeHistory: String = ""
    private var completionTask: Task<Void, Never>?
    private var completionDebounceTask: Task<Void, Never>?
    private var completionGeneration: UInt = 0
    private var suppressingChanged = false
    private var completionPopover: Popover?
    private var completionList: ListBox?
    private var completionItems: [String] = []
    private var completionBaseCode: String = ""

    init(engine: Engine, sessionID: UUID, owner: MainWindow? = nil) {
        self.engine = engine
        self.sessionID = sessionID
        self.owner = owner

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        bannerSlot = Box(orientation: .vertical, spacing: 0)
        bannerSlot.hexpand = true
        widget.append(child: bannerSlot)

        cellsBox = Box(orientation: .vertical, spacing: 4)
        cellsBox.marginStart = 16
        cellsBox.marginEnd = 16
        cellsBox.marginTop = 12
        cellsBox.marginBottom = 12
        cellsBox.hexpand = true
        cellsBox.vexpand = true
        cellsBox.valign = .end

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
        inputEntry.add(cssClass: "monospace")
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
        inputEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suppressingChanged else { return }
                self.scheduleCompletionRequest()
            }
        }
        runButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.submit()
            }
        }

        let keyController = EventControllerKey()
        keyController.propagationPhase = GTK_PHASE_CAPTURE
        keyController.onKeyPressed { [weak self] _, keyval, _, _ in
            return MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKeyPress(keyval: keyval)
            }
        }
        inputEntry.install(controller: keyController)

        loadCells()
        refresh()
        applySessionState()
    }

    func applySessionState() {
        guard let engine else { return }
        let session = engine.sessions.first(where: { $0.id == sessionID })
        let isAttached = engine.node(forSessionID: sessionID) != nil

        inputEntry.sensitive = isAttached
        runButton.sensitive = isAttached
        inputEntry.placeholderText =
            isAttached
            ? "Enter JavaScript\u{2026}"
            : "Session detached — re-establish to continue."

        let wantsBanner = session.map { SessionDetachedBanner.shouldShow(for: $0) } ?? false
        let bannerChanging = wantsBanner != (currentBanner != nil)
        if bannerChanging, let rootPtr = widget.root?.ptr {
            WindowRef(raw: rootPtr).focus = nil
        }

        if let session, wantsBanner {
            let banner = SessionDetachedBanner.make(for: session) { [weak self] in
                self?.owner?.reestablishSession(id: session.id)
            }
            if let existing = currentBanner {
                bannerSlot.remove(child: existing)
            }
            bannerSlot.append(child: banner)
            currentBanner = banner
        } else if let existing = currentBanner {
            bannerSlot.remove(child: existing)
            currentBanner = nil
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
        if completionPopover != nil {
            if key == Gdk.keyEscape {
                dismissCompletionPopover()
                return true
            }
            if key == Gdk.keyUp {
                moveCompletionSelection(delta: -1)
                return true
            }
            if key == Gdk.keyDown {
                moveCompletionSelection(delta: 1)
                return true
            }
            if key == Gdk.keyTab || key == Gdk.keyISOLeftTab
                || key == Gdk.keyReturn || key == Gdk.keyKPEnter || key == Gdk.keyISOEnter
            {
                acceptSelectedCompletion()
                return true
            }
        }
        if key == Gdk.keyReturn || key == Gdk.keyKPEnter || key == Gdk.keyISOEnter {
            submit()
            return true
        }
        if key == Gdk.keyUp {
            historyPrevious()
            return true
        }
        if key == Gdk.keyDown {
            historyNext()
            return true
        }
        if key == Gdk.keyTab || key == Gdk.keyISOLeftTab {
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
        suppressingChanged = true
        defer { suppressingChanged = false }
        inputEntry.text = text
        inputEntry.position = -1
        inputEntry.selectRegion(startPos: -1, endPos: -1)
    }

    private func scheduleCompletionRequest() {
        completionDebounceTask?.cancel()
        let text = inputEntry.text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completionTask?.cancel()
            dismissCompletionPopover()
            return
        }
        let gen = completionGeneration
        completionDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, self?.completionGeneration == gen else { return }
            self?.requestCompletion(showPopoverOnly: true)
        }
    }

    private func requestCompletion(showPopoverOnly: Bool = false) {
        guard let node = engine?.node(forSessionID: sessionID) else { return }
        let code = inputEntry.text ?? ""
        let cursor = code.count
        completionTask?.cancel()
        let gen = completionGeneration
        completionTask = Task { @MainActor in
            let suggestions = await node.completeInREPL(code: code, cursor: cursor)
            guard !Task.isCancelled, self.completionGeneration == gen, (inputEntry.text ?? "") == code else { return }
            guard !suggestions.isEmpty else {
                self.dismissCompletionPopover()
                return
            }
            self.showCompletionPopover(suggestions: suggestions)
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

    private func showCompletionPopover(suggestions: [String]) {
        dismissCompletionPopover()

        let popover = Popover()
        popover.autohide = false
        popover.canFocus = false

        let scroll = ScrolledWindow()
        scroll.setPolicy(hscrollbarPolicy: GTK_POLICY_NEVER, vscrollbarPolicy: GTK_POLICY_AUTOMATIC)
        scroll.setSizeRequest(width: 280, height: min(160, 24 * suggestions.count + 8))

        let listBox = ListBox()
        listBox.selectionMode = .single
        listBox.canFocus = false
        listBox.add(cssClass: "boxed-list")
        for suggestion in suggestions {
            let row = ListBoxRow()
            row.canFocus = false
            let label = Label(str: suggestion)
            label.add(cssClass: "monospace")
            label.halign = .start
            label.marginStart = 8
            label.marginEnd = 8
            label.marginTop = 4
            label.marginBottom = 4
            row.set(child: label)
            listBox.append(child: row)
        }
        listBox.onRowActivated { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.acceptSelectedCompletion()
            }
        }

        scroll.set(child: listBox)
        popover.set(child: scroll)
        popover.set(parent: inputEntry)
        popover.position = GTK_POS_BOTTOM

        completionPopover = popover
        completionList = listBox
        completionItems = suggestions
        completionBaseCode = inputEntry.text ?? ""

        if let first = listBox.getRowAt(index: 0) {
            listBox.select(row: first)
        }

        let caret = caretRectInEntry()
        var rect = GdkRectangle(
            x: gint(caret.x),
            y: gint(caret.y),
            width: gint(caret.width),
            height: gint(caret.height)
        )
        withUnsafeMutablePointer(to: &rect) { ptr in
            gtk_popover_set_pointing_to(popover.popover_ptr, ptr)
        }
        popover.popup()
    }

    private func caretRectInEntry() -> (x: Double, y: Double, width: Double, height: Double) {
        let text = inputEntry.text ?? ""
        let position = Int(inputEntry.position)
        let clamped = max(0, min(position, text.count))
        let prefix = String(text.prefix(clamped))

        let layoutPtr = gtk_widget_create_pango_layout(inputEntry.widget_ptr, prefix)
        defer { if let p = layoutPtr { g_object_unref(p) } }

        var prefixWidth: Int32 = 0
        var unusedHeight: Int32 = 0
        if let layoutPtr {
            pango_layout_get_pixel_size(layoutPtr, &prefixWidth, &unusedHeight)
        }

        let height = inputEntry.allocatedHeight
        let approxLeftPadding: Int32 = 8
        return (
            x: Double(prefixWidth + approxLeftPadding),
            y: Double(height),
            width: 1,
            height: 1
        )
    }

    private func moveCompletionSelection(delta: Int) {
        guard let listBox = completionList, !completionItems.isEmpty else { return }
        let current = listBox.selectedRow.map { Int($0.index) } ?? -1
        var next = current + delta
        if next < 0 { next = completionItems.count - 1 }
        if next >= completionItems.count { next = 0 }
        if let row = listBox.getRowAt(index: next) {
            listBox.select(row: row)
        }
    }

    private func acceptSelectedCompletion() {
        guard let listBox = completionList else { return }
        let idx = listBox.selectedRow.map { Int($0.index) } ?? 0
        guard idx >= 0, idx < completionItems.count else {
            dismissCompletionPopover()
            return
        }
        let suggestion = completionItems[idx]
        let base = completionBaseCode
        dismissCompletionPopover()
        applyCompletion(to: base, suggestion: suggestion)
    }

    private func dismissCompletionPopover() {
        completionGeneration &+= 1
        completionDebounceTask?.cancel()
        completionDebounceTask = nil
        completionTask?.cancel()
        completionTask = nil
        completionPopover?.popdown()
        completionPopover = nil
        completionList = nil
        completionItems = []
    }

    func focusInput() {
        _ = inputEntry.grabFocus()
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

    func appendCell(_ cell: LumaCore.REPLCell) {
        guard cell.sessionID == sessionID else { return }
        cells.append(cell)
        historyCursor = orderedHistory.count
        cellsBox.append(child: makeRow(for: cell))
        scrollToBottomSoon()
    }

    private func refresh() {
        clearChildren(of: cellsBox)
        rowKeepers.removeAll()
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

        let resultRow = Box(orientation: .horizontal, spacing: 8)
        resultRow.hexpand = true
        let resultArrow = Label(str: "←")
        resultArrow.add(cssClass: "monospace")
        resultArrow.add(cssClass: "dim-label")
        resultArrow.valign = .start
        resultRow.append(child: resultArrow)

        let resultWidget: Widget
        switch cell.result {
        case .js(let value):
            if let engine {
                let wrapper = JSInspectValueWidget.make(value: value, engine: engine, sessionID: sessionID)
                rowKeepers.append(wrapper)
                resultWidget = wrapper.widget
            } else {
                resultWidget = makePlainResultLabel(text: format(result: cell.result))
            }
        case .binary(let data, let meta):
            let column2 = Box(orientation: .vertical, spacing: 4)
            column2.hexpand = true
            column2.halign = .start
            let kind = meta?.typedArray ?? "binary"
            let header = Label(str: "<\(kind) \(data.count) bytes>")
            header.add(cssClass: "monospace")
            header.halign = .start
            column2.append(child: header)
            let hex = HexView(bytes: data)
            rowKeepers.append(hex)
            hex.widget.hexpand = true
            hex.widget.vexpand = false
            hex.widget.halign = .start
            column2.append(child: hex.widget)
            resultWidget = column2
        case .text:
            resultWidget = makePlainResultLabel(text: format(result: cell.result))
        }
        resultWidget.hexpand = true
        resultWidget.halign = .start
        resultRow.append(child: resultWidget)
        column.append(child: resultRow)

        attachContextMenu(to: column, cell: cell)

        return column
    }

    private func makePlainResultLabel(text: String) -> Widget {
        let label = Label(str: text)
        label.add(cssClass: "monospace")
        label.halign = .start
        label.hexpand = true
        label.wrap = true
        label.selectable = true
        return label
    }

    private func attachContextMenu(to anchor: Box, cell: LumaCore.REPLCell) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.onPressed { [anchor, weak self] _, _, x, y in
            MainActor.assumeIsolated {
                self?.presentCellContextMenu(at: anchor, x: x, y: y, cell: cell)
            }
        }
        anchor.install(controller: gesture)
    }

    private func presentCellContextMenu(at anchor: Widget, x: Double, y: Double, cell: LumaCore.REPLCell) {
        ContextMenu.present([
            [
                .init("Add to Notebook") { [weak self] in
                    self?.addCellToNotebook(cell)
                },
            ],
        ], at: anchor, x: x, y: y)
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
