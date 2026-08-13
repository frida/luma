import CGtk
import Foundation
import Gdk
import Gtk
import GtkSource
import LumaCore
import SwiftyPharo

/// A notebook entry holding Smalltalk the reader can edit and run again: the
/// source over what its last run captured. Running re-evaluates it and keeps a
/// fresh snapshot beside the code; both the code and the result save back to
/// the entry, and the cell refreshes in place rather than rebuilding its row.
/// Mirrors the SwiftUI PharoNotebookCell.
@MainActor
final class PharoNotebookCell {
    let widget: Box
    let id: UUID

    private var entry: NotebookEntry
    private let engine: Engine
    private let buffer: GtkSource.Buffer
    private let resultSlot = Box(orientation: .vertical, spacing: 0)
    private let failure = Label(str: "")
    private var completion: PharoCompletionController!
    private var marks: PharoInlineMarks!
    private let find: PharoFindBar
    private var snapshotView: PharoSnapshotView?
    private var running = false

    private var source: String { marks.source }

    init(entry: NotebookEntry, engine: Engine) {
        self.entry = entry
        self.id = entry.id
        self.engine = engine

        buffer = GtkSource.Buffer(table: Gtk.TextTagTable?.none)
        buffer.set(text: entry.details, len: Int(entry.details.utf8.count))
        PharoHighlighting.apply(to: buffer)

        let editor = GtkSource.View(buffer: buffer)
        editor.monospace = true
        editor.enableSnippets = true
        editor.highlightCurrentLine = false
        editor.leftMargin = 10
        editor.rightMargin = 10
        editor.topMargin = 8
        editor.bottomMargin = 8
        editor.hexpand = true

        let editorScroll = ScrolledWindow()
        editorScroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .never)
        editorScroll.hexpand = true
        editorScroll.propagateNaturalHeight = true
        editorScroll.minContentHeight = 48
        editorScroll.maxContentHeight = 400
        editorScroll.set(child: editor)

        let frame = Frame()
        frame.set(child: editorScroll)

        failure.xalign = 0
        failure.wrap = true
        failure.add(cssClass: "error")
        failure.add(cssClass: "caption")
        failure.visible = false

        let run = Button(iconName: "media-playback-start-symbolic")
        run.add(cssClass: "flat")
        run.tooltipText = "Run (Ctrl+Return)"
        run.halign = .start

        let bar = Box(orientation: .horizontal, spacing: 6)
        bar.append(child: run)
        bar.append(child: failure)

        find = PharoFindBar(editor: editor, buffer: buffer)

        widget = Box(orientation: .vertical, spacing: 6)
        widget.hexpand = true
        widget.append(child: find.widget)
        widget.append(child: frame)
        widget.append(child: bar)
        widget.append(child: resultSlot)

        showSnapshot(entry.pharoSnapshot)

        marks = PharoInlineMarks(
            editor: editor, buffer: buffer, runtime: PharoRuntime.shared, selfClass: nil,
            highlight: { PharoHighlighting.apply(to: $0) })
        completion = PharoCompletionController(editor: editor, buffer: buffer) { source, position in
            try? await PharoRuntime.shared.completions(for: source, at: position)
        }
        completion.cleanSource = { [weak self] in self?.marks.source }
        completion.cleanCursor = { [weak self] in self?.marks.sourceCursor() }

        run.onClicked { [weak self] _ in MainActor.assumeIsolated { self?.run() } }

        buffer.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.marks.isApplying else { return }
                self.marks.refresh()
            }
        }

        let keys = EventControllerKey()
        keys.propagationPhase = .capture
        keys.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if self.completion.handleKey(keyval) { return true }
                if self.marks.handleCursorKey(keyval, shift: state.contains(.shiftMask)) { return true }
                guard state.contains(.controlMask) else { return false }
                switch keyval {
                case 0xFF0D, 0xFF8D:
                    self.run()
                    return true
                case 0x0020, 0xFF80:
                    self.completion.request()
                    return true
                default:
                    return false
                }
            }
        }
        editor.install(controller: keys)

        let focus = EventControllerFocus()
        focus.onLeave { [weak self] _ in MainActor.assumeIsolated { self?.persistSource() } }
        editor.install(controller: focus)
    }

    /// A field-scoped change lands here rather than rebuilding the row, so the
    /// caret and the editor survive. The editor stays the source of truth for
    /// the code -- an echo of a source change it originated is a no-op -- so
    /// only the captured result is applied.
    func apply(_ entry: NotebookEntry, changed: NotebookEntryFields) {
        self.entry = entry
        if changed.contains(.pharoSnapshot) {
            showSnapshot(entry.pharoSnapshot)
        }
    }

    private func run() {
        guard !running else { return }
        running = true
        let source = source

        Task { @MainActor in
            defer { self.running = false }
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                let produced = try await PharoRuntime.shared.evaluate(source)
                let snapshot = try await PharoSnapshot.capture(of: produced, using: PharoRuntime.shared)
                failure.visible = false
                // The result reaches the view back through the model's change,
                // which keeps the source and the snapshot moving together.
                var updated = entry
                updated.details = source
                updated.pharoSnapshot = snapshot
                entry = updated
                engine.updateNotebookEntry(updated, changed: [.details, .pharoSnapshot])
            } catch {
                failure.setText(str: error.localizedDescription)
                failure.visible = true
            }
        }
    }

    private func persistSource() {
        let source = source
        guard source != entry.details else { return }
        var updated = entry
        updated.details = source
        entry = updated
        engine.updateNotebookEntry(updated, changed: .details)
    }

    private func showSnapshot(_ snapshot: PharoSnapshot?) {
        while let existing = resultSlot.getFirstChild() {
            resultSlot.remove(child: existing)
        }
        snapshotView = nil
        guard let snapshot else { return }
        let view = PharoSnapshotView(snapshot: snapshot)
        snapshotView = view
        resultSlot.append(child: view.widget)
    }
}
