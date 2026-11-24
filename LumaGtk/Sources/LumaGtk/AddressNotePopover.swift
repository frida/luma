import Adw
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

    private var dialog: Adw.Dialog?
    private var headerTitleLabel: Label?
    private var switchButton: MenuButton?
    private var renameButton: Button?
    private var deleteButton: Button?
    private var bodyHost: Box?
    private var transcript: ConversationTranscript?
    private var inputBar: ConversationInputBar?
    private var streamingRow: ConversationMessageRow?
    private var streamingText: String = ""
    private var messageRows: [UUID: ConversationMessageRow] = [:]

    private var notes: [AddressNote] = []
    private var activeNoteID: UUID?
    private var messages: [AddressNoteMessage] = []
    private var pending: PendingState = .idle
    private var unusedTransientNoteIDs: Set<UUID> = []
    private var pendingActions: [MissionAction] = []
    private var actionsObservation: StoreObservation?
    private var approvalsBox: Box?
    private var approvalDecisions: [MissionActionDecision] = []

    init(engine: Engine, sessionID: UUID, address: UInt64) {
        self.engine = engine
        self.sessionID = sessionID
        self.address = address
    }

    func presentAnchored(to anchor: WidgetProtocol, pointingX: Int) {
        AddressNotePopover.active?.dismiss()
        AddressNotePopover.active = self

        let dialog = Adw.Dialog()
        dialog.set(title: "Notes & AI")
        dialog.set(contentWidth: 460)
        dialog.set(contentHeight: 520)
        dialog.onClosed { _ in
            MainActor.assumeIsolated { self.teardown() }
        }

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: makeHeader())
        column.append(child: Separator(orientation: .horizontal))

        let host = Box(orientation: .vertical, spacing: 0)
        host.hexpand = true
        host.vexpand = true
        bodyHost = host
        column.append(child: host)

        dialog.set(child: column)

        self.dialog = dialog

        reloadNotes()
        observePendingActions()
        dialog.present(parent: anchor)
    }

    private func observePendingActions() {
        guard let engine else { return }
        updatePendingActions((try? engine.store.fetchAllPendingMissionActions()) ?? [])
        actionsObservation = engine.store.observeAllPendingMissionActions { [weak self] rows in
            Task { @MainActor in self?.updatePendingActions(rows) }
        }
    }

    private func updatePendingActions(_ rows: [MissionAction]) {
        guard let engine else {
            pendingActions = []
            refreshApprovals()
            return
        }
        pendingActions = rows.filter {
            $0.sessionID == sessionID && engine.isAmbientMission($0.missionID)
        }
        refreshApprovals()
    }

    private func dismiss() {
        teardown()
    }

    private func teardown() {
        guard let dialog else { return }
        discardUnusedTransientNotes()
        actionsObservation = nil
        approvalsBox = nil
        self.dialog = nil
        _ = dialog.close()
        bodyHost = nil
        transcript = nil
        inputBar = nil
        headerTitleLabel = nil
        switchButton = nil
        renameButton = nil
        deleteButton = nil
        if AddressNotePopover.active === self {
            AddressNotePopover.active = nil
        }
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

        let closeBtn = Button()
        let closeIcon = Gtk.Image(iconName: "window-close-symbolic")
        closeIcon.pixelSize = 12
        closeBtn.set(child: closeIcon)
        closeBtn.add(cssClass: "flat")
        closeBtn.tooltipText = "Close"
        closeBtn.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        header.append(child: closeBtn)

        return header
    }

    private func reloadNotes() {
        guard let engine else {
            notes = []
            activeNoteID = nil
            rebuildBody()
            return
        }
        notes = engine.addressNotes(sessionID: sessionID).filter { note in
            engine.resolveSync(sessionID: sessionID, anchor: note.anchor) == address
        }
        if activeNoteID == nil || !notes.contains(where: { $0.id == activeNoteID }) {
            activeNoteID = notes.last?.id
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
        messageRows.removeAll()
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
            let rowBox = Box(orientation: .horizontal, spacing: 6)
            rowBox.marginStart = 10
            rowBox.marginEnd = 10
            rowBox.marginTop = 4
            rowBox.marginBottom = 4

            let check = Gtk.Image(iconName: "object-select-symbolic")
            check.pixelSize = 12
            check.opacity = note.id == activeNoteID ? 1.0 : 0.0
            rowBox.append(child: check)

            let label = Label(str: noteTitle(note))
            label.halign = .start
            label.hexpand = true
            label.xalign = 0
            rowBox.append(child: label)

            row.set(child: rowBox)
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
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroll.propagateNaturalWidth = true
        scroll.propagateNaturalHeight = true
        scroll.maxContentHeight = 220
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

        let transcript = ConversationTranscript()
        self.transcript = transcript
        column.append(child: transcript.widget)

        for message in messages {
            transcript.append(makeMessageRow(message).widget)
        }

        let approvals = Box(orientation: .vertical, spacing: 6)
        approvals.marginStart = 12
        approvals.marginEnd = 12
        approvals.marginTop = 8
        approvals.marginBottom = 8
        approvals.add(cssClass: "luma-address-note-approvals")
        approvalsBox = approvals
        column.append(child: approvals)

        column.append(child: Separator(orientation: .horizontal))
        column.append(child: makeInputBar())
        refreshApprovals()
        transcript.scrollToBottom()
        return column
    }

    private func refreshApprovals() {
        guard let container = approvalsBox else { return }
        while let child = container.firstChild {
            container.remove(child: child)
        }
        approvalDecisions = []
        container.visible = !pendingActions.isEmpty
        for action in pendingActions {
            if action.toolName == MissionTools.requestUserInputToolName {
                container.append(child: makeRequestInputCard(action))
            } else {
                container.append(child: makeApprovalCard(action))
            }
        }
    }

    private func makeApprovalCard(_ action: MissionAction) -> Widget {
        let card = Box(orientation: .vertical, spacing: 6)
        card.add(cssClass: "card")
        card.add(cssClass: "luma-mission-queue-card")

        let inner = Box(orientation: .vertical, spacing: 6)
        inner.marginStart = 12
        inner.marginEnd = 12
        inner.marginTop = 10
        inner.marginBottom = 10
        card.append(child: inner)

        let header = Box(orientation: .horizontal, spacing: 8)
        let icon = Gtk.Image(iconName: "applications-engineering-symbolic")
        icon.pixelSize = 14
        icon.add(cssClass: "accent")
        header.append(child: icon)
        let name = Label(str: action.toolName)
        name.add(cssClass: "monospace")
        name.add(cssClass: "heading")
        name.halign = .start
        name.hexpand = true
        name.xalign = 0
        header.append(child: name)
        inner.append(child: header)

        let args = parseArgs(action.argsJSON)
        if let source = codeSource(toolName: action.toolName, args: args) {
            inner.append(child: makeCodeView(source))
        }
        if let json = remainingArgsJSON(toolName: action.toolName, args: args) {
            let jsonLabel = Label(str: json)
            jsonLabel.add(cssClass: "monospace")
            jsonLabel.add(cssClass: "caption")
            jsonLabel.halign = .start
            jsonLabel.xalign = 0
            jsonLabel.wrap = true
            jsonLabel.selectable = true
            inner.append(child: jsonLabel)
        }
        if let rationale = action.rationale {
            let r = Label(str: rationale)
            r.add(cssClass: "dim-label")
            r.halign = .start
            r.xalign = 0
            r.wrap = true
            inner.append(child: r)
        }

        let decision = MissionActionDecision(
            action: action,
            engine: engine,
            onApprove: { [weak self] in
                guard let engine = self?.engine else { return }
                Task { @MainActor in await engine.approveMissionAction(actionID: action.id) }
            },
            onReject: { [weak self] in
                guard let engine = self?.engine else { return }
                Task { @MainActor in await engine.rejectMissionAction(actionID: action.id) }
            }
        )
        approvalDecisions.append(decision)
        inner.append(child: decision.widget)

        return card
    }

    private func makeRequestInputCard(_ action: MissionAction) -> Widget {
        let card = Box(orientation: .vertical, spacing: 8)
        card.add(cssClass: "card")

        let inner = Box(orientation: .vertical, spacing: 8)
        inner.marginStart = 12
        inner.marginEnd = 12
        inner.marginTop = 10
        inner.marginBottom = 10
        card.append(child: inner)

        let args = parseArgs(action.argsJSON)
        let question = Label(str: (args["question"] as? String) ?? "(no question provided)")
        question.wrap = true
        question.halign = .start
        question.xalign = 0
        inner.append(child: question)

        if let options = args["options"] as? [String], !options.isEmpty {
            for option in options {
                let button = Button(label: option)
                button.onClicked { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.engine?.submitUserInputResponse(actionID: action.id, answer: option)
                    }
                }
                inner.append(child: button)
            }
        } else {
            let entry = Entry()
            entry.placeholderText = "Your answer"
            inner.append(child: entry)
            let submit = Button(label: "Submit")
            submit.add(cssClass: "suggested-action")
            submit.halign = .end
            submit.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.engine?.submitUserInputResponse(actionID: action.id, answer: entry.text ?? "")
                }
            }
            inner.append(child: submit)
        }

        return card
    }

    private func makeCodeView(_ source: String) -> Widget {
        let view = TextView()
        view.editable = false
        view.monospace = true
        view.topMargin = 6
        view.bottomMargin = 6
        view.leftMargin = 8
        view.rightMargin = 8
        view.buffer?.set(text: source, len: Int(source.utf8.count))

        let scroll = ScrolledWindow()
        scroll.add(cssClass: "card")
        scroll.setSizeRequest(width: -1, height: 160)
        scroll.set(child: view)
        return scroll
    }

    private func codeSource(toolName: String, args: [String: Any]) -> String? {
        guard let field = engine?.missionTools.spec(named: toolName)?.codePreview?.field,
            let source = args[field] as? String
        else { return nil }
        return source
    }

    private func remainingArgsJSON(toolName: String, args: [String: Any]) -> String? {
        var stripped = args
        if let field = engine?.missionTools.spec(named: toolName)?.codePreview?.field {
            stripped.removeValue(forKey: field)
        }
        if stripped.isEmpty { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: stripped, options: [.prettyPrinted, .sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func makeMessageRow(_ message: AddressNoteMessage) -> ConversationMessageRow {
        let row = ConversationMessageRow(message: message)
        messageRows[message.id] = row
        if message.role == .user {
            let messageID = message.id
            row.offerEditing(
                onEdit: { [weak self] in self?.beginEditingMessage(messageID: messageID) },
                onDelete: { [weak self] in self?.confirmDeleteMessage(messageID: messageID) })
        }
        return row
    }

    private func confirmDeleteMessage(messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }),
            let anchor = messageRows[messageID]?.content
        else { return }
        ConfirmationPopover.present(
            heading: "Delete message?",
            destructiveLabel: "Delete",
            at: anchor
        ) { [weak self] in
            self?.commitDeleteMessage(message: message)
        }
    }

    private func commitDeleteMessage(message: AddressNoteMessage) {
        guard let engine, let row = messageRows.removeValue(forKey: message.id) else { return }
        engine.deleteAddressNoteMessage(message)
        messages.removeAll { $0.id == message.id }
        transcript?.remove(row.widget)
    }

    private func beginEditingMessage(messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }),
            let row = messageRows[messageID]
        else { return }
        row.edit(message.bodyMarkdown) { [weak self] trimmed in
            guard let self else { return }
            if !trimmed.isEmpty, trimmed != message.bodyMarkdown,
                let updated = self.engine?.editUserMessage(noteID: message.noteID, messageID: message.id, body: trimmed)
            {
                self.messages = self.messages.map { $0.id == updated.id ? updated : $0 }
                row.show(markdown: updated.bodyMarkdown)
            }
        }
    }

    private func makeInputBar() -> Widget {
        let bar = ConversationInputBar(
            primary: .init(iconName: "mail-send-symbolic", tooltip: "Ask AI") { [weak self] in self?.askAI() },
            secondary: .init(iconName: "document-edit-symbolic", tooltip: "Save as user note") { [weak self] in self?.saveNote() },
            onStop: { [weak self] in self?.cancelReply() })
        inputBar = bar
        refreshPendingUI()
        return bar.widget
    }

    private func refreshPendingUI() {
        let isSending: Bool
        switch pending {
        case .sending: isSending = true
        default: isSending = false
        }
        let failure: String?
        if case .error(let reason) = pending {
            failure = reason
        } else {
            failure = nil
        }
        inputBar?.show(isSending: isSending, failure: failure)
    }

    private func appendMessageRow(_ message: AddressNoteMessage) {
        messages.append(message)
        transcript?.append(makeMessageRow(message).widget)
        transcript?.scrollToBottom()
    }

    private func createNote() {
        guard let engine, let note = engine.createAddressNote(sessionID: sessionID, address: address) else { return }
        notes.append(note)
        activeNoteID = note.id
        messages = []
        unusedTransientNoteIDs.insert(note.id)
        rebuildBody()
        inputBar?.focus()
    }

    private func renameActive() {
        guard let id = activeNoteID,
            let note = notes.first(where: { $0.id == id }),
            let anchor = renameButton
        else { return }
        RenamePopover.present(heading: "Rename thread", title: noteTitle(note), at: anchor) { [weak self] title in
            self?.commitRename(note: note, title: title)
        }
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
        ConfirmationPopover.present(
            heading: "Delete thread?",
            destructiveLabel: "Delete",
            at: anchor
        ) { [weak self] in
            self?.commitDeleteActive(note: note)
        }
    }

    private func commitDeleteActive(note: AddressNote) {
        guard let engine else { return }
        engine.deleteAddressNote(note)
        notes.removeAll { $0.id == note.id }
        unusedTransientNoteIDs.remove(note.id)
        activeNoteID = notes.last?.id
        reloadMessages()
        if notes.isEmpty {
            dismiss()
            return
        }
        rebuildBody()
    }

    private func saveNote() {
        guard let engine, let id = activeNoteID else { return }
        guard let inputBar else { return }
        let body = inputBar.draft
        guard !body.isEmpty, let message = engine.appendUserMessage(noteID: id, body: body) else { return }
        appendMessageRow(message)
        unusedTransientNoteIDs.remove(id)
        inputBar.clearDraft()
    }

    private func cancelReply() {
        guard let engine else { return }
        Task { @MainActor in
            await engine.cancelAddressNoteReply(sessionID: sessionID)
        }
    }

    private func askAI() {
        guard let engine, let id = activeNoteID, let inputBar else { return }
        let body = inputBar.draft
        guard !body.isEmpty else { return }
        guard let userMessage = engine.appendUserMessage(noteID: id, body: body) else { return }
        appendMessageRow(userMessage)
        unusedTransientNoteIDs.remove(id)
        inputBar.clearDraft()
        pending = .sending
        refreshPendingUI()
        startStreamingPlaceholder(modelID: LumaAppState.shared.missionDefaults.modelID)
        let defaults = LumaAppState.shared.missionDefaults
        Task { @MainActor in
            let reply = await engine.requestAIReply(
                noteID: id,
                providerID: defaults.providerID,
                modelID: defaults.modelID,
                onDelta: { delta in self.appendStreamingDelta(delta) }
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
        let row = ConversationMessageRow(message: placeholder)
        streamingRow = row
        transcript?.append(row.widget)
        transcript?.scrollToBottom()
    }

    private func appendStreamingDelta(_ delta: String) {
        streamingText += delta
        streamingRow?.show(markdown: streamingText)
        transcript?.scrollToBottom()
    }

    private func removeStreamingPlaceholder() {
        if let row = streamingRow {
            transcript?.remove(row.widget)
        }
        streamingRow = nil
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
}
