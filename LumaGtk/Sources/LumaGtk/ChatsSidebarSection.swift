import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class ChatsSidebarSection {
    let listBox = ListBox()
    var onSelect: (UUID) -> Void = { _ in }

    private let engine: Engine
    private let headerRow = ListBoxRow()
    private let countLabel = Label(str: "")
    private let unreadBadge = Label(str: "")
    private let chevron = Gtk.Image(iconName: "pan-down-symbolic")
    private let chevronButton = Button()
    private var shown: [Row] = []
    private var selected: UUID?

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private struct Row: Equatable {
        let id: UUID
        let isProject: Bool
        let title: String
        let about: String
        let unread: Int
        let latest: String?
    }

    init(engine: Engine) {
        self.engine = engine
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")
        listBox.add(cssClass: "luma-flush-sidebar-list")
        listBox.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated { self?.choose(rowIndex: Int(row.index)) }
        }
        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                self.choose(rowIndex: Int(row.index))
            }
        }

        let heading = SidebarFeatureRow.makeSectionHeading(iconName: "chat-message-new-symbolic", title: "Chats")
        unreadBadge.add(cssClass: "caption")
        unreadBadge.add(cssClass: "error")
        unreadBadge.visible = false
        heading.append(child: unreadBadge)
        countLabel.add(cssClass: "dim-label")
        countLabel.add(cssClass: "caption")
        heading.append(child: countLabel)
        chevron.pixelSize = 12
        chevron.add(cssClass: "dim-label")
        chevronButton.set(child: chevron)
        chevronButton.add(cssClass: "flat")
        chevronButton.add(cssClass: "circular")
        chevronButton.add(cssClass: "luma-sidebar-chevron")
        chevronButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleExpansion() }
        }
        heading.append(child: chevronButton)
        headerRow.set(child: heading)
        headerRow.selectable = false
        headerRow.activatable = false
        listBox.append(child: headerRow)

        follow()
        applyExpansion()
    }

    private var isExpanded: Bool {
        engine.sidebarExpansion(of: .chats) == .expanded
    }

    private func toggleExpansion() {
        engine.setSidebarExpansion(section: .chats, isExpanded ? .collapsed : .expanded)
        applyExpansion()
    }

    private func applyExpansion() {
        chevron.set(name: isExpanded ? "pan-down-symbolic" : "pan-end-symbolic")
        chevronButton.tooltipText = isExpanded ? "Hide chats" : "Show chats"
        for index in shown.indices {
            listBox.getRowAt(index: index + 1)?.visible = isExpanded
        }
    }

    func select(_ chatID: UUID?) {
        selected = chatID
        guard let chatID, let index = shown.firstIndex(where: { $0.id == chatID }), let row = listBox.getRowAt(index: index + 1) else {
            listBox.unselectAll()
            return
        }
        listBox.select(row: row)
    }

    private func choose(rowIndex: Int) {
        guard rowIndex > 0 else { return }
        let row = shown[rowIndex - 1]
        let chatID = row.isProject ? engine.objectChats.openConversation().id : row.id
        guard chatID != selected else { return }
        onSelect(chatID)
    }

    private func follow() {
        let rows = withObservationTracking {
            rowsNow()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        countLabel.label = "\(rows.count)"
        let unread = engine.objectChats.unreadTotal
        unreadBadge.label = "\(unread)"
        unreadBadge.visible = unread > 0
        guard rows != shown else { return }
        shown = rows
        while let row = listBox.getRowAt(index: 1) {
            listBox.remove(child: row)
        }
        for row in rows {
            listBox.append(child: make(row))
        }
        applyExpansion()
        select(selected)
    }

    private func rowsNow() -> [Row] {
        let chats = engine.objectChats
        return chats.sidebarChatIDs.map { chatID in
            let chat = chats.chat(withID: chatID)
            let latest = chats.thread(of: chatID).messages.last.map { message in
                let author = message.role == .assistant ? "Assistant" : chats.isMine(message) ? "You" : message.author?.name ?? "You"
                return "\(author) \u{00B7} \(Self.clock.string(from: message.createdAt))"
            }
            return Row(
                id: chatID, isProject: chatID == chats.conversationID, title: chat.map(chats.displayTitle(of:)) ?? "Project Chat",
                about: chat.map { about($0, at: chats.subject(of: $0)) } ?? "Project", unread: chats.unreadCount(in: chatID), latest: latest)
        }
    }

    private func about(_ chat: ObjectChat, at subject: ObjectChatSubjectPlace) -> String {
        switch (subject, chat.subject) {
        case (.instruction(let place), _):
            [place.anchor.displayString, place.sessionName].compactMap { $0 }.joined(separator: " \u{00B7} ")
        case (_, .object(_, let label, _, let className, _, _)):
            "\(className) \u{00B7} \(label)"
        case (_, .project), (_, .instruction):
            "Project"
        }
    }

    private func make(_ row: Row) -> ListBoxRow {
        let listRow = ListBoxRow()
        let box = Box(orientation: .horizontal, spacing: 8)
        box.marginStart = 28
        box.marginEnd = 12
        box.marginTop = 4
        box.marginBottom = 4

        let icon = Gtk.Image(iconName: row.isProject ? "system-users-symbolic" : "chat-message-new-symbolic")
        icon.add(cssClass: "dim-label")
        icon.valign = .start
        icon.marginTop = 2
        box.append(child: icon)

        let column = Box(orientation: .vertical, spacing: 1)
        column.hexpand = true
        column.append(child: line(row.title, classes: []))
        column.append(child: line(row.about, classes: ["dim-label", "caption"]))
        if let latest = row.latest {
            column.append(child: line(latest, classes: ["dim-label", "caption"]))
        }
        box.append(child: column)

        if row.unread > 0 {
            let badge = Label(str: "\(row.unread)")
            badge.add(cssClass: "caption")
            badge.add(cssClass: "error")
            badge.valign = .center
            box.append(child: badge)
        }
        listRow.set(child: box)
        ContextMenu.attach(to: listRow, anchor: box) { [weak self, box] x, y in
            self?.presentMenu(at: box, x: x, y: y, chatID: row.id)
        }
        return listRow
    }

    private func presentMenu(at anchor: Box, x: Double, y: Double, chatID: UUID) {
        let chats = engine.objectChats
        guard let chat = chats.chat(withID: chatID) ?? (chatID == chats.conversationID ? chats.openConversation() : nil) else { return }
        var first: [ContextMenu.Item] = [
            .init("Show Subject") { PharoObjectChatPage.showSubject?(chats.subject(of: chat)) }
        ]
        if chats.unreadCount(in: chatID) > 0 {
            first.append(.init("Mark as Read") { chats.markRead(chatID) })
        }
        var sections = [first]
        if chatID != chats.conversationID {
            let canRename = chats.canRename(chatID)
            let canDelete = chats.canDelete(chatID)
            sections.append([
                .init("Rename\u{2026}", detail: canRename ? nil : "This chat was deleted in the lab", enabled: canRename) {
                    RenamePopover.present(heading: "Rename chat", title: chats.displayTitle(of: chat), at: anchor) { title in
                        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !title.isEmpty {
                            chats.rename(chatID, to: title)
                        }
                    }
                },
                .init(
                    "Delete", detail: canDelete ? nil : "Only the member who started this chat, or a lab owner, can delete it", destructive: true,
                    enabled: canDelete
                ) {
                    ConfirmationPopover.present(heading: "Delete this chat?", destructiveLabel: "Delete", at: anchor) {
                        Task { @MainActor [weak self] in
                            if let self, self.selected == chatID {
                                self.onSelect(chats.openConversation().id)
                            }
                            do {
                                try await chats.delete(chatID)
                            } catch {
                                AddressActionMenu.errorReporter?("Can\u{2019}t delete the chat: \(error.localizedDescription)")
                            }
                        }
                    }
                },
            ])
        }
        ContextMenu.present(sections, at: anchor, x: x, y: y)
    }

    private func line(_ text: String, classes: [String]) -> Label {
        let label = Label(str: text)
        for each in classes {
            label.add(cssClass: each)
        }
        label.halign = .start
        label.xalign = 0
        label.ellipsize = .end
        label.maxWidthChars = 26
        return label
    }
}

extension ObjectChats {
    var sidebarChatIDs: [UUID] {
        [conversationID] + listed.map(\.id).filter { $0 != conversationID }
    }

    var unreadTotal: Int {
        sidebarChatIDs.reduce(0) { $0 + unreadCount(in: $1) }
    }
}
