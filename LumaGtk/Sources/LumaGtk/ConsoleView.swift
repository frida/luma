import CGraphene
import CGtk
import Foundation
import Gdk
import struct Graphene.PointRef
import Gtk
import LumaCore

@MainActor
final class ConsoleView {
    let widget: Box

    struct Style {
        var promptGlyph: String = "\u{203A}"
        var placeholder: String = ""
        var runButtonLabel: String = "Run"
    }

    var onSubmit: ((String) -> Void)?
    var onComplete: (@MainActor (_ code: String, _ cursor: Int) async -> [REPLCompletion])?
    var onBackgroundContextMenu: ((_ anchor: Widget, _ x: Double, _ y: Double) -> Void)?
    var onInputChanged: ((String) -> Void)?
    var onPromptClicked: (() -> Void)?
    var onHistoryRecalled: ((String) -> Void)?
    var commandInterceptor: ((String) -> Bool)?
    var completionReplacesWholeToken = false

    private let style: Style
    private let emptyState: Widget
    private let cellsBox: Box
    private let cellsScroll: ScrolledWindow
    private let scroller: BottomScroller
    private let contentSlot: Box
    private let prompt: Label
    private let inputEntry: Entry
    private let runButton: Button
    private var hasEntries = false

    private var history: [String] = []
    private var historyCursor: Int = 0
    private var draftBeforeHistory: String = ""

    private var completionTask: Task<Void, Never>?
    private var completionDebounceTask: Task<Void, Never>?
    private var completionGeneration: UInt = 0
    private var suppressingChanged = false
    private var completionPopover: Popover?
    private var completionList: ListBox?
    private var completionScroll: ScrolledWindow?
    private var completionItems: [REPLCompletion] = []
    private var completionBaseCode: String = ""

    init(style: Style, emptyState: Widget) {
        self.style = style
        self.emptyState = emptyState

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        cellsBox = Box(orientation: .vertical, spacing: 4)
        cellsBox.marginStart = 12
        cellsBox.marginEnd = 16
        cellsBox.marginTop = 12
        cellsBox.marginBottom = 12
        cellsBox.hexpand = true
        cellsBox.vexpand = true
        cellsBox.valign = .end

        cellsScroll = ScrolledWindow()
        cellsScroll.hexpand = true
        cellsScroll.vexpand = true
        cellsScroll.add(cssClass: "view")
        cellsScroll.set(child: cellsBox)
        scroller = BottomScroller(cellsScroll, threshold: 2.0)

        contentSlot = Box(orientation: .vertical, spacing: 0)
        contentSlot.hexpand = true
        contentSlot.vexpand = true
        contentSlot.append(child: emptyState)
        widget.append(child: contentSlot)

        widget.append(child: Separator(orientation: .horizontal))

        let inputRow = Box(orientation: .horizontal, spacing: 8)
        inputRow.marginStart = 12
        inputRow.marginEnd = 12
        inputRow.marginTop = 6
        inputRow.marginBottom = 6

        prompt = Label(str: style.promptGlyph)
        prompt.add(cssClass: "monospace")
        prompt.add(cssClass: "dim-label")
        inputRow.append(child: prompt)

        inputEntry = Entry()
        inputEntry.hexpand = true
        inputEntry.placeholderText = style.placeholder
        inputEntry.add(cssClass: "monospace")
        inputRow.append(child: inputEntry)

        runButton = Button(label: style.runButtonLabel)
        runButton.add(cssClass: "suggested-action")
        inputRow.append(child: runButton)

        widget.append(child: inputRow)

        installInputHandlers()
        installBackgroundContextMenu()
    }

    func appendEntry(_ child: Widget) {
        if !hasEntries {
            showCellList()
            hasEntries = true
        }
        cellsBox.append(child: child)
        scroller.pin()
    }

    func pinToBottom() {
        scroller.pin()
    }

