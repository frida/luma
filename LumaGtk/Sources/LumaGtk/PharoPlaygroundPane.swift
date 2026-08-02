import CGtk
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

/// A first Smalltalk surface for the GTK frontend: a snippet to edit, a button
/// to run it, and the result opened in the moldable inspector below. It drives
/// the same PharoRuntime the macOS app does.
@MainActor
final class PharoPlaygroundPane {
    let widget: Box

    private weak var engine: Engine?
    private let editor: TextView
    private let runButton: Button
    private let inspector: PharoColumnsView
    private var isEvaluating = false

    init(engine: Engine) {
        self.engine = engine

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        editor = TextView()
        editor.monospace = true
        editor.leftMargin = 12
        editor.rightMargin = 12
        editor.topMargin = 12
        editor.bottomMargin = 12
        editor.hexpand = true
        editor.vexpand = true

        let editorScroll = ScrolledWindow()
        editorScroll.hexpand = true
        editorScroll.vexpand = true
        editorScroll.set(child: editor)

        runButton = Button(label: "Evaluate")
        runButton.add(cssClass: "suggested-action")
        runButton.marginTop = 8
        runButton.marginBottom = 8
        runButton.marginStart = 12
        runButton.marginEnd = 12
        runButton.halign = .start

        inspector = PharoColumnsView(runtime: PharoRuntime.shared)

        widget.append(child: editorScroll)
        widget.append(child: runButton)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: inspector.widget)

        runButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    private func evaluate() {
        guard !isEvaluating, let engine else { return }
        let source = editorText()
        guard !source.isEmpty else { return }
        isEvaluating = true
        runButton.sensitive = false
        inspector.showMessage("Evaluating…")

        Task { @MainActor in
            defer {
                isEvaluating = false
                runButton.sensitive = true
            }
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                let produced = try await PharoRuntime.shared.evaluate(source)
                inspector.present(produced)
            } catch {
                inspector.showMessage(error.localizedDescription)
            }
        }
    }

    private func editorText() -> String {
        editor.buffer?.text ?? ""
    }
}
