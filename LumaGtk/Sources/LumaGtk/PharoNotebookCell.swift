import CGtk
import Foundation
import Gdk
import Gtk
import GtkSource
import LumaCore
import SwiftyPharo

/// A notebook entry holding Smalltalk the reader can edit and run again: the
/// source over what its last run captured. Running re-evaluates it, keeps a
/// fresh snapshot beside the code, and saves both back to the entry. Mirrors
/// the SwiftUI PharoNotebookCell.
@MainActor
final class PharoNotebookCell {
    let widget: Box

    private let entry: NotebookEntry
    private let engine: Engine
    private let buffer: GtkSource.Buffer
    private let resultSlot = Box(orientation: .vertical, spacing: 0)
    private let failure = Label(str: "")
    private var completion: PharoCompletionController!
    private var snapshotView: PharoSnapshotView?
    private var running = false

    init(entry: NotebookEntry, engine: Engine) {
        self.entry = entry
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

        widget = Box(orientation: .vertical, spacing: 6)
        widget.hexpand = true
        widget.append(child: frame)
        widget.append(child: bar)
        widget.append(child: resultSlot)

        showSnapshot(entry.pharoSnapshot)

        completion = PharoCompletionController(editor: editor, buffer: buffer) { source, position in
            try? await PharoRuntime.shared.completions(for: source, at: position)
        }

        run.onClicked { [weak self] _ in MainActor.assumeIsolated { self?.run() } }

        let keys = EventControllerKey()
        keys.propagationPhase = .capture
        keys.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if self.completion.handleKey(keyval) { return true }
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
    }

    /// Running saves the edited source and the fresh snapshot together, which
    /// rebuilds the row; a pure edit left unrun is not persisted, since saving
    /// it would rebuild the row out from under the caret.
    private func run() {
        guard !running else { return }
        running = true
        let source = buffer.text

        Task { @MainActor in
            defer { self.running = false }
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                let produced = try await PharoRuntime.shared.evaluate(source)
                let snapshot = try await PharoSnapshot.capture(of: produced, using: PharoRuntime.shared)
                failure.visible = false
                var updated = entry
                updated.details = source
                updated.pharoSnapshot = snapshot
                engine.updateNotebookEntry(updated)
            } catch {
                failure.setText(str: error.localizedDescription)
                failure.visible = true
            }
        }
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
