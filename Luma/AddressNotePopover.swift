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
        .onAppear(perform: refresh)
        .onChange(of: activeNoteID) { _, _ in reloadMessages() }
        .onDisappear(perform: discardUnusedTransientNotes)
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
                Button(role: .destructive) {
                    delete(note: note)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                    }
                }
                .padding(12)
            }
            Divider()
            inputBar(note: note)
        }
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

    private func inputBar(note: AddressNote) -> some View {
        VStack(spacing: 6) {
            if case .error(let reason) = pending {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Write a note or ask…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if let note = activeNote, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSending {
                            askAI(note: note)
                        }
                        return .handled
                    }
                Button {
                    saveNote(note: note)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("Save as user note")
                .disabled(isSending || draft.isEmpty)
                Button {
                    askAI(note: note)
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .help("Ask AI")
                .disabled(isSending || draft.isEmpty)
            }
        }
        .padding(10)
    }

    private var isSending: Bool {
        if case .sending = pending { return true }
        return false
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
    }

    private func delete(note: AddressNote) {
        engine.deleteAddressNote(note)
        notes.removeAll { $0.id == note.id }
        unusedTransientNoteIDs.remove(note.id)
        activeNoteID = notes.first?.id
        reloadMessages()
        if notes.isEmpty {
            isPresented = false
        }
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
        Task { @MainActor in
            let reply = await engine.requestAIReply(
                noteID: note.id,
                providerID: defaults.providerID,
                modelID: defaults.modelID
            )
            if let reply {
                messages.append(reply)
                pending = .idle
            } else {
                pending = .error("Reply failed. Check provider settings.")
            }
        }
    }

    private func discardUnusedTransientNotes() {
        for noteID in unusedTransientNoteIDs {
            guard let note = notes.first(where: { $0.id == noteID }) else { continue }
            guard engine.addressNoteMessages(noteID: noteID).isEmpty else { continue }
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
            Text(message.bodyMarkdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        case .assistant: return message.modelID ?? "Assistant"
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
