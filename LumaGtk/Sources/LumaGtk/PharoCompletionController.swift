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

    /// The source and caret the marks leave once their anchor characters are
    /// taken out, so the image sees the code and not the placeholders.
    var cleanSource: (() -> String?)?
    var cleanCursor: (() -> Int?)?

    private var popover: Popover?
    private var list: ListBox?
    private var scroll: ScrolledWindow?
    private var candidates: [String] = []
    private var generation: UInt = 0
    private var pending: Task<Void, Never>?



    init(editor: GtkSource.View, buffer: GtkSource.Buffer, suggest: @escaping (String, Int) async -> PharoCompletions?) {
        self.editor = editor
        self.buffer = buffer
        self.suggest = suggest
        installAutoTrigger()
    }

    /// Completions surface as the reader types, no key needed -- the way the
    /// SwiftUI editor calls `complete:` on every letter. A single-character edit
    /// asks afresh: a letter opens or narrows the list, a delimiter empties the
    /// token and closes it. Deleting re-asks only while the list already stands,
    /// so backspacing filters without conjuring a list from nothing. Longer
    /// inserts -- setting the source, accepting a candidate -- are left alone.
    private func installAutoTrigger() {
        buffer.onInsertText { [weak self] _, _, text, _ in
            MainActor.assumeIsolated {
                guard let self, text.count == 1, let character = text.first else { return }
                if character.isLetter || self.isActive { self.scheduleRequest() }
            }
        }
        buffer.onDeleteRange { [weak self] _, _, _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.scheduleRequest()
            }
        }
    }

    /// Ask once the edit that prompted it has landed, so the token and caret read
    /// their settled positions rather than the ones from mid-signal.
    private func scheduleRequest() {
        Task { @MainActor in self.request() }
    }

    var isActive: Bool { popover != nil }

    func request() {
        let source = cleanSource?() ?? buffer.text
        guard !source.isEmpty else { return }
        let cursor = cleanCursor?() ?? cursorOffset()
        generation &+= 1
        let generationAtRequest = generation
        pending?.cancel()
        pending = Task { @MainActor in
            guard let answer = await suggest(source, cursor), generation == generationAtRequest else { return }
            guard !answer.completions.isEmpty else {
                dismiss()
                return
            }
            show(candidates: answer.completions)
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
            // Let the keystroke through and let the edit it makes decide whether
            // the list refreshes or closes; dismissing here would fight typing.
            return false
        }
    }

    private func show(candidates: [String]) {
        teardown()
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
        let start = currentTokenStart()
        dismiss()
        if replacement.contains(":") {
            insertKeywordTemplate(replacement, from: start)
        } else {
            replaceToken(from: start, with: replacement)
        }
    }

    /// A keyword selector lays down as a source snippet -- "to:by:" becomes
    /// "to: ⟨⟩ by: ⟨⟩" -- so the editor renders each argument as its own token,
    /// selects the first, and tabs through them the way Xcode does. The keyword
    /// already names the slot, so it is left blank rather than echoed.
    private func insertKeywordTemplate(_ selector: String, from start: Int) {
        let keywords = selector.split(separator: ":").map(String.init)
        guard !keywords.isEmpty else { return }

        var spec = ""
        for (index, keyword) in keywords.enumerated() {
            spec += "\(keyword): ${\(index + 1):\u{2026}}"
            if index < keywords.count - 1 { spec += " " }
        }
        spec += "$0"

        guard let snippet = try? GtkSource.Snippet.new(parsed: spec) else {
            replaceToken(from: start, with: selector)
            return
        }

        withIters { first, second in
            buffer.getIterAtOffset(iter: first, charOffset: start)
            buffer.getIterAtMark(iter: second, mark: buffer.getInsert())
            buffer.delete(start: first, end: second)
        }
        withIter { iter in
            buffer.getIterAtOffset(iter: iter, charOffset: start)
            editor.push(snippet: snippet, location: iter)
        }
    }

    /// Where the token under the caret begins, walked back over its own letters
    /// here rather than trusted from the image, whose offset is one-based and
    /// would leave the first character behind.
    private func currentTokenStart() -> Int {
        let characters = Array(buffer.text)
        var start = min(cursorOffset(), characters.count)
        while start > 0, isTokenCharacter(characters[start - 1]) { start -= 1 }
        return start
    }

    private func isTokenCharacter(_ character: Character) -> Bool {
        character == "_" || (character.isASCII && (character.isLetter || character.isNumber))
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

    private func withIter<R>(_ body: (TextIter) -> R) -> R {
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { storage.deallocate() }
        return body(TextIter(storage))
    }

    private func withIters<R>(_ body: (TextIter, TextIter) -> R) -> R {
        let first = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let second = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { first.deallocate(); second.deallocate() }
        return body(TextIter(first), TextIter(second))
    }
}
