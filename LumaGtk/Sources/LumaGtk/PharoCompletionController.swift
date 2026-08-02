import CGraphene
import CGtk
import Foundation
import Gdk
import struct Graphene.PointRef
import Gtk
import GtkSource
import SwiftyPharo

/// Drives an on-demand completion popover for the Pharo playground editor,
/// asking the runtime what identifiers complete the token at the caret and
/// replacing that token when one is chosen.
@MainActor
final class PharoCompletionController {
    private let editor: GtkSource.View
    private let buffer: GtkSource.Buffer
    private let suggest: (String, Int) async -> PharoCompletions?

    private var popover: Popover?
    private var list: ListBox?
    private var scroll: ScrolledWindow?
    private var candidates: [String] = []
    private var tokenStart = 0
    private var generation: UInt = 0
    private var pending: Task<Void, Never>?

    init(editor: GtkSource.View, buffer: GtkSource.Buffer, suggest: @escaping (String, Int) async -> PharoCompletions?) {
        self.editor = editor
        self.buffer = buffer
        self.suggest = suggest
    }

    var isActive: Bool { popover != nil }

    func request() {
        let source = buffer.text ?? ""
        guard !source.isEmpty else { return }
        let cursor = cursorOffset()
        generation &+= 1
        let generationAtRequest = generation
        pending?.cancel()
        pending = Task { @MainActor in
            guard let answer = await suggest(source, cursor), generation == generationAtRequest else { return }
            guard !answer.completions.isEmpty else {
                dismiss()
                return
            }
            show(tokenStart: answer.tokenStart, candidates: answer.completions)
        }
    }

    func handleKey(_ keyval: UInt) -> Bool {
        guard isActive else { return false }
        switch Int32(keyval) {
        case Gdk.keyEscape:
            dismiss()
            return true
        case Gdk.keyUp:
            move(-1)
            return true
        case Gdk.keyDown:
            move(1)
            return true
        case Gdk.keyTab, Gdk.keyISOLeftTab, Gdk.keyReturn, Gdk.keyKPEnter, Gdk.keyISOEnter:
            accept()
            return true
        default:
            dismiss()
            return false
        }
    }

    private func show(tokenStart: Int, candidates: [String]) {
        teardown()
        self.tokenStart = tokenStart
        self.candidates = candidates

        let popover = Popover()
        popover.autohide = false
        popover.canFocus = false

        let listBox = ListBox()
        listBox.selectionMode = .single
        listBox.canFocus = false
        listBox.add(cssClass: "boxed-list")
        listBox.setSizeRequest(width: 280, height: -1)
        for candidate in candidates {
            let label = Label(str: candidate)
            label.add(cssClass: "monospace")
            label.halign = .start
            label.xalign = 0
            label.marginStart = 8
            label.marginEnd = 8
            label.marginTop = 4
            label.marginBottom = 4
            let row = ListBoxRow()
            row.canFocus = false
            row.set(child: label)
            listBox.append(child: row)
        }
        listBox.onRowActivated { [weak self] _, _ in
            MainActor.assumeIsolated { self?.accept() }
        }

        let inlineRowLimit = 8
        if candidates.count > inlineRowLimit {
            let scroll = ScrolledWindow()
            scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
            scroll.propagateNaturalHeight = true
            scroll.maxContentHeight = 200
            scroll.set(child: listBox)
            popover.set(child: scroll)
            self.scroll = scroll
        } else {
            popover.set(child: listBox)
        }
        popover.set(parent: editor)
        popover.position = .bottom

        self.popover = popover
        self.list = listBox
        if let first = listBox.getRowAt(index: 0) {
            listBox.select(row: first)
        }

        pointAtCaret(popover)
        popover.popup()
    }

    private func pointAtCaret(_ popover: Popover) {
        var strong = GdkRectangle(x: 0, y: 0, width: 0, height: 0)
        let textView = UnsafeMutablePointer<GtkTextView>(OpaquePointer(editor.view_ptr))
        withUnsafeMutablePointer(to: &strong) { gtk_text_view_get_cursor_locations(textView, nil, $0, nil) }
        var windowX: gint = 0
        var windowY: gint = 0
        editor.bufferToWindowCoords(
            win: .widget,
            bufferX: Int(strong.x),
            bufferY: Int(strong.y),
            windowX: &windowX,
            windowY: &windowY
        )
        var rect = GdkRectangle(x: windowX, y: windowY, width: 1, height: strong.height)
        withUnsafeMutablePointer(to: &rect) { gtk_popover_set_pointing_to(popover.popover_ptr, $0) }
    }

    private func move(_ delta: Int) {
        guard let list, !candidates.isEmpty else { return }
        let current = list.selectedRow.map { Int($0.index) } ?? -1
        var next = current + delta
        if next < 0 { next = candidates.count - 1 }
        if next >= candidates.count { next = 0 }
        guard let row = list.getRowAt(index: next) else { return }
        list.select(row: row)
        scrollRowIntoView(row)
    }

    private func scrollRowIntoView(_ row: ListBoxRowRef) {
        guard let scroll, let list, let vadjustment = scroll.vadjustment else { return }
        var origin = graphene_point_t(x: 0, y: 0)
        var translated = graphene_point_t(x: 0, y: 0)
        let ok = withUnsafeMutablePointer(to: &origin) { originPtr in
            withUnsafeMutablePointer(to: &translated) { translatedPtr in
                row.computePoint(target: list, point: PointRef(originPtr), outPoint: PointRef(translatedPtr))
            }
        }
        guard ok else { return }
        let rowY = Double(translated.y)
        vadjustment.clampPage(lower: rowY, upper: rowY + Double(row.height))
    }

    private func accept() {
        guard let list else { return }
        let index = list.selectedRow.map { Int($0.index) } ?? 0
        guard index >= 0, index < candidates.count else {
            dismiss()
            return
        }
        let replacement = candidates[index]
        let start = tokenStart
        dismiss()
        replaceToken(from: start, with: replacement)
    }

    private func replaceToken(from start: Int, with text: String) {
        let startStorage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let endStorage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            startStorage.deallocate()
            endStorage.deallocate()
        }
        let startIter = TextIter(startStorage)
        let endIter = TextIter(endStorage)
        buffer.getIterAtOffset(iter: startIter, charOffset: start)
        buffer.getIterAtMark(iter: endIter, mark: buffer.getInsert())
        buffer.delete(start: startIter, end: endIter)
        buffer.insertAtCursor(text: text, len: Int(text.utf8.count))
    }

    private func dismiss() {
        generation &+= 1
        pending?.cancel()
        pending = nil
        teardown()
    }

    private func teardown() {
        popover?.popdown()
        popover?.unparent()
        popover = nil
        list = nil
        scroll = nil
        candidates = []
    }

    private func cursorOffset() -> Int {
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { storage.deallocate() }
        let iter = TextIter(storage)
        buffer.getIterAtMark(iter: iter, mark: buffer.getInsert())
        return Int(iter.offset)
    }
}
