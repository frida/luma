import Adw
import CGtk
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
struct AddressNotePointingRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

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
    private var deleteButton: Button?
    private var bodyHost: Box?
    private var messagesBox: Box?
    private var messagesScroll: ScrolledWindow?
    private var inputView: TextView?
    private var saveButton: Button?
    private var askButton: Button?
    private var askSpinner: Adw.Spinner?
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

    func presentAnchored(to parent: WidgetProtocol, pointingTo rect: AddressNotePointingRect) {
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
        popover.set(parent: WidgetRef(parent))

        var gdkRect = GdkRectangle(
            x: gint(rect.x),
            y: gint(rect.y),
            width: gint(max(1, rect.width)),
            height: gint(max(1, rect.height))
        )
        withUnsafeMutablePointer(to: &gdkRect) { ptr in
            gtk_popover_set_pointing_to(popover.popover_ptr, ptr)
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
        messagesBox = list
        scroll.set(child: list)
        column.append(child: scroll)

        for message in messages {
            list.append(child: makeMessageRow(message))
        }

        column.append(child: Separator(orientation: .horizontal))
        column.append(child: makeInputBar())
        return column
    }

    private func makeMessageRow(_ message: AddressNoteMessage) -> Widget {
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
        body.xalign = 0
        body.halign = .fill
        body.selectable = true
        body.add(cssClass: "luma-address-note-body")
        body.add(cssClass: "card")
        body.marginTop = 2
        row.append(child: body)
        return row
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

        let submitKey = EventControllerKey()
        submitKey.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                let key = Int32(keyval)
                guard key == Gdk.keyReturn || key == Gdk.keyKPEnter else { return false }
                if state.contains(.shiftMask) { return false }
                guard let self else { return true }
                if case .sending = self.pending { return true }
                if self.draftText().isEmpty { return true }
                self.askAI()
                return true
            }
        }
        entry.install(controller: submitKey)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.setSizeRequest(width: -1, height: 64)
        scroll.add(cssClass: "card")
        scroll.set(child: entry)
        row.append(child: scroll)

        let saveBtn = Button()
        let saveIcon = Gtk.Image(iconName: "document-edit-symbolic")
        saveIcon.pixelSize = 14
        saveBtn.set(child: saveIcon)
        saveBtn.add(cssClass: "flat")
        saveBtn.tooltipText = "Save as user note"
        saveBtn.valign = .end
        saveBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNote() }
        }
        saveButton = saveBtn
        row.append(child: saveBtn)

        let askBtn = Button()
        let askContent = Box(orientation: .horizontal, spacing: 0)
        let askIcon = Gtk.Image(iconName: "mail-send-symbolic")
        askIcon.pixelSize = 14
        askContent.append(child: askIcon)
        let spinner = Adw.Spinner()
        spinner.visible = false
        askContent.append(child: spinner)
        askBtn.set(child: askContent)
        askBtn.add(cssClass: "suggested-action")
        askBtn.tooltipText = "Ask AI"
        askBtn.valign = .end
        askBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.askAI() }
        }
        askButton = askBtn
        askSpinner = spinner
        row.append(child: askBtn)

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
        Task { @MainActor in
            if let adj = self.messagesScroll?.vadjustment {
                adj.value = max(0, adj.upper - adj.pageSize)
            }
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
    }

    private func deleteActive() {
        guard let engine, let id = activeNoteID, let note = notes.first(where: { $0.id == id }) else { return }
        engine.deleteAddressNote(note)
        notes.removeAll { $0.id == id }
        unusedTransientNoteIDs.remove(id)
        activeNoteID = notes.first?.id
        reloadMessages()
        if notes.isEmpty {
            dismiss()
            return
        }
        rebuildBody()
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
        let defaults = LumaAppState.shared.missionDefaults
        Task { @MainActor in
            let reply = await engine.requestAIReply(
                noteID: id,
                providerID: defaults.providerID,
                modelID: defaults.modelID
            )
            if let reply {
                self.appendMessageRow(reply)
                self.pending = .idle
            } else {
                self.pending = .error("Reply failed. Check provider settings.")
            }
            self.refreshPendingUI()
        }
    }

    private func discardUnusedTransientNotes() {
        guard let engine else {
            unusedTransientNoteIDs.removeAll()
            return
        }
        for noteID in unusedTransientNoteIDs {
            guard let note = notes.first(where: { $0.id == noteID }) else { continue }
            guard engine.addressNoteMessages(noteID: noteID).isEmpty else { continue }
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
        case .assistant: return message.modelID ?? "Assistant"
        case .system: return "System"
        }
    }
}
