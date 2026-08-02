import CGtk
import Foundation
import Gdk
import Gtk
import GtkSource
import LumaCore
import SwiftyPharo

/// A first Smalltalk surface for the GTK frontend: a snippet to edit, a button
/// to run it, and the result opened in the moldable inspector below. It drives
/// the same PharoRuntime the macOS app does.
@MainActor
final class PharoPlaygroundPane {
    let widget: Box

    private weak var engine: Engine?
    private let editor: GtkSource.View
    private let sourceBuffer: GtkSource.Buffer
    private let runButton: Button
    private let formatButton: Button
    private let inspector: PharoColumnsView
    private var isEvaluating = false

    init(engine: Engine) {
        self.engine = engine

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        sourceBuffer = GtkSource.Buffer(table: Gtk.TextTagTable?.none)
        editor = GtkSource.View(buffer: sourceBuffer)
        editor.monospace = true
        editor.showLineNumbers = true
        editor.highlightCurrentLine = true
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
        runButton.tooltipText = "Evaluate (Ctrl+Return)"

        formatButton = Button(label: "Format")
        formatButton.add(cssClass: "flat")
        formatButton.tooltipText = "Format (Ctrl+Shift+F)"

        let buttons = Box(orientation: .horizontal, spacing: 8)
        buttons.marginTop = 8
        buttons.marginBottom = 8
        buttons.marginStart = 12
        buttons.marginEnd = 12
        buttons.append(child: runButton)
        buttons.append(child: formatButton)

        inspector = PharoColumnsView(runtime: PharoRuntime.shared)

        widget.append(child: editorScroll)
        widget.append(child: buttons)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: inspector.widget)

        runButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        formatButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.format() }
        }
        installShortcuts()
        highlightSmalltalk()
        inspector.showMessage("Evaluate a snippet with Ctrl+Return to open its result here.")
    }

    /// Colour the source through GtkSourceView's own highlighter, from the
    /// Smalltalk language and Luma scheme bundled beside the app.
    private func highlightSmalltalk() {
        guard let specs = Bundle.module.url(forResource: "smalltalk", withExtension: "lang", subdirectory: "pharo")?
            .deletingLastPathComponent().path
        else { return }

        let languages = GtkSource.LanguageManager()
        let schemes = GtkSource.StyleSchemeManager()
        specs.withCString { path in
            var dirs: [UnsafePointer<gchar>?] = [path, nil]
            dirs.withUnsafeBufferPointer { buffer in
                languages.setSearchPath(dirs: buffer.baseAddress)
                schemes.setSearchPath(path: buffer.baseAddress)
            }
        }

        sourceBuffer.language = languages.getLanguage(id: "smalltalk")
        sourceBuffer.styleScheme = schemes.getScheme(schemeId: "luma")
        sourceBuffer.highlightSyntax = true
    }

    private func installShortcuts() {
        let keys = EventControllerKey()
        keys.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self, state.contains(.controlMask) else { return false }
                switch keyval {
                case 0xFF0D, 0xFF8D:
                    self.evaluate()
                    return true
                case 0x0066, 0x0046:
                    guard state.contains(.shiftMask) else { return false }
                    self.format()
                    return true
                case 0x006D, 0x004D:
                    self.browse(.implementors)
                    return true
                case 0x006E, 0x004E:
                    self.browse(.senders)
                    return true
                default:
                    return false
                }
            }
        }
        editor.install(controller: keys)
    }

    private func format() {
        guard let engine else { return }
        let source = editorText()
        guard !source.isEmpty else { return }
        Task { @MainActor in
            try? await PharoRuntime.shared.startPlayground(for: engine)
            if let formatted = try? await PharoRuntime.shared.format(source: source) {
                sourceBuffer.set(text: formatted, len: Int(formatted.utf8.count))
            }
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

    private func browse(_ kind: PharoBrowseKind) {
        guard let engine else { return }
        let source = editorText()
        guard !source.isEmpty else { return }
        let position = cursorOffset()
        inspector.showMessage("Browsing \(kind.rawValue)…")
        Task { @MainActor in
            do {
                try await PharoRuntime.shared.startPlayground(for: engine)
                let found = try await PharoRuntime.shared.browse(kind, source: source, at: position)
                if let result = found.result {
                    inspector.present(result)
                } else {
                    inspector.showMessage("No \(kind.rawValue) for the selector at the cursor.")
                }
            } catch {
                inspector.showMessage(error.localizedDescription)
            }
        }
    }

    private func editorText() -> String {
        sourceBuffer.text ?? ""
    }

    private func cursorOffset() -> Int {
        let iterStorage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { iterStorage.deallocate() }
        let iter = TextIter(iterStorage)
        sourceBuffer.getIterAtMark(iter: iter, mark: sourceBuffer.getInsert())
        return Int(iter.offset)
    }
}
