import Adw
import CGtk
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class AddressNotePopover {
    private static var active: AddressNotePopover?

    private enum PendingState {
        case idle
        case sending
        case error(String)
    }

    private weak var engine: Engine?
    private let sessionID: UUID
    private let address: UInt64

    private var popover: Popover?
    private var headerTitleLabel: Label?
    private var switchButton: MenuButton?
    private var renameButton: Button?
    private var deleteButton: Button?
    private var bodyHost: Box?
    private var messagesBox: Box?
    private var messagesScroll: ScrolledWindow?
    private var inputView: TextView?
    private var saveButton: Button?
    private var askButton: Button?
    private var askSpinner: Adw.Spinner?
    private var askIcon: Gtk.Image?
    private var streamingRow: Widget?
    private var streamingBody: Label?
    private var streamingText: String = ""
    private var messageRowsByID: [UUID: Box] = [:]
    private var messageBodiesByID: [UUID: Label] = [:]
    private var errorLabel: Label?

    private var notes: [AddressNote] = []
    private var activeNoteID: UUID?
    private var messages: [AddressNoteMessage] = []
    private var pending: PendingState = .idle
    private var unusedTransientNoteIDs: Set<UUID> = []

    init(engine: Engine, sessionID: UUID, address: UInt64) {
        self.engine = engine
        self.sessionID = sessionID
        self.address = address
    }

    func presentAnchored(to anchor: WidgetProtocol, pointingX: Int) {
        AddressNotePopover.active?.dismiss()
        AddressNotePopover.active = self

        let popover = Popover()
        popover.autohide = true
        popover.position = .right
        popover.onClosed { _ in
            MainActor.assumeIsolated {
                guard AddressNotePopover.active === self else { return }
                self.discardUnusedTransientNotes()
                AddressNotePopover.active = nil
            }
        }

        let key = EventControllerKey()
        key.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                if Int32(keyval) == Gdk.keyEscape {
                    self?.dismiss()
                    return true
                }
                return false
            }
        }
        popover.install(controller: key)

        let column = Box(orientation: .vertical, spacing: 0)
        column.setSizeRequest(width: 460, height: 460)

        column.append(child: makeHeader())
        column.append(child: Separator(orientation: .horizontal))

        let host = Box(orientation: .vertical, spacing: 0)
        host.hexpand = true
        host.vexpand = true
        bodyHost = host
        column.append(child: host)

        popover.set(child: column)
        popover.set(parent: WidgetRef(anchor))

        let anchorHeight = max(1, Int(anchor.height))
        var gdkRect = GdkRectangle(
            x: gint(pointingX),
            y: gint(anchorHeight / 2),
            width: 1,
            height: 1
        )
        withUnsafeMutablePointer(to: &gdkRect) { ptr in
            popover.setPointingTo(rect: Gdk.RectangleRef(ptr))
        }

        self.popover = popover

        reloadNotes()
        popover.popup()
    }

    private func dismiss() {
        guard let popover else { return }
        discardUnusedTransientNotes()
        popover.popdown()
        popover.unparent()
        self.popover = nil
        bodyHost = nil
        messagesBox = nil
        messagesScroll = nil
        inputView = nil
        saveButton = nil
        askButton = nil
        askSpinner = nil
        errorLabel = nil
        headerTitleLabel = nil
        switchButton = nil
        renameButton = nil
        deleteButton = nil
    }

    private func makeHeader() -> Widget {
        let header = Box(orientation: .horizontal, spacing: 6)
        header.marginStart = 12
        header.marginEnd = 12
        header.marginTop = 8
        header.marginBottom = 8

        let icon = Gtk.Image(iconName: "mail-unread-symbolic")
        icon.pixelSize = 14
        icon.add(cssClass: "dim-label")
        header.append(child: icon)

        let title = Label(str: String(format: "0x%llx", address))
        title.add(cssClass: "monospace")
        title.halign = .start
        title.hexpand = true
        title.xalign = 0
        headerTitleLabel = title
        header.append(child: title)

        let switchBtn = MenuButton()
        switchBtn.iconName = "view-list-symbolic"
        switchBtn.hasFrame = false
        switchBtn.tooltipText = "Switch thread"
        switchBtn.visible = false
        switchButton = switchBtn
        header.append(child: switchBtn)

        let addBtn = Button()
        let addIcon = Gtk.Image(iconName: "list-add-symbolic")
        addIcon.pixelSize = 12
        addBtn.set(child: addIcon)
        addBtn.add(cssClass: "flat")
        addBtn.tooltipText = "New thread"
        addBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.createNote() }
        }
        header.append(child: addBtn)

        let renameBtn = Button()
        let renameIcon = Gtk.Image(iconName: "document-edit-symbolic")
        renameIcon.pixelSize = 12
        renameBtn.set(child: renameIcon)
        renameBtn.add(cssClass: "flat")
        renameBtn.tooltipText = "Rename thread"
        renameBtn.visible = false
        renameBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.renameActive() }
        }
        renameButton = renameBtn
        header.append(child: renameBtn)

        let delBtn = Button()
        let delIcon = Gtk.Image(iconName: "user-trash-symbolic")
        delIcon.pixelSize = 12
        delBtn.set(child: delIcon)
        delBtn.add(cssClass: "flat")
        delBtn.add(cssClass: "luma-menu-destructive")
        delBtn.tooltipText = "Delete thread"
        delBtn.visible = false
        delBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.deleteActive() }
        }
        deleteButton = delBtn
        header.append(child: delBtn)

        return header
    }

    private func reloadNotes() {
        guard let engine, let node = engine.node(forSessionID: sessionID) else {
            notes = []
            activeNoteID = nil
            rebuildBody()
            return
        }
        let all = engine.addressNotes(sessionID: sessionID)
        notes = all.filter { note in
            (try? node.resolveSyncIfReady(note.anchor)) == address
        }
        if activeNoteID == nil || !notes.contains(where: { $0.id == activeNoteID }) {
            activeNoteID = notes.first?.id
        }
        reloadMessages()
        rebuildBody()
    }

    private func reloadMessages() {
        guard let engine, let id = activeNoteID else {
            messages = []
            return
        }
        messages = engine.addressNoteMessages(noteID: id)
    }

    private func rebuildBody() {
        guard let host = bodyHost else { return }
        while let child = host.firstChild {
            host.remove(child: child)
        }
        messageRowsByID.removeAll()
        messageBodiesByID.removeAll()
        refreshHeaderControls()
        if activeNoteID == nil {
            host.append(child: makeEmptyState())
        } else {
            host.append(child: makeThreadView())
        }
    }

    private func refreshHeaderControls() {
        switchButton?.visible = notes.count > 1
        if let sb = switchButton, notes.count > 1 {
            sb.set(popover: makeSwitchPopover())
        }
        renameButton?.visible = activeNoteID != nil
        deleteButton?.visible = activeNoteID != nil
    }

    private func makeSwitchPopover() -> Popover {
        let pop = Popover()
        pop.position = .bottom
        let list = ListBox()
        list.selectionMode = .none
        list.add(cssClass: "navigation-sidebar")
        for note in notes {
            let row = ListBoxRow()
            let label = Label(str: noteTitle(note))
            label.halign = .start
            label.marginStart = 10
            label.marginEnd = 10
            label.marginTop = 4
            label.marginBottom = 4
            row.set(child: label)
            list.append(child: row)
        }
        list.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                let i = Int(row.index)
                guard i >= 0, i < self.notes.count else { return }
                self.activeNoteID = self.notes[i].id
                self.reloadMessages()
                self.rebuildBody()
                pop.popdown()
            }
        }
        let scroll = ScrolledWindow()
        scroll.setSizeRequest(width: 260, height: 220)
        scroll.set(child: list)
        pop.set(child: scroll)
        return pop
    }

    private func makeEmptyState() -> Widget {
        let box = Box(orientation: .vertical, spacing: 10)
        box.hexpand = true
        box.vexpand = true
        box.halign = .center
        box.valign = .center

        let label = Label(str: "No threads on this address yet.")
        label.add(cssClass: "dim-label")
        box.append(child: label)

        let button = Button(label: "Start a thread")
        button.add(cssClass: "suggested-action")
        button.halign = .center
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.createNote() }
        }
        box.append(child: button)
        return box
    }

    private func makeThreadView() -> Widget {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        messagesScroll = scroll

        let list = Box(orientation: .vertical, spacing: 8)
        list.marginStart = 12
        list.marginEnd = 12
        list.marginTop = 12
        list.marginBottom = 12
        list.valign = .end
        messagesBox = list
        scroll.set(child: list)
        column.append(child: scroll)

        for message in messages {
            list.append(child: makeMessageRow(message))
        }

        column.append(child: Separator(orientation: .horizontal))
        column.append(child: makeInputBar())
        scrollToBottom()
        return column
    }

    private func makeMessageRow(_ message: AddressNoteMessage) -> Box {
        makeMessageRowReturningBody(message).row
    }

    private func makeMessageRowReturningBody(_ message: AddressNoteMessage) -> (row: Box, body: Label) {
        let row = Box(orientation: .vertical, spacing: 2)
        row.halign = .fill
        row.hexpand = true

        let head = Box(orientation: .horizontal, spacing: 6)
        let icon = Gtk.Image(iconName: roleIcon(message.role))
        icon.pixelSize = 12
        icon.add(cssClass: "dim-label")
        head.append(child: icon)

        let role = Label(str: roleLabel(message))
        role.add(cssClass: "caption")
        role.add(cssClass: "dim-label")
        role.halign = .start
        role.hexpand = true
        role.xalign = 0
        head.append(child: role)

        let time = Label(str: formatTime(message.createdAt))
        time.add(cssClass: "caption")
        time.add(cssClass: "dim-label")
        head.append(child: time)
        row.append(child: head)

        let body = Label(str: "")
        body.setMarkup(str: MissionMarkdown.pangoMarkup(from: message.bodyMarkdown))
        body.wrap = true
        body.naturalWrapMode = GTK_NATURAL_WRAP_WORD
        body.xalign = 0
        body.halign = .fill
        body.selectable = true
        body.add(cssClass: "luma-address-note-body")
        body.add(cssClass: "card")
        body.marginTop = 2
        row.append(child: body)

        messageRowsByID[message.id] = row
        messageBodiesByID[message.id] = body
        if message.role == .user {
            installUserMessageActions(row: row, body: body, message: message)
        }
        return (row, body)
    }

    private func installUserMessageActions(row: Box, body: Label, message: AddressNoteMessage) {
        let messageID = message.id
        let click = GestureClick()
        click.set(button: 3)
        click.propagationPhase = GTK_PHASE_CAPTURE
        click.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated {
                self?.showMessageContextMenu(anchor: body, x: x, y: y, messageID: messageID)
            }
        }
        body.install(controller: click)
    }

    private func showMessageContextMenu(anchor: Widget, x: Double, y: Double, messageID: UUID) {
        let items: [ContextMenu.Item] = [
            .init("Edit") { [weak self] in
                self?.beginEditingMessage(messageID: messageID)
            },
            .init("Delete", destructive: true) { [weak self] in
                self?.confirmDeleteMessage(messageID: messageID)
            },
        ]
        ContextMenu.present([items], at: anchor, x: x, y: y)
    }

    private func confirmDeleteMessage(messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }),
            let anchor = messageBodiesByID[messageID]
        else { return }
        confirmDestructive(
            heading: "Delete message?",
            destructiveLabel: "Delete",
            anchor: anchor
        ) { [weak self] in
            self?.commitDeleteMessage(message: message)
        }
    }

    private func commitDeleteMessage(message: AddressNoteMessage) {
        guard let engine, let row = messageRowsByID.removeValue(forKey: message.id) else { return }
        engine.deleteAddressNoteMessage(message)
        messageBodiesByID.removeValue(forKey: message.id)
        messages.removeAll { $0.id == message.id }
        messagesBox?.remove(child: row)
    }

    private func beginEditingMessage(messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }),
            let row = messageRowsByID[messageID],
            let body = messageBodiesByID[messageID]
        else { return }
        body.visible = false

        let editor = TextView()
        editor.wrapMode = .word
        editor.topMargin = 6
        editor.bottomMargin = 6
        editor.leftMargin = 8
        editor.rightMargin = 8
        editor.acceptsTab = false
        editor.buffer?.set(text: message.bodyMarkdown, len: Int(message.bodyMarkdown.utf8.count))

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.setSizeRequest(width: -1, height: 96)
        scroll.add(cssClass: "card")
        scroll.set(child: editor)
        scroll.marginTop = 2
        row.append(child: scroll)

        let actions = Box(orientation: .horizontal, spacing: 6)
        actions.halign = .end
        actions.marginTop = 4

        let cancelBtn = Button(label: "Cancel")
        cancelBtn.add(cssClass: "flat")
        cancelBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishEditingMessage(row: row, body: body, scroll: scroll, actions: actions)
            }
        }

        let saveBtn = Button(label: "Save")
        saveBtn.add(cssClass: "suggested-action")
        saveBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let text = self.textFrom(editor: editor)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != message.bodyMarkdown,
                    let updated = self.engine?.editUserMessage(noteID: message.noteID, messageID: message.id, body: trimmed)
                {
                    self.messages = self.messages.map { $0.id == updated.id ? updated : $0 }
                    body.setMarkup(str: MissionMarkdown.pangoMarkup(from: updated.bodyMarkdown))
                }
                self.finishEditingMessage(row: row, body: body, scroll: scroll, actions: actions)
            }
        }

        actions.append(child: cancelBtn)
        actions.append(child: saveBtn)
        row.append(child: actions)

        _ = editor.grabFocus()
    }

    private func finishEditingMessage(row: Box, body: Label, scroll: ScrolledWindow, actions: Box) {
        row.remove(child: scroll)
        row.remove(child: actions)
        body.visible = true
    }

    private func textFrom(editor: TextView) -> String {
        guard let buffer = editor.buffer else { return "" }
        let startPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let endPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            startPtr.deallocate()
            endPtr.deallocate()
        }
        let start = TextIter(startPtr)
        let end = TextIter(endPtr)
        buffer.getStart(iter: start)
        buffer.getEnd(iter: end)
        return buffer.getText(start: start, end: end, includeHiddenChars: true) ?? ""
    }

    private func makeInputBar() -> Widget {
        let column = Box(orientation: .vertical, spacing: 4)
        column.marginStart = 10
        column.marginEnd = 10
        column.marginTop = 8
        column.marginBottom = 10

        let err = Label(str: "")
        err.add(cssClass: "error")
        err.add(cssClass: "caption")
        err.halign = .start
        err.xalign = 0
        err.visible = false
        errorLabel = err
        column.append(child: err)

        let row = Box(orientation: .horizontal, spacing: 6)
        row.hexpand = true

        let entry = TextView()
        entry.wrapMode = .word
        entry.topMargin = 6
        entry.bottomMargin = 6
        entry.leftMargin = 8
        entry.rightMargin = 8
        entry.acceptsTab = false
        inputView = entry

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.setSizeRequest(width: -1, height: 64)
        scroll.add(cssClass: "card")
        scroll.set(child: entry)
        row.append(child: scroll)

        let buttonColumn = Box(orientation: .vertical, spacing: 4)
        buttonColumn.valign = .end

        let saveBtn = Button()
        let saveIcon = Gtk.Image(iconName: "document-edit-symbolic")
        saveIcon.pixelSize = 14
        saveBtn.set(child: saveIcon)
        saveBtn.add(cssClass: "flat")
        saveBtn.tooltipText = "Save as user note"
        saveBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNote() }
        }
        saveButton = saveBtn
        buttonColumn.append(child: saveBtn)

        let askBtn = Button()
        let askIcon = Gtk.Image(iconName: "mail-send-symbolic")
        askIcon.pixelSize = 14
        let spinner = Adw.Spinner()
        spinner.visible = false
        let askContent = Box(orientation: .horizontal, spacing: 0)
        askContent.append(child: askIcon)
        askContent.append(child: spinner)
        askBtn.set(child: askContent)
        self.askIcon = askIcon
        askBtn.add(cssClass: "suggested-action")
        askBtn.tooltipText = "Ask AI"
        askBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.askAI() }
        }
        askButton = askBtn
        askSpinner = spinner
        buttonColumn.append(child: askBtn)

        row.append(child: buttonColumn)

        column.append(child: row)
        refreshPendingUI()
        return column
    }

    private func refreshPendingUI() {
        let isSending: Bool
        switch pending {
        case .sending: isSending = true
        default: isSending = false
        }
        saveButton?.sensitive = !isSending
        askButton?.sensitive = !isSending
        askSpinner?.visible = isSending
        askIcon?.visible = !isSending
        if case .error(let reason) = pending {
            errorLabel?.label = reason
            errorLabel?.visible = true
        } else {
            errorLabel?.visible = false
        }
    }

    private func appendMessageRow(_ message: AddressNoteMessage) {
        messages.append(message)
        messagesBox?.append(child: makeMessageRow(message))
        scrollToBottom()
    }

    private func scrollToBottom() {
        Task { @MainActor [weak self] in
            guard let scroll = self?.messagesScroll,
                let box = self?.messagesBox,
                let adj = scroll.vadjustment,
                box.width > 0
            else { return }
            var natural: gint = 0
            box.measure(orientation: GTK_ORIENTATION_VERTICAL, for: Int(box.width), natural: &natural)
            adj.upper = Double(natural)
            adj.value = max(0, adj.upper - adj.pageSize)
        }
    }

    private func draftText() -> String {
        guard let buffer = inputView?.buffer else { return "" }
        let startPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let endPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            startPtr.deallocate()
            endPtr.deallocate()
        }
        let start = TextIter(startPtr)
        let end = TextIter(endPtr)
        buffer.getStart(iter: start)
        buffer.getEnd(iter: end)
        return (buffer.getText(start: start, end: end, includeHiddenChars: true) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clearDraft() {
        inputView?.buffer?.set(text: "", len: 0)
    }

    private func createNote() {
        guard let engine, let note = engine.createAddressNote(sessionID: sessionID, address: address) else { return }
        notes.insert(note, at: 0)
        activeNoteID = note.id
        messages = []
        unusedTransientNoteIDs.insert(note.id)
        rebuildBody()
        _ = inputView?.grabFocus()
    }

    private func renameActive() {
        guard let id = activeNoteID,
            let note = notes.first(where: { $0.id == id }),
            let anchor = renameButton
        else { return }
        presentRenamePopover(note: note, anchor: anchor)
    }

    private func presentRenamePopover(note: AddressNote, anchor: Widget) {
        let popover = Popover()
        popover.autohide = true
        popover.position = .bottom
        popover.set(parent: anchor)

        let column = Box(orientation: .vertical, spacing: 8)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12

        let heading = Label(str: "Rename thread")
        heading.add(cssClass: "heading")
        heading.halign = .start
        heading.xalign = 0
        column.append(child: heading)

        let entry = Entry()
        entry.text = noteTitle(note)
        entry.placeholderText = "Title"
        entry.widthChars = 28
        column.append(child: entry)

        let buttonRow = Box(orientation: .horizontal, spacing: 6)
        buttonRow.halign = .end

        let cancelBtn = Button(label: "Cancel")
        cancelBtn.add(cssClass: "flat")
        cancelBtn.onClicked { _ in
            MainActor.assumeIsolated { popover.popdown() }
        }
        buttonRow.append(child: cancelBtn)

        let saveBtn = Button(label: "Save")
        saveBtn.add(cssClass: "suggested-action")
        saveBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                popover.popdown()
                self?.commitRename(note: note, title: entry.text)
            }
        }
        buttonRow.append(child: saveBtn)

        entry.onActivate { [weak self] _ in
            MainActor.assumeIsolated {
                popover.popdown()
                self?.commitRename(note: note, title: entry.text)
            }
        }

        column.append(child: buttonRow)
        popover.set(child: column)
        popover.popup()
        _ = entry.grabFocus()
    }

    private func commitRename(note: AddressNote, title: String) {
        guard let engine else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? nil : trimmed
        guard newTitle != note.title else { return }
        var updated = note
        updated.title = newTitle
        engine.updateAddressNote(updated)
        notes = notes.map { $0.id == updated.id ? updated : $0 }
        refreshHeaderControls()
    }

    private func deleteActive() {
        guard let id = activeNoteID,
            let note = notes.first(where: { $0.id == id }),
            let anchor = deleteButton
        else { return }
        confirmDestructive(
            heading: "Delete thread?",
            destructiveLabel: "Delete",
            anchor: anchor
        ) { [weak self] in
            self?.commitDeleteActive(note: note)
        }
    }

    private func commitDeleteActive(note: AddressNote) {
        guard let engine else { return }
        engine.deleteAddressNote(note)
        notes.removeAll { $0.id == note.id }
        unusedTransientNoteIDs.remove(note.id)
        activeNoteID = notes.first?.id
        reloadMessages()
        if notes.isEmpty {
            dismiss()
            return
        }
        rebuildBody()
    }

    private func confirmDestructive(heading: String, destructiveLabel: String, anchor: Widget, action: @escaping () -> Void) {
        let confirmation = Popover()
        confirmation.autohide = true
        confirmation.position = .bottom
        confirmation.set(parent: anchor)

        let column = Box(orientation: .vertical, spacing: 8)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12

        let headingLabel = Label(str: heading)
        headingLabel.halign = .start
        headingLabel.xalign = 0
        headingLabel.add(cssClass: "heading")
        column.append(child: headingLabel)

        let buttonRow = Box(orientation: .horizontal, spacing: 6)
        buttonRow.halign = .end

        let cancelBtn = Button(label: "Cancel")
        cancelBtn.add(cssClass: "flat")
        cancelBtn.onClicked { _ in
            MainActor.assumeIsolated { confirmation.popdown() }
        }
        buttonRow.append(child: cancelBtn)

        let confirmBtn = Button(label: destructiveLabel)
        confirmBtn.add(cssClass: "destructive-action")
        confirmBtn.onClicked { _ in
            MainActor.assumeIsolated {
                confirmation.popdown()
                action()
            }
        }
        buttonRow.append(child: confirmBtn)
        column.append(child: buttonRow)

        confirmation.set(child: column)
        confirmation.popup()
    }

    private func saveNote() {
        guard let engine, let id = activeNoteID else { return }
        let body = draftText()
        guard !body.isEmpty, let message = engine.appendUserMessage(noteID: id, body: body) else { return }
        appendMessageRow(message)
        unusedTransientNoteIDs.remove(id)
        clearDraft()
    }

    private func askAI() {
        guard let engine, let id = activeNoteID else { return }
        let body = draftText()
        guard !body.isEmpty else { return }
        guard let userMessage = engine.appendUserMessage(noteID: id, body: body) else { return }
        appendMessageRow(userMessage)
        unusedTransientNoteIDs.remove(id)
        clearDraft()
        pending = .sending
        refreshPendingUI()
        startStreamingPlaceholder(modelID: LumaAppState.shared.missionDefaults.modelID)
        let defaults = LumaAppState.shared.missionDefaults
        Task { @MainActor in
            let reply = await engine.requestAIReply(
                noteID: id,
                providerID: defaults.providerID,
                modelID: defaults.modelID,
                onDelta: { [weak self] delta in self?.appendStreamingDelta(delta) }
            )
            self.removeStreamingPlaceholder()
            if let reply {
                self.appendMessageRow(reply)
                self.pending = .idle
            } else {
                self.pending = .error("Reply failed. Check provider settings.")
            }
            self.refreshPendingUI()
        }
    }

    private func startStreamingPlaceholder(modelID: String) {
        streamingText = ""
        let placeholder = AddressNoteMessage(
            noteID: activeNoteID ?? UUID(),
            index: -1,
            role: .assistant,
            bodyMarkdown: "",
            modelID: modelID
        )
        let (row, body) = makeMessageRowReturningBody(placeholder)
        streamingRow = row
        streamingBody = body
        messagesBox?.append(child: row)
        scrollToBottom()
    }

    private func appendStreamingDelta(_ delta: String) {
        streamingText += delta
        streamingBody?.setMarkup(str: MissionMarkdown.pangoMarkup(from: streamingText))
        scrollToBottom()
    }

    private func removeStreamingPlaceholder() {
        if let row = streamingRow {
            messagesBox?.remove(child: row)
        }
        streamingRow = nil
        streamingBody = nil
        streamingText = ""
    }

    private func discardUnusedTransientNotes() {
        guard let engine else {
            unusedTransientNoteIDs.removeAll()
            return
        }
        for note in notes where engine.addressNoteMessages(noteID: note.id).isEmpty {
            engine.deleteAddressNote(note)
        }
        unusedTransientNoteIDs.removeAll()
    }

    private func noteTitle(_ note: AddressNote) -> String {
        if let title = note.title, !title.isEmpty { return title }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "Thread from \(formatter.string(from: note.createdAt))"
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func roleIcon(_ role: AddressNoteMessage.Role) -> String {
        switch role {
        case .user: return "avatar-default-symbolic"
        case .assistant: return "starred-symbolic"
        case .system: return "preferences-system-symbolic"
        }
    }

    private func roleLabel(_ message: AddressNoteMessage) -> String {
        switch message.role {
        case .user: return message.author?.name ?? "You"
        case .assistant:
            if let modelID = message.modelID, !modelID.isEmpty, modelID != "default" {
                return modelID
            }
            return "Assistant"
        case .system: return "System"
        }
    }
}
