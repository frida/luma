import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk
import GtkSource
import LumaCore
import SwiftyPharo

/// One snippet on the playground page: an accent bar that marks focus and the
/// last run's outcome, an editor, and a row of actions that appears on hover or
/// focus -- run and inspect on the left, examples and remove on the right, the
/// way the macOS card lays them out. Reordering lives in a right-click menu.
@MainActor
final class PharoSnippetCard {
    let widget: Box
    let id: UUID

    var onRun: ((PharoRunMode) -> Void)?
    var onFormat: (() -> Void)?
    var onBrowse: ((PharoBrowseKind) -> Void)?
    var onSourceChanged: ((String) -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onRemove: (() -> Void)?

    private let editor: GtkSource.View
    private let buffer: GtkSource.Buffer
    private let accent: DrawingArea
    private let actions: Box
    private var completion: PharoCompletionController!

    private var suppressChange = false
    private var pointedAt = false
    private var editorFocused = false
    private var outcome: Bool?
    private var outcomeGeneration = 0

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

        accent = DrawingArea()
        accent.setSizeRequest(width: 3, height: -1)
        accent.vexpand = true

        actions = Box(orientation: .horizontal, spacing: 2)
        actions.marginTop = 4
        actions.marginBottom = 4
        actions.marginStart = 6
        actions.marginEnd = 6
        actions.opacity = 0

        let content = Box(orientation: .vertical, spacing: 0)
        content.hexpand = true
        content.append(child: editorScroll)
        content.append(child: Separator(orientation: .horizontal))
        content.append(child: actions)

        widget = Box(orientation: .horizontal, spacing: 0)
        widget.add(cssClass: "card")
        widget.valign = .start
        widget.vexpand = false
        widget.append(child: accent)
        widget.append(child: content)

        accent.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated { self?.drawAccent(ctx, Double(width), Double(height)) }
        }

        populateActions()
        completion = PharoCompletionController(editor: editor, buffer: buffer, suggest: suggest)
        installShortcuts()
        installReveal()
        installContextMenu()

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

    func flashOutcome(success: Bool) {
        outcome = success
        accent.queueDraw()
        outcomeGeneration += 1
        let generation = outcomeGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard self.outcomeGeneration == generation else { return }
            self.outcome = nil
            self.accent.queueDraw()
        }
    }

    func cursorOffset() -> Int {
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { storage.deallocate() }
        let iter = TextIter(storage)
        buffer.getIterAtMark(iter: iter, mark: buffer.getInsert())
        return Int(iter.offset)
    }

    private func populateActions() {
        actions.append(child: iconButton("media-playback-start-symbolic", "Evaluate and inspect (Ctrl+Return)") { [weak self] in self?.onRun?(.inspect) })
        actions.append(child: iconButton("media-seek-forward-symbolic", "Evaluate (Ctrl+D)") { [weak self] in self?.onRun?(.doIt) })

        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        actions.append(child: spacer)

        actions.append(child: examplesButton())
        actions.append(child: iconButton("user-trash-symbolic", "Remove") { [weak self] in self?.onRemove?() })
    }

    private func iconButton(_ icon: String, _ tooltip: String, _ action: @escaping () -> Void) -> Button {
        let button = Button(iconName: icon)
        button.add(cssClass: "flat")
        button.add(cssClass: "circular")
        button.tooltipText = tooltip
        button.onClicked { _ in MainActor.assumeIsolated { action() } }
        return button
    }

    private func examplesButton() -> MenuButton {
        let button = MenuButton()
        button.add(cssClass: "flat")
        button.add(cssClass: "circular")
        button.iconName = "starred-symbolic"
        button.tooltipText = "Insert an example"

        let popover = Popover()
        popover.autohide = true
        let box = Box(orientation: .vertical, spacing: 4)
        box.marginTop = 6
        box.marginBottom = 6
        box.marginStart = 6
        box.marginEnd = 6
        for section in PharoExampleCatalog.sections {
            let heading = Label(str: section.heading)
            heading.add(cssClass: "dim-label")
            heading.add(cssClass: "caption-heading")
            heading.halign = .start
            heading.marginTop = 4
            box.append(child: heading)
            for example in section.examples {
                let item = Button(label: example.title)
                item.add(cssClass: "flat")
                item.hexpand = true
                if let child = item.child { child.halign = .start }
                let code = example.code
                item.onClicked { _ in
                    MainActor.assumeIsolated {
                        popover.popdown()
                        self.insertExample(code)
                    }
                }
                box.append(child: item)
            }
        }
        let scroll = ScrolledWindow()
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroll.propagateNaturalHeight = true
        scroll.maxContentHeight = 360
        scroll.setSizeRequest(width: 260, height: -1)
        scroll.set(child: box)
        popover.set(child: scroll)
        button.set(popover: popover)
        return button
    }

    private func insertExample(_ code: String) {
        setSource(code)
        onSourceChanged?(code)
        focusEditor()
    }

    private func installReveal() {
        let motion = EventControllerMotion()
        motion.onEnter { [weak self] _, _, _ in
            MainActor.assumeIsolated { self?.pointedAt = true; self?.updateReveal() }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.pointedAt = false; self?.updateReveal() }
        }
        widget.install(controller: motion)

        let focus = EventControllerFocus()
        focus.onEnter { [weak self] _ in
            MainActor.assumeIsolated { self?.editorFocused = true; self?.updateReveal(); self?.accent.queueDraw() }
        }
        focus.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.editorFocused = false; self?.updateReveal(); self?.accent.queueDraw() }
        }
        editor.install(controller: focus)
    }

    private func updateReveal() {
        actions.opacity = (pointedAt || editorFocused) ? 1 : 0
    }

    private func installContextMenu() {
        let popover = Popover()
        popover.autohide = true
        popover.set(parent: widget)
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

        let gesture = GestureClick()
        gesture.button = 3
        gesture.onPressed { _, _, x, y in
            MainActor.assumeIsolated { popover.presentPointing(at: x, y: y) }
        }
        widget.install(controller: gesture)
    }

    private func menuItem(_ label: String, _ popover: Popover, _ action: @escaping () -> Void) -> Button {
        let button = Button(label: label)
        button.add(cssClass: "flat")
        button.hexpand = true
        if let child = button.child { child.halign = .start }
        button.onClicked { _ in
            MainActor.assumeIsolated {
                popover.popdown()
                action()
            }
        }
        return button
    }

    private func drawAccent(_ ctx: Cairo.ContextRef, _ width: Double, _ height: Double) {
        let color: (r: Double, g: Double, b: Double)?
        if let outcome {
            color = outcome ? (0.36, 0.78, 0.41) : (0.90, 0.32, 0.30)
        } else if editorFocused {
            color = (0.937, 0.392, 0.337)
        } else {
            color = nil
        }
        guard let color else { return }
        ctx.setSource(red: color.r, green: color.g, blue: color.b, alpha: 1)
        ctx.rectangle(x: 0, y: 0, width: width, height: height)
        ctx.fill()
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