    func clearEntries() {
        clearChildren(of: cellsBox)
        hasEntries = false
        showEmptyState()
    }

    func setInputEnabled(_ enabled: Bool, placeholder: String? = nil) {
        inputEntry.sensitive = enabled
        runButton.sensitive = enabled
        inputEntry.placeholderText = placeholder ?? style.placeholder
    }

    func focusInput() {
        _ = inputEntry.grabFocus()
    }

    func setPromptMarkup(_ markup: String) {
        prompt.remove(cssClass: "dim-label")
        prompt.useMarkup = true
        prompt.setMarkup(str: markup)
    }

    func setInputText(_ text: String) {
        replaceInput(with: text)
    }

    func setHistory(_ items: [String]) {
        history = items
        historyCursor = history.count
        draftBeforeHistory = ""
    }

    func appendHistory(_ item: String) {
        history.append(item)
        historyCursor = history.count
        draftBeforeHistory = ""
    }

    private func installInputHandlers() {
        inputEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.submit() }
        }
        inputEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suppressingChanged else { return }
                self.onInputChanged?(self.inputEntry.text ?? "")
                self.scheduleCompletionRequest()
            }
        }
        runButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.submit() }
        }

        let promptClick = GestureClick()
        promptClick.set(button: 1)
        promptClick.onPressed { [weak self] _, _, _, _ in
            MainActor.assumeIsolated { self?.onPromptClicked?() }
        }
        prompt.install(controller: promptClick)

        let keyController = EventControllerKey()
        keyController.propagationPhase = .capture
        keyController.onKeyPressed { [weak self] _, keyval, _, _ in
            return MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKeyPress(keyval: keyval)
            }
        }
        inputEntry.install(controller: keyController)
    }

    private func installBackgroundContextMenu() {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self, self.hasEntries, let handler = self.onBackgroundContextMenu else { return }
                handler(self.cellsScroll, x, y)
            }
        }
        cellsScroll.install(controller: gesture)
    }

    private func submit() {
        let raw = inputEntry.text ?? ""
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        if commandInterceptor?(code) == true {
            inputEntry.text = ""
            return
        }
        inputEntry.text = ""
        appendHistory(code)
        onSubmit?(code)
    }

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
        guard !history.isEmpty else { return }
        if historyCursor == history.count {
            draftBeforeHistory = inputEntry.text ?? ""
        }
        if historyCursor > 0 {
            historyCursor -= 1
        }
        replaceInput(with: history[historyCursor])
        onHistoryRecalled?(history[historyCursor])
    }

    private func historyNext() {
        guard !history.isEmpty else { return }
        if historyCursor < history.count - 1 {
            historyCursor += 1
            replaceInput(with: history[historyCursor])
            onHistoryRecalled?(history[historyCursor])
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
            self?.requestCompletion()
        }
    }

    private func requestCompletion() {
        guard let onComplete else { return }
        let code = inputEntry.text ?? ""
        let cursor = code.count
        completionTask?.cancel()
        let gen = completionGeneration
        completionTask = Task { @MainActor in
            let suggestions = await onComplete(code, cursor)
            guard !Task.isCancelled, self.completionGeneration == gen, (inputEntry.text ?? "") == code else { return }
            guard !suggestions.isEmpty else {
                self.dismissCompletionPopover()
                return
            }
            self.showCompletionPopover(suggestions: suggestions)
        }
    }

    private func applyCompletion(to code: String, suggestion: REPLCompletion) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._$"))
        let scalars = Array(code.unicodeScalars)
        var start = scalars.count
        while start > 0, allowed.contains(scalars[start - 1]) {
            start -= 1
        }
        let token = String(String.UnicodeScalarView(scalars[start..<scalars.count]))
        let before = String(String.UnicodeScalarView(scalars[0..<start]))
        let insert = suggestion.insertText

        let newToken: String
        if completionReplacesWholeToken {
            newToken = insert
        } else if let dotIdx = token.lastIndex(of: ".") {
            let baseExpr = String(token[..<dotIdx])
            let lastSegment = insert.lastIndex(of: ".").map { String(insert[insert.index(after: $0)...]) } ?? insert
            newToken = baseExpr + "." + lastSegment
        } else {
            newToken = insert
        }

        replaceInput(with: before + newToken)
    }

    private func showCompletionPopover(suggestions: [REPLCompletion]) {
        dismissCompletionPopover()

        let popover = Popover()
        popover.autohide = false
        popover.canFocus = false

        let listBox = ListBox()
        listBox.selectionMode = .single
        listBox.canFocus = false
        listBox.add(cssClass: "boxed-list")
        listBox.setSizeRequest(width: 280, height: -1)
        let titleGroup = SizeGroup(mode: .horizontal)
        for suggestion in suggestions {
            let row = ListBoxRow()
            row.canFocus = false
            let line = Box(orientation: .horizontal, spacing: 12)
            line.marginStart = 8
            line.marginEnd = 8
            line.marginTop = 4
            line.marginBottom = 4
            let title = Label(str: suggestion.displayText)
            title.add(cssClass: "monospace")
            title.halign = .start
            title.xalign = 0
            titleGroup.add(widget: title)
            line.append(child: title)
            if let detail = suggestion.detailText {
                let detailLabel = Label(str: detail)
                detailLabel.add(cssClass: "dim-label")
                detailLabel.add(cssClass: "caption")
                detailLabel.halign = .start
                line.append(child: detailLabel)
            }
            row.set(child: line)
            listBox.append(child: row)
        }
        listBox.onRowActivated { [weak self] _, _ in
            MainActor.assumeIsolated { self?.acceptSelectedCompletion() }
        }

        let inlineRowLimit = 6
        if suggestions.count > inlineRowLimit {
            let scroll = ScrolledWindow()
            scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
            scroll.propagateNaturalHeight = true
            scroll.maxContentHeight = 160
            scroll.set(child: listBox)
            popover.set(child: scroll)
            completionScroll = scroll
        } else {
            popover.set(child: listBox)
        }
        popover.set(parent: inputEntry)
        popover.position = .bottom

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

        let approxLeftPadding: Int32 = 8
        let entryHeight = inputEntry.height
        return (
            x: Double(prefixWidth + approxLeftPadding),
            y: 0,
            width: 1,
            height: Double(entryHeight)
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
            scrollCompletionRowIntoView(row)
        }
    }

    private func scrollCompletionRowIntoView(_ row: ListBoxRowRef) {
        guard let scroll = completionScroll,
              let listBox = completionList,
              let vadj = scroll.vadjustment else { return }
        var source = graphene_point_t(x: 0, y: 0)
        var destination = graphene_point_t(x: 0, y: 0)
        let translated = withUnsafeMutablePointer(to: &source) { srcPtr in
            withUnsafeMutablePointer(to: &destination) { dstPtr in
                row.computePoint(target: listBox, point: PointRef(srcPtr), outPoint: PointRef(dstPtr))
            }
        }
        guard translated else { return }
        let rowY = Double(destination.y)
        vadj.clampPage(lower: rowY, upper: rowY + Double(row.height))
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
        completionPopover?.unparent()
        completionPopover = nil
        completionList = nil
        completionScroll = nil
        completionItems = []
    }

    private func showEmptyState() {
        if cellsScroll.parent != nil {
            contentSlot.remove(child: cellsScroll)
        }
        if emptyState.parent == nil {
            contentSlot.append(child: emptyState)
        }
    }

    private func showCellList() {
        if emptyState.parent != nil {
            contentSlot.remove(child: emptyState)
        }
        if cellsScroll.parent == nil {
            contentSlot.append(child: cellsScroll)
        }
    }


    private func clearChildren(of container: Box) {
        while let child = container.firstChild {
            container.remove(child: child)
        }
    }
}
