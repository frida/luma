import Foundation
import Gtk
import LumaCore

@MainActor
final class ConversationMessageRow {
    let widget: Box
    let content: Box
    private var footer: Widget?

    convenience init(message: some ConversationMessage) {
        self.init(message: message, content: Self.bubble(markdown: message.bodyMarkdown))
    }

    init(message: some ConversationMessage, content: Box) {
        self.content = content

        widget = Box(orientation: .vertical, spacing: 2)
        widget.halign = .fill
        widget.hexpand = true

        let head = Box(orientation: .horizontal, spacing: 6)
        let icon = Gtk.Image(iconName: Self.icon(of: message.speaker))
        icon.pixelSize = 12
        icon.add(cssClass: "dim-label")
        head.append(child: icon)

        let role = Label(str: Self.roleLabel(of: message))
        role.add(cssClass: "caption")
        role.add(cssClass: "dim-label")
        role.halign = .start
        role.hexpand = true
        role.xalign = 0
        head.append(child: role)

        let time = Label(str: Self.time(of: message.createdAt))
        time.add(cssClass: "caption")
        time.add(cssClass: "dim-label")
        head.append(child: time)
        widget.append(child: head)

        content.marginTop = 2
        widget.append(child: content)
    }

    private static func icon(of speaker: ConversationSpeaker) -> String {
        switch speaker {
        case .user: return "avatar-default-symbolic"
        case .assistant: return "starred-symbolic"
        case .system: return "preferences-system-symbolic"
        }
    }

    private static func roleLabel(of message: some ConversationMessage) -> String {
        switch message.speaker {
        case .user: return message.author?.name ?? "You"
        case .assistant:
            if let modelID = message.modelID, !modelID.isEmpty, modelID != "default" {
                return modelID
            }
            return "Assistant"
        case .system: return "System"
        }
    }

    private static func time(of date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func bubble(markdown: String) -> Box {
        let bubble = Box(orientation: .vertical, spacing: 0)
        bubble.halign = .fill
        bubble.add(cssClass: "luma-address-note-body")
        bubble.add(cssClass: "card")
        show(markdown, in: bubble)
        return bubble
    }

    func show(markdown: String) {
        Self.show(markdown, in: content)
    }

    private static func show(_ markdown: String, in bubble: Box) {
        while let child = bubble.firstChild {
            bubble.remove(child: child)
        }
        let text = MarkdownWidget.make(markdown: markdown, as: .conversation)
        text.marginStart = 8
        text.marginEnd = 8
        text.marginTop = 6
        text.marginBottom = 6
        bubble.append(child: text)
    }

    func show(footer: Widget?) {
        if let existing = self.footer {
            widget.remove(child: existing)
        }
        self.footer = footer
        if let footer {
            widget.insertChildAfter(child: footer, sibling: content)
        }
    }

    func offerEditing(
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        canEdit: @escaping () -> Bool = { true },
        canDelete: @escaping () -> Bool = { true }
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.propagationPhase = .capture
        click.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                var items: [ContextMenu.Item] = []
                if canEdit() {
                    items.append(.init("Edit", handler: onEdit))
                }
                if canDelete() {
                    items.append(.init("Delete", destructive: true, handler: onDelete))
                }
                guard !items.isEmpty else { return }
                ContextMenu.present([items], at: self.content, x: x, y: y)
            }
        }
        content.add(controller: click)
    }

    func edit(_ draft: String, onSave: @escaping (String) -> Void) {
        content.visible = false

        let editor = TextView()
        editor.wrapMode = .word
        editor.topMargin = 6
        editor.bottomMargin = 6
        editor.leftMargin = 8
        editor.rightMargin = 8
        editor.acceptsTab = false
        editor.buffer?.set(text: draft, len: Int(draft.utf8.count))

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.setSizeRequest(width: -1, height: 96)
        scroll.add(cssClass: "card")
        scroll.set(child: editor)
        scroll.marginTop = 2
        widget.append(child: scroll)

        let actions = Box(orientation: .horizontal, spacing: 6)
        actions.halign = .end
        actions.marginTop = 4

        let cancelBtn = Button(label: "Cancel")
        cancelBtn.add(cssClass: "flat")
        cancelBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishEditing(scroll: scroll, actions: actions)
            }
        }

        let saveBtn = Button(label: "Save")
        saveBtn.add(cssClass: "suggested-action")
        saveBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                onSave(editor.text.trimmingCharacters(in: .whitespacesAndNewlines))
                self?.finishEditing(scroll: scroll, actions: actions)
            }
        }

        actions.append(child: cancelBtn)
        actions.append(child: saveBtn)
        widget.append(child: actions)

        _ = editor.grabFocus()
    }

    private func finishEditing(scroll: ScrolledWindow, actions: Box) {
        widget.remove(child: scroll)
        widget.remove(child: actions)
        content.visible = true
    }
}
