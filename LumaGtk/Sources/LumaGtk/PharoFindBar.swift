import CGLib
import CGtk
import Foundation
import GLibObject
import Gtk
import GtkSource

@MainActor
final class PharoFindBar {
    let widget: SearchBar

    private let editor: GtkSource.View
    private let buffer: GtkSource.Buffer
    private let settings = GtkSource.SearchSettings()
    private let context: GtkSource.SearchContext
    private let entry = SearchEntry()
    private let position = Label(str: "")

    init(editor: GtkSource.View, buffer: GtkSource.Buffer) {
        self.editor = editor
        self.buffer = buffer

        settings.wrapAround = true
        context = GtkSource.SearchContext(buffer: buffer, settings: settings)
        context.highlight = true
        widget = SearchBar()

        entry.placeholderText = "Find"
        entry.hexpand = true

        position.add(cssClass: "dim-label")

        let matchCase = ToggleButton(label: "Aa")
        matchCase.add(cssClass: "flat")
        matchCase.tooltipText = "Match case"

        let steps = Box(orientation: .horizontal, spacing: 0)
        steps.add(cssClass: "linked")
        steps.append(child: stepButton("go-up-symbolic", "Previous match", forward: false))
        steps.append(child: stepButton("go-down-symbolic", "Next match", forward: true))

        let line = Box(orientation: .horizontal, spacing: 6)
        line.append(child: entry)
        line.append(child: position)
        line.append(child: matchCase)
        line.append(child: steps)

        widget.showCloseButton = true
        widget.set(child: line)
        widget.connect(entry: entry)

        installShortcut()

        entry.onSearchChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.search(from: .cursor) }
        }
        entry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.step(forward: true) }
        }
        entry.onNextMatch { [weak self] _ in
            MainActor.assumeIsolated { self?.step(forward: true) }
        }
        entry.onPreviousMatch { [weak self] _ in
            MainActor.assumeIsolated { self?.step(forward: false) }
        }
        entry.onStopSearch { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        matchCase.onToggled { [weak self] toggle in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settings.caseSensitive = toggle.active
                self.search(from: .cursor)
            }
        }
        // The count is worked out off the keystroke that set the search going,
        // so the place within it is only known once the context says so. The
        // context dies with this bar, so the callback never outlives its owner.
        g_signal_connect_data(
            context.search_context_ptr,
            "notify::occurrences-count",
            unsafeBitCast(Self.occurrencesCounted, to: GCallback.self),
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            GConnectFlags(rawValue: 0))
    }

    private static let occurrencesCounted:
        @convention(c) (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?
        ) -> Void = { _, _, owner in
            // Crossing to the main actor as an address rather than a pointer,
            // which Swift will not let travel between isolation domains.
            let address = UInt(bitPattern: owner)
            MainActor.assumeIsolated {
                guard let owner = UnsafeRawPointer(bitPattern: address) else { return }
                Unmanaged<PharoFindBar>.fromOpaque(owner).takeUnretainedValue().updatePosition()
            }
        }

    private func stepButton(_ icon: String, _ tooltip: String, forward: Bool) -> Button {
        let button = Button(iconName: icon)
        button.add(cssClass: "flat")
        button.tooltipText = tooltip
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.step(forward: forward) }
        }
        return button
    }

    private func installShortcut() {
        let keys = EventControllerKey()
        keys.propagationPhase = .capture
        keys.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self, state.contains(.controlMask), !state.contains(.shiftMask) else { return false }
                guard keyval == 0x0066 || keyval == 0x0046 else { return false }
                self.open()
                return true
            }
        }
        editor.install(controller: keys)
    }

    /// What is selected in the code is what the reader means to look for, the way
    /// both toolkits seed a find from the selection.
    func open() {
        if let selected = selectedText(), !selected.contains("\n") {
            entry.text = selected
        }
        widget.searchMode = true
        _ = entry.grabFocus()
        entry.selectRegion(startPos: 0, endPos: -1)
        search(from: .selection)
    }

    func close() {
        widget.searchMode = false
        _ = editor.grabFocus()
    }

    /// Where a fresh search starts from. Typing looks on from the cursor so the
    /// match under it stays put as the term grows; opening the bar over a
    /// selection looks on from its head so that selection is the first match.
    private enum SearchStart {
        case cursor
        case selection
    }

    private func search(from start: SearchStart) {
        settings.searchText = entry.text
        withIters { selectionStart, selectionEnd, matchStart, matchEnd in
            buffer.getSelectionBounds(start: selectionStart, end: selectionEnd)
            let from = start == .cursor ? selectionEnd : selectionStart
            guard context.forward(iter: from, matchStart: matchStart, matchEnd: matchEnd) else { return }
            select(matchStart, matchEnd)
        }
        updatePosition()
    }

    private func step(forward: Bool) {
        withIters { selectionStart, selectionEnd, matchStart, matchEnd in
            buffer.getSelectionBounds(start: selectionStart, end: selectionEnd)
            let found = forward
                ? context.forward(iter: selectionEnd, matchStart: matchStart, matchEnd: matchEnd)
                : context.backward(iter: selectionStart, matchStart: matchStart, matchEnd: matchEnd)
            guard found else { return }
            select(matchStart, matchEnd)
        }
        updatePosition()
    }

    private func updatePosition() {
        let total = context.occurrencesCount
        guard total > 0 else {
            position.text = (entry.text ?? "").isEmpty ? "" : "No results"
            return
        }

        let place = withIters { matchStart, matchEnd, _, _ in
            buffer.getSelectionBounds(start: matchStart, end: matchEnd)
            return context.getOccurrencePosition(matchStart: matchStart, matchEnd: matchEnd)
        }
        position.text = place > 0 ? "\(place) of \(total)" : "\(total) matches"
    }

    private func select(_ start: TextIter, _ end: TextIter) {
        buffer.selectRange(ins: start, bound: end)
        _ = editor.scrollTo(iter: start, within: 0.1, useAlign: false, xalign: 0, yalign: 0)
    }

    private func selectedText() -> String? {
        withIters { start, end, _, _ in
            guard buffer.getSelectionBounds(start: start, end: end) else { return nil }
            return buffer.getText(start: start, end: end, includeHiddenChars: false)
        }
    }

    private func withIters<R>(_ body: (TextIter, TextIter, TextIter, TextIter) -> R) -> R {
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 4)
        defer { storage.deallocate() }
        return body(TextIter(storage), TextIter(storage + 1), TextIter(storage + 2), TextIter(storage + 3))
    }
}
