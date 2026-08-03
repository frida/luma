import CGtk
import Foundation
import Gdk
import Gtk
import GtkSource
import SwiftyPharo

/// One snippet on the playground page: an editor, the run and format actions,
/// a button back to its last result, and a menu to reorder or remove it. It
/// reports edits and actions to the pane, which owns the list and the runtime.
@MainActor
final class PharoSnippetCard {
    let widget: Box
    let id: UUID

    var onRun: ((PharoRunMode) -> Void)?
    var onFormat: (() -> Void)?
    var onBrowse: ((PharoBrowseKind) -> Void)?
    var onSourceChanged: ((String) -> Void)?
    var onReopenResult: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onRemove: (() -> Void)?

    private let editor: GtkSource.View
    private let buffer: GtkSource.Buffer
    private let reopenButton: Button
    private var completion: PharoCompletionController!
    private var suppressChange = false

    var source: String { buffer.text }

    init(
        id: UUID,
        source: String,
        highlight: (GtkSource.Buffer) -> Void,
        completion suggest: @escaping (String, Int) async -> PharoCompletions?
    ) {
        self.id = id

        buffer = GtkSource.Buffer(table: Gtk.TextTagTable?.none)
        editor = GtkSource.View(buffer: buffer)
        editor.monospace = true
        editor.showLineNumbers = false
        editor.highlightCurrentLine = false
        editor.leftMargin = 10
        editor.rightMargin = 10
        editor.topMargin = 8
        editor.bottomMargin = 8
        editor.hexpand = true
        buffer.set(text: source, len: Int(source.utf8.count))
        highlight(buffer)

        let editorScroll = ScrolledWindow()
        editorScroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        editorScroll.hexpand = true
        editorScroll.setSizeRequest(width: -1, height: 108)
        editorScroll.set(child: editor)

        reopenButton = Button(iconName: "view-reveal-symbolic")
        reopenButton.add(cssClass: "flat")
        reopenButton.add(cssClass: "circular")
        reopenButton.tooltipText = "Show last result"
        reopenButton.visible = false

        let runButton = Button(iconName: "media-playback-start-symbolic")
        runButton.add(cssClass: "flat")
        runButton.add(cssClass: "circular")
        runButton.tooltipText = "Inspect (Ctrl+Return) · Do it (Ctrl+D) · Print it (Ctrl+P)"

        let formatButton = Button(iconName: "format-justify-left-symbolic")
        formatButton.add(cssClass: "flat")
        formatButton.add(cssClass: "circular")
        formatButton.tooltipText = "Format (Ctrl+Shift+F)"

        let toolbar = Box(orientation: .horizontal, spacing: 2)
        toolbar.halign = .end
        toolbar.marginTop = 4
        toolbar.marginBottom = 4
        toolbar.marginStart = 6
        toolbar.marginEnd = 6
        toolbar.append(child: reopenButton)
        toolbar.append(child: runButton)
        toolbar.append(child: formatButton)

        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "card")
        widget.append(child: editorScroll)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: toolbar)

        toolbar.append(child: makeMenuButton())

        reopenButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.onReopenResult?() }
        }
        runButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.onRun?(.inspect) }
        }
        formatButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.onFormat?() }
        }

        completion = PharoCompletionController(editor: editor, buffer: buffer, suggest: suggest)
        installShortcuts()

        buffer.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suppressChange else { return }
                self.onSourceChanged?(self.buffer.text)
            }
        }
    }

    func focusEditor() {
        _ = editor.grabFocus()
    }

    func setSource(_ text: String) {
        suppressChange = true
        buffer.set(text: text, len: Int(text.utf8.count))
        suppressChange = false
    }

    func setResultAvailable(_ available: Bool) {
        reopenButton.visible = available
    }

    func cursorOffset() -> Int {
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { storage.deallocate() }
        let iter = TextIter(storage)
        buffer.getIterAtMark(iter: iter, mark: buffer.getInsert())
        return Int(iter.offset)
    }

    private func makeMenuButton() -> MenuButton {
        let button = MenuButton()
        button.add(cssClass: "flat")
        button.add(cssClass: "circular")
        button.iconName = "view-more-symbolic"
        button.tooltipText = "Snippet actions"

        let popover = Popover()
        popover.autohide = true
        let box = Box(orientation: .vertical, spacing: 2)
        box.marginTop = 6
        box.marginBottom = 6
        box.marginStart = 6
        box.marginEnd = 6
        box.append(child: menuItem("Move Up", popover) { [weak self] in self?.onMoveUp?() })
        box.append(child: menuItem("Move Down", popover) { [weak self] in self?.onMoveDown?() })
        box.append(child: menuItem("Duplicate", popover) { [weak self] in self?.onDuplicate?() })
        box.append(child: Separator(orientation: .horizontal))
        let remove = menuItem("Remove", popover) { [weak self] in self?.onRemove?() }
        remove.add(cssClass: "destructive-action")
        box.append(child: remove)
        popover.set(child: box)
        button.set(popover: popover)
        return button
    }

    private func menuItem(_ label: String, _ popover: Popover, _ action: @escaping () -> Void) -> Button {
        let button = Button(label: label)
        button.add(cssClass: "flat")
        button.hexpand = true
        if let child = button.child {
            child.halign = .start
        }
        button.onClicked { _ in
            MainActor.assumeIsolated {
                popover.popdown()
                action()
            }
        }
        return button
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
                    self.onRun?(.inspect)
                    return true
                case 0x0064, 0x0044:
                    self.onRun?(.doIt)
                    return true
                case 0x0070, 0x0050:
                    self.onRun?(.printIt)
                    return true
                case 0x0020, 0xFF80:
                    self.completion.request()
                    return true
                case 0x0066, 0x0046:
                    guard state.contains(.shiftMask) else { return false }
                    self.onFormat?()
                    return true
                case 0x006D, 0x004D:
                    self.onBrowse?(.implementors)
                    return true
                case 0x006E, 0x004E:
                    self.onBrowse?(.senders)
                    return true
                default:
                    return false
                }
            }
        }
        editor.install(controller: keys)
    }
}
