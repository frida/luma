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
    @State private var streamingPlaceholder: AddressNoteMessage?
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
            DispatchQueue.main.async { inputFocused = true }
        }
        .onChange(of: activeNoteID) { _, _ in reloadMessages() }
        .onDisappear(perform: discardUnusedTransientNotes)
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
                            Text(noteTitle(note))
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
                            if let placeholder = streamingPlaceholder {
                                MessageRow(message: placeholder, isEditing: false, editingDraft: .constant(""))
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
                .onChange(of: streamingPlaceholder?.bodyMarkdown) { _, _ in
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: editingMessageID) { _, newID in
                    guard let newID else { return }
                    withAnimation { proxy.scrollTo(newID, anchor: .bottom) }
                }
            }
            Divider()
            inputBar(note: note)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: AddressNoteMessage) -> some View {
        let isEditing = editingMessageID == message.id
        VStack(alignment: .trailing, spacing: 4) {
            MessageRow(message: message, isEditing: isEditing, editingDraft: $editingDraft)
                .focused($editFocused, equals: isEditing)
            if isEditing {
                HStack(spacing: 6) {
                    Button("Cancel") { editingMessageID = nil }
                        .buttonStyle(.bordered)
                    Button("Save") { commitEdit(message: message) }
                        .buttonStyle(.borderedProminent)
                        .disabled(editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
            .contextMenu {
                if message.role == .user {
                    Button {
                        editingDraft = message.bodyMarkdown
                        editingMessageID = message.id
                        DispatchQueue.main.async { editFocused = true }
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDeleteMessage = message
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
    }

    private static let bottomAnchorID = "address-note-bottom"

    private func inputBar(note: AddressNote) -> some View {
        VStack(spacing: 6) {
            if case .error(let reason) = pending {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .center, spacing: 6) {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.secondary.opacity(0.3)))
                    .frame(height: 64)
                    .focused($inputFocused)
                VStack(spacing: 0) {
                    Button {
                        saveNote(note: note)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .help("Save as user note")
                    .disabled(isSending || draft.isEmpty)
                    Spacer(minLength: 0)
                    Button {
                        askAI(note: note)
                    } label: {
                        Group {
                            if isSending {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                        }
                        .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Ask AI")
                    .disabled(isSending || draft.isEmpty)
                }
                .frame(height: 64)
            }
        }
        .padding(10)
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

    private func refresh() {
        notes = engine.addressNotes(sessionID: sessionID)
            .filter { (try? engine.node(forSessionID: sessionID)?.resolveSyncIfReady($0.anchor)) == address }
        if activeNoteID == nil {
            activeNoteID = notes.first?.id
        }
        reloadMessages()
    }

    private func reloadMessages() {
        guard let id = activeNoteID else { messages = []; return }
        messages = engine.addressNoteMessages(noteID: id)
    }

    private func createNote() {
        guard let note = engine.createAddressNote(sessionID: sessionID, address: address) else { return }
        notes.insert(note, at: 0)
        activeNoteID = note.id
        messages = []
        unusedTransientNoteIDs.insert(note.id)
        DispatchQueue.main.async { inputFocused = true }
    }

    private func commitDelete(note: AddressNote) {
        engine.deleteAddressNote(note)
        notes.removeAll { $0.id == note.id }
        unusedTransientNoteIDs.remove(note.id)
        activeNoteID = notes.first?.id
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

    private func askAI(note: AddressNote) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard let userMessage = engine.appendUserMessage(noteID: note.id, body: body) else { return }
        messages.append(userMessage)
        unusedTransientNoteIDs.remove(note.id)
        draft = ""
        pending = .sending
        let defaults = LumaAppState.shared.missionDefaults
        streamingPlaceholder = AddressNoteMessage(
            noteID: note.id,
            index: -1,
            role: .assistant,
            bodyMarkdown: "",
            modelID: defaults.modelID
        )
        Task { @MainActor in
            let reply = await engine.requestAIReply(
                noteID: note.id,
                providerID: defaults.providerID,
                modelID: defaults.modelID,
                onDelta: { delta in
                    if var placeholder = streamingPlaceholder {
                        placeholder.bodyMarkdown += delta
                        streamingPlaceholder = placeholder
                    }
                }
            )
            streamingPlaceholder = nil
            if let reply {
                messages.append(reply)
                pending = .idle
            } else {
                pending = .error("Reply failed. Check provider settings.")
            }
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

private struct MessageRow: View {
    let message: AddressNoteMessage
    let isEditing: Bool
    @Binding var editingDraft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let author = message.author {
                    AuthorAvatar(author: author, size: 16)
                } else {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                }
                Text(roleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if isEditing {
                TextEditor(text: $editingDraft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.secondary.opacity(0.3)))
                    .frame(height: 120)
            } else {
                Text(message.bodyMarkdown)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var icon: String {
        switch message.role {
        case .user: return "person.crop.circle"
        case .assistant: return "sparkles"
        case .system: return "gearshape"
        }
    }

    private var tint: Color {
        switch message.role {
        case .user: return .accentColor
        case .assistant: return .purple
        case .system: return .secondary
        }
    }

    private var roleLabel: String {
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

    private var background: AnyShapeStyle {
        switch message.role {
        case .user: return AnyShapeStyle(.quaternary)
        case .assistant: return AnyShapeStyle(.tertiary)
        case .system: return AnyShapeStyle(.quinary)
        }
    }
}
