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
enum PharoRunMode {
    case doIt
    case printIt
    case inspect
}

@MainActor
final class PharoPlaygroundPane {
    let widget: Box

    private weak var engine: Engine?
    private let editor: GtkSource.View
    private let sourceBuffer: GtkSource.Buffer
    private let runButton: Button
    private let formatButton: Button
    private let inspector: PharoColumnsView
    private var completion: PharoCompletionController!
    private var isEvaluating = false

    init(engine: Engine) {
        self.engine = engine

        widget = Box(orientation: .horizontal, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        sourceBuffer = GtkSource.Buffer(table: Gtk.TextTagTable?.none)
        editor = GtkSource.View(buffer: sourceBuffer)
        editor.monospace = true
        editor.showLineNumbers = false
        editor.highlightCurrentLine = false
        editor.leftMargin = 10
        editor.rightMargin = 10
        editor.topMargin = 8
        editor.bottomMargin = 8
        editor.hexpand = true
        editor.vexpand = true

        let editorScroll = ScrolledWindow()
        editorScroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        editorScroll.hexpand = true
        editorScroll.vexpand = false
        editorScroll.setSizeRequest(width: -1, height: 132)
        editorScroll.set(child: editor)

        runButton = Button(iconName: "media-playback-start-symbolic")
        runButton.add(cssClass: "flat")
        runButton.add(cssClass: "circular")
        runButton.tooltipText = "Inspect (Ctrl+Return) · Do it (Ctrl+D) · Print it (Ctrl+P)"

        formatButton = Button(iconName: "format-justify-left-symbolic")
        formatButton.add(cssClass: "flat")
        formatButton.add(cssClass: "circular")
        formatButton.tooltipText = "Format (Ctrl+Shift+F)"

        let toolbar = Box(orientation: .horizontal, spacing: 2)
        toolbar.halign = .end
        toolbar.marginTop = 4
        toolbar.marginBottom = 4
        toolbar.marginStart = 6
        toolbar.marginEnd = 6
        toolbar.append(child: runButton)
        toolbar.append(child: formatButton)

        let card = Box(orientation: .vertical, spacing: 0)
        card.add(cssClass: "card")
        card.valign = .start
        card.halign = .start
        card.hexpand = false
        card.vexpand = false
        card.setSizeRequest(width: 340, height: -1)
        card.marginTop = 12
        card.marginBottom = 12
        card.marginStart = 12
        card.marginEnd = 12
        card.append(child: editorScroll)
        card.append(child: Separator(orientation: .horizontal))
        card.append(child: toolbar)

        inspector = PharoColumnsView(runtime: PharoRuntime.shared)

        widget.append(child: card)
        widget.append(child: Separator(orientation: .vertical))
        widget.append(child: inspector.widget)

        runButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.run(.inspect) }
        }
        formatButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.format() }
        }
        completion = PharoCompletionController(editor: editor, buffer: sourceBuffer) { [weak self] source, position in
            guard let self, let engine = self.engine else { return nil }
            try? await PharoRuntime.shared.startPlayground(for: engine)
            return try? await PharoRuntime.shared.completions(for: source, at: position)
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
        languages.appendSearchPath(path: specs)
        schemes.appendSearchPath(path: specs)

        sourceBuffer.language = languages.getLanguage(id: "smalltalk")
        sourceBuffer.styleScheme = schemes.getScheme(schemeId: "luma")
        sourceBuffer.highlightSyntax = true
    }

    private func installShortcuts() {
        let keys = EventControllerKey()
        keys.propagationPhase = .capture
        keys.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if self.completion.handleKey(keyval) { return true }
                guard state.contains(.controlMask) else { return false }
                switch keyval {
                case 0xFF0D, 0xFF8D:
                    self.run(.inspect)
                    return true
                case 0x0064, 0x0044:
                    self.run(.doIt)
                    return true
                case 0x0070, 0x0050:
                    self.run(.printIt)
                    return true
                case 0x0020, 0xFF80:
                    self.completion.request()
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

    private func run(_ mode: PharoRunMode) {
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
                switch mode {
                case .doIt:
                    inspector.showMessage("Done.")
                case .printIt:
                    inspector.showMessage(produced.printString)
                case .inspect:
                    inspector.present(produced)
                }
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
        sourceBuffer.text
    }

    private func cursorOffset() -> Int {
        let iterStorage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { iterStorage.deallocate() }
        let iter = TextIter(iterStorage)
        sourceBuffer.getIterAtMark(iter: iter, mark: sourceBuffer.getInsert())
        return Int(iter.offset)
    }
}
