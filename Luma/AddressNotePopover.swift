import LumaCore
import SwiftUI

struct AddressNotePopover: View {
    let engine: Engine
    let sessionID: UUID
    let address: UInt64
    @Binding var isPresented: Bool

    @State private var notes: [AddressNote] = []
    @State private var activeNoteID: UUID?
    @State private var messages: [AddressNoteMessage] = []
    @State private var draft: String = ""
    @State private var pending: PendingState = .idle
    @State private var unusedTransientNoteIDs: Set<UUID> = []
    @State private var pendingActions: [MissionAction] = []
    @State private var actionsObservation: LumaCore.StoreObservation?
    @State private var rejectingAction: MissionAction?
    @State private var rejectReason: String = ""
    @State private var editingMessageID: UUID?
    @State private var editingDraft: String = ""
    @State private var pendingDeleteThread: AddressNote?
    @State private var pendingDeleteMessage: AddressNoteMessage?
    @State private var renamingNoteID: UUID?
    @State private var renameDraft: String = ""

    @FocusState private var inputFocused: Bool
    @FocusState private var editFocused: Bool

    private enum PendingState {
        case idle
        case sending
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let note = activeNote {
                threadView(note: note)
            } else {
                emptyState
            }
        }
        .frame(width: 460, height: 460)
        .onAppear {
            refresh()
            observePendingActions()
            DispatchQueue.main.async { inputFocused = true }
        }
        .onChange(of: activeNoteID) { _, _ in reloadActiveNote() }
        .onChange(of: hasActiveReply) { _, active in
            pending = active ? .sending : .idle
            if !active { reloadMessages() }
        }
        .onDisappear {
            actionsObservation = nil
            discardUnusedTransientNotes()
        }
        .confirmationDialog(
            "Delete thread?",
            isPresented: Binding(
                get: { pendingDeleteThread != nil },
                set: { if !$0 { pendingDeleteThread = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteThread
        ) { note in
            Button("Delete", role: .destructive) { commitDelete(note: note) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete message?",
            isPresented: Binding(
                get: { pendingDeleteMessage != nil },
                set: { if !$0 { pendingDeleteMessage = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteMessage
        ) { message in
            Button("Delete", role: .destructive) { commitDelete(message: message) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename thread",
            isPresented: Binding(
                get: { renamingNoteID != nil },
                set: { if !$0 { renamingNoteID = nil } }
            )
        ) {
            TextField("Title", text: $renameDraft)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Reject action?", isPresented: Binding(
            get: { rejectingAction != nil },
            set: { if !$0 { rejectingAction = nil } }
        )) {
            TextField("Reason (optional)", text: $rejectReason)
            Button("Reject", role: .destructive) {
                if let a = rejectingAction {
                    let reason = rejectReason.isEmpty ? nil : rejectReason
                    Task { await engine.rejectMissionAction(actionID: a.id, reason: reason) }
                }
                rejectingAction = nil
            }
            Button("Cancel", role: .cancel) { rejectingAction = nil }
        } message: {
            if let a = rejectingAction {
                Text("Tell the agent why you rejected \(a.toolName). This signal can help it adjust.")
            }
        }
    }

    private var activeNote: AddressNote? {
        guard let id = activeNoteID else { return nil }
        return notes.first(where: { $0.id == id })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.secondary)
            Text(addressLabel)
                .font(.system(.callout, design: .monospaced))
            if let editors = activeNote?.editors, !editors.isEmpty {
                AuthorAvatarStack(authors: editors, avatarSize: 18)
            }
            Spacer()
            if notes.count > 1 {
                Menu {
                    ForEach(notes) { note in
                        Button {
                            activeNoteID = note.id
                        } label: {
                            if note.id == activeNoteID {
                                Label(noteTitle(note), systemImage: "checkmark")
                            } else {
                                Text(noteTitle(note))
                            }
                        }
                    }
                } label: {
                    Label("Switch", systemImage: "chevron.up.chevron.down")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            Button {
                createNote()
            } label: {
                Image(systemName: "plus.bubble")
            }
            .buttonStyle(.borderless)
            .help("New thread")
            if let note = activeNote {
                Button {
                    renameDraft = noteTitle(note)
                    renamingNoteID = note.id
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename thread")
                Button(role: .destructive) {
                    pendingDeleteThread = note
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete thread")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var addressLabel: String {
        String(format: "0x%llx", address)
    }

    private func threadView(note: AddressNote) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                            if let placeholder = livePlaceholder {
                                ConversationMessageRow(message: placeholder, isEditing: false, editingDraft: .constant(""))
                                    .id(placeholder.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)

                        Color.clear
                            .frame(height: 12)
                            .id(Self.bottomAnchorID)
                    }
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: messages.count) { _, _ in
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: livePlaceholder?.bodyMarkdown) { _, _ in
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: editingMessageID) { _, newID in
                    guard let newID else { return }
                    withAnimation { proxy.scrollTo(newID, anchor: .bottom) }
                }
            }
            if !pendingActions.isEmpty {
                Divider()
                pendingApprovals
            }
            Divider()
            inputBar(note: note)
        }
    }

    private var pendingApprovals: some View {
        VStack(spacing: 8) {
            ForEach(pendingActions) { action in
                if action.toolName == MissionTools.requestUserInputToolName {
                    RequestUserInputCard(action: action) { answer in
                        engine.submitUserInputResponse(actionID: action.id, answer: answer)
                    }
                } else {
                    ActionCard(
                        engine: engine,
                        action: action,
                        onApprove: { Task { await engine.approveMissionAction(actionID: action.id) } },
                        onReject: {
                            rejectingAction = action
                            rejectReason = ""
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func messageRow(_ message: AddressNoteMessage) -> some View {
        let isEditing = editingMessageID == message.id
        return ConversationEditableMessage(
            isEditing: isEditing,
            editFocus: $editFocused,
            canEdit: message.role == .user,
            canDelete: message.role == .user,
            canSave: !editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onEdit: {
                editingDraft = message.bodyMarkdown
                editingMessageID = message.id
                DispatchQueue.main.async { editFocused = true }
            },
            onCancel: { editingMessageID = nil },
            onSave: { commitEdit(message: message) },
            onDelete: { pendingDeleteMessage = message }
        ) {
            ConversationMessageRow(message: message, isEditing: isEditing, editingDraft: $editingDraft)
        }
    }

    private static let bottomAnchorID = "address-note-bottom"

    private func inputBar(note: AddressNote) -> some View {
        ConversationInputBar(
            draft: $draft,
            isSending: isSending,
            failure: failure,
            focus: $inputFocused,
            secondary: ConversationInputAction(symbol: "square.and.pencil", help: "Save as user note") { saveNote(note: note) },
            primary: ConversationInputAction(symbol: "paperplane.fill", help: "Ask AI") { askAI(note: note) },
            onStop: cancelReply)
    }

    private var failure: String? {
        if case .error(let reason) = pending { return reason }
        return nil
    }

    private var isSending: Bool {
        if case .sending = pending { return true }
        return false
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No threads on this address yet.")
                .foregroundStyle(.secondary)
            Button("Start a thread") {
                createNote()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasActiveReply: Bool {
        engine.noteReplyProgress[sessionID]?.noteID == activeNoteID
    }

    private var livePlaceholder: AddressNoteMessage? {
        guard isSending, let noteID = activeNoteID else { return nil }
        let progress = engine.noteReplyProgress[sessionID]
        let text = progress?.noteID == noteID ? progress?.text ?? "" : ""
        return AddressNoteMessage(
            noteID: noteID,
            index: -1,
            role: .assistant,
            bodyMarkdown: text,
            modelID: LumaAppState.shared.missionDefaults.modelID
        )
    }

    private func refresh() {
        notes = engine.addressNotes(sessionID: sessionID)
            .filter { engine.resolveSync(sessionID: sessionID, anchor: $0.anchor) == address }
        if activeNoteID == nil {
            activeNoteID = notes.last?.id
        }
        reloadActiveNote()
    }

    private func reloadActiveNote() {
        reloadMessages()
        if hasActiveReply { pending = .sending }
    }

    private func observePendingActions() {
        applyPendingActions((try? engine.store.fetchAllPendingMissionActions()) ?? [])
        actionsObservation = engine.store.observeAllPendingMissionActions { rows in
            Task { @MainActor in applyPendingActions(rows) }
        }
    }

    private func applyPendingActions(_ rows: [MissionAction]) {
        pendingActions = rows.filter {
            $0.sessionID == sessionID && engine.isAmbientMission($0.missionID)
        }
    }

    private func reloadMessages() {
        guard let id = activeNoteID else { messages = []; return }
        messages = engine.addressNoteMessages(noteID: id)
    }

    private func createNote() {
        guard let note = engine.createAddressNote(sessionID: sessionID, address: address) else { return }
        notes.append(note)
        activeNoteID = note.id
        messages = []
        unusedTransientNoteIDs.insert(note.id)
        DispatchQueue.main.async { inputFocused = true }
    }

    private func commitDelete(note: AddressNote) {
        engine.deleteAddressNote(note)
        notes.removeAll { $0.id == note.id }
        unusedTransientNoteIDs.remove(note.id)
        activeNoteID = notes.last?.id
        reloadMessages()
        if notes.isEmpty {
            isPresented = false
        }
    }

    private func commitDelete(message: AddressNoteMessage) {
        engine.deleteAddressNoteMessage(message)
        messages.removeAll { $0.id == message.id }
    }

    private func commitRename() {
        guard let id = renamingNoteID,
            var note = notes.first(where: { $0.id == id })
        else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? nil : trimmed
        guard newTitle != note.title else { return }
        note.title = newTitle
        engine.updateAddressNote(note)
        notes = notes.map { $0.id == note.id ? note : $0 }
    }

    private func commitEdit(message: AddressNoteMessage) {
        let body = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body != message.bodyMarkdown,
            let updated = engine.editUserMessage(noteID: message.noteID, messageID: message.id, body: body)
        else {
            editingMessageID = nil
            return
        }
        messages = messages.map { $0.id == updated.id ? updated : $0 }
        editingMessageID = nil
    }

    private func saveNote(note: AddressNote) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
            let message = engine.appendUserMessage(noteID: note.id, body: body)
        else { return }
        messages.append(message)
        unusedTransientNoteIDs.remove(note.id)
        draft = ""
    }

    private func cancelReply() {
        Task { @MainActor in
            await engine.cancelAddressNoteReply(sessionID: sessionID)
        }
    }

    private func askAI(note: AddressNote) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard let userMessage = engine.appendUserMessage(noteID: note.id, body: body) else { return }
        messages.append(userMessage)
        unusedTransientNoteIDs.remove(note.id)
        draft = ""
        pending = .sending
        let defaults = LumaAppState.shared.missionDefaults
        Task { @MainActor in
            let reply = await engine.requestAIReply(
                noteID: note.id,
                providerID: defaults.providerID,
                modelID: defaults.modelID
            )
            reloadMessages()
            pending = reply == nil ? .error("Reply failed. Check provider settings.") : .idle
        }
    }

    private func discardUnusedTransientNotes() {
        for note in notes where engine.addressNoteMessages(noteID: note.id).isEmpty {
            engine.deleteAddressNote(note)
        }
        unusedTransientNoteIDs.removeAll()
    }

    private func noteTitle(_ note: AddressNote) -> String {
        note.title ?? "Thread from \(note.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
