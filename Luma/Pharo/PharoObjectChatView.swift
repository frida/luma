import LumaCore
import SwiftUI
import SwiftyPharo

struct PharoObjectChatView: View {
    let engine: Engine
    let chatID: UUID
    let onSelect: (PharoObject) -> Void

    @State private var failure: String?
    @State private var isDeletingChat = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var subjectUnavailableReason: String?

    @Environment(\.pharoColumn) private var column

    var body: some View {
        if let chat {
            VStack(spacing: 0) {
                header(chat)
                Divider()
                PharoChatThreadView(engine: engine, chatID: chatID, onSelect: onSelect)
            }
            .confirmationDialog("Delete this chat?", isPresented: $isDeletingChat, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await deleteChat() } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename chat", isPresented: $isRenaming) {
                TextField("Title", text: $renameDraft)
                Button("Save") { rename() }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { discardWhenClosed() }
            .task(id: subjectCheck(chat)) { await checkSubject(of: chat) }
        } else if chats.wasDiscarded(chatID) || chats.wasDeletedHere(chatID) {
            Color.clear
                .onAppear { column?.close() }
        } else {
            ContentUnavailableView("This chat was deleted", systemImage: "bubble.left.and.text.bubble.right")
        }
    }

    private var chat: ObjectChat? {
        chats.chat(withID: chatID)
    }

    private var chats: ObjectChats {
        engine.objectChats
    }

    private func header(_ chat: ObjectChat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.secondary)
                Text(provenance(of: chat, at: chats.subject(of: chat)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !chat.editors.isEmpty {
                    AuthorAvatarStack(authors: chat.editors, avatarSize: 18)
                }
                Spacer()
                showSubjectButton(chats.subject(of: chat))
                if chats.canRename(chatID) {
                    Button {
                        renameDraft = chats.displayTitle(of: chat)
                        isRenaming = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Rename chat")
                }
                if chats.canDelete(chatID) {
                    Button(role: .destructive) {
                        isDeletingChat = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete chat")
                }
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func showSubjectButton(_ subject: ObjectChatSubjectPlace) -> some View {
        let unavailable = unavailableReason(of: subject)
        return Button {
            do {
                try engine.showSubject(subject)
            } catch {
                failure = error.localizedDescription
            }
        } label: {
            Image(systemName: "scope")
        }
        .buttonStyle(.borderless)
        .disabled(unavailable != nil)
        .help(unavailable ?? "Show Subject")
        .accessibilityLabel("Show Subject")
    }

    private func unavailableReason(of subject: ObjectChatSubjectPlace) -> String? {
        switch subject {
        case .instruction(let place):
            place.unavailableReason ?? subjectUnavailableReason
        case .project, .object:
            nil
        }
    }

    private func provenance(of chat: ObjectChat, at subject: ObjectChatSubjectPlace) -> String {
        switch (subject, chat.subject) {
        case (.instruction(let place), _):
            "An instruction in \(place.sessionName ?? "a session not in this project")"
        case (.object(_, let label), .object):
            "From \(label)"
        case (.project, _), (.object, _):
            "About the project"
        }
    }

    private func discardWhenClosed() {
        let chats = chats
        let chatID = chatID
        column?.whenClosed { Task { await chats.discard(chatID) } }
    }

    private func subjectCheck(_ chat: ObjectChat) -> String {
        guard case .instruction(let place) = chats.subject(of: chat) else { return "" }
        let address = place.address.map { String($0) } ?? ""
        return "\(address) \(place.presence) \(place.unavailableReason ?? "") \(chats.thread(of: chatID).messages.count)"
    }

    private func checkSubject(of chat: ObjectChat) async {
        guard case .instruction(let place) = chats.subject(of: chat) else { return }
        subjectUnavailableReason = await engine.disassemblyUnavailableReason(at: place)
    }

    private func deleteChat() async {
        do {
            try await chats.delete(chatID)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func rename() {
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        chats.rename(chatID, to: title)
    }
}

extension Engine {
    func showSubject(_ subject: ObjectChatSubjectPlace) throws {
        switch subject {
        case .project:
            setSidePanel(.collaboration)
        case .instruction(let place):
            let insight = try disassemblyInsight(at: place)
            DisassemblyJumpRequests.shared.request(place.address!, in: insight.id)
            selectedSidebarItem = .insight(place.sessionID, insight.id)
        case .object(let origin, _):
            showOrigin(origin)
        }
    }

    private func showOrigin(_ origin: ObjectChat.Origin) {
        switch origin {
        case .snippet:
            selectedSidebarItem = .pharo
        case .notebookEntry:
            selectedSidebarItem = .notebook
        case .instrumentView(let instanceID, _, let sessionID):
            selectedSidebarItem = .instrument(sessionID, instanceID)
        case .chat(let chatID, _):
            selectedSidebarItem = .chat(chatID)
        }
    }
}
