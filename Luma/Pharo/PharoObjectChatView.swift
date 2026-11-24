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
        } else {
            ContentUnavailableView("This chat was deleted", systemImage: "bubble.left.and.text.bubble.right")
        }
    }

    private var chat: ObjectChat? {
        chats.chats.first { $0.id == chatID }
    }

    private var chats: ObjectChats {
        engine.objectChats
    }

    private func header(_ chat: ObjectChat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.secondary)
                Text(chats.displayTitle(of: chat))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !chat.editors.isEmpty {
                    AuthorAvatarStack(authors: chat.editors, avatarSize: 18)
                }
                Spacer()
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
            Text(about(chat))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func about(_ chat: ObjectChat) -> String {
        switch chat.subject {
        case .project:
            "About the project"
        case .instruction(_, let anchor):
            "About the instruction at \(anchor.displayString)"
        case .object(_, let label, _, _, let printString, _):
            "About \(printString), from \(label)"
        }
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
