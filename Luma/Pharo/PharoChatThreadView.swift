import LumaCore
import SwiftUI
import SwiftyPharo

struct PharoChatThreadView: View {
    let engine: Engine
    let chatID: UUID
    let onSelect: (PharoObject) -> Void

    @State private var draft = ""
    @State private var failure: String?
    @State private var editingMessageID: UUID?
    @State private var editingDraft = ""
    @State private var pendingDeleteMessage: ObjectChatMessage?
    @State private var answerUnavailableReason: String?
    @State private var isSettingUpProvider = false
    @State private var providerSetups = 0

    @FocusState private var inputFocused: Bool
    @FocusState private var editFocused: Bool

    private static let bottomAnchorID = "object-chat-bottom"

    var body: some View {
        VStack(spacing: 0) {
            if chats.removedInLab.contains(chatID) {
                removedNotice
                Divider()
            }
            ForEach(chats.problems.filter { $0.chatID == chatID && $0.messageID == nil }) { problem in
                ObjectChatProblemNotice(problem: problem, chats: chats, namesChat: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            transcript
            Divider()
            if ObjectChatRunSetting.shared.runsWithoutAsking {
                runsWithoutAskingNotice
            }
            ConversationInputBar(
                draft: $draft,
                isSending: isSending,
                failure: failure,
                focus: $inputFocused,
                secondary: hasCompany ? askAction : postAction,
                primary: hasCompany ? postAction : askAction,
                onStop: { chats.cancel(chatID) }
            ) {
                ObjectChatModelPicker(engine: engine, chatID: chatID, onSetUp: { isSettingUpProvider = true })
                if let answerUnavailableReason {
                    Label(answerUnavailableReason, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Set Up…") { isSettingUpProvider = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .sheet(isPresented: $isSettingUpProvider) {
            ObjectChatProviderSetupSheet(engine: engine, chatID: chatID, onDone: { providerSetups += 1 })
        }
        .task(id: answerCheck) { answerUnavailableReason = await chats.answerUnavailableReason(in: chatID) }
        .onAppear { chats.markRead(chatID) }
        .onChange(of: thread.messages.count) { chats.markRead(chatID) }
        .confirmationDialog(
            "Delete message?",
            isPresented: Binding(
                get: { pendingDeleteMessage != nil },
                set: { if !$0 { pendingDeleteMessage = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteMessage
        ) { message in
            Button("Delete", role: .destructive) { delete(message) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var chats: ObjectChats {
        engine.objectChats
    }

    private var answerCheck: String {
        let choice = chats.modelChoice(in: chatID)
        return "\(choice.providerID) \(choice.modelID) \(providerSetups)"
    }

    private var thread: ObjectChats.Thread {
        chats.thread(of: chatID)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(thread.messages) { message in
                            row(message)
                                .id(message.id)
                        }
                        streamingReply
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
            .onChange(of: thread.messages.count) { _, _ in
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: thread.replyText) { _, _ in
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: thread.toolCalls.count) { _, _ in
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: editingMessageID) { _, newID in
                guard let newID else { return }
                withAnimation { proxy.scrollTo(newID, anchor: .bottom) }
            }
        }
    }

    private var removedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This chat was deleted in the lab. What you wrote here was not sent.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
            HStack {
                Button("Copy What I Wrote") { Platform.copyToClipboard(unsentText) }
                Button("Delete Here", role: .destructive) { Task { await deleteHere() } }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.yellow.opacity(0.12))
    }

    private var unsentText: String {
        thread.messages.filter { chats.unsent[$0.id] != nil }.map(\.bodyMarkdown).joined(separator: "\n\n")
    }

    private func deleteHere() async {
        do {
            try await chats.delete(chatID)
        } catch {
            failure = error.localizedDescription
        }
    }

    private var runsWithoutAskingNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.orange)
            Text("The assistant's expressions run without asking.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Ask First") { ObjectChatRunSetting.shared.runsWithoutAsking = false }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("chat.askFirst")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var isSending: Bool {
        thread.replyText != nil
    }

    private var hasCompany: Bool {
        guard engine.associatedLabID != nil else { return false }
        let members = engine.collaboration.members
        return members.isEmpty || members.contains { !engine.collaboration.isSelf($0.user.id) }
    }

    private var askAction: ConversationInputAction {
        ConversationInputAction(symbol: "sparkles", help: "Ask the Assistant", unavailableReason: answerUnavailableReason, run: ask)
    }

    private var postAction: ConversationInputAction {
        ConversationInputAction(
            symbol: "paperplane.fill",
            help: hasCompany ? "Send" : "Send without asking the assistant",
            run: post)
    }

    private func ask() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        failure = nil
        Task {
            do {
                try await chats.ask(text, in: chatID)
            } catch {
                if draft.isEmpty { draft = text }
                failure = error.localizedDescription
            }
        }
    }

    private func post() {
        do {
            try chats.post(draft.trimmingCharacters(in: .whitespacesAndNewlines), in: chatID)
            draft = ""
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func delete(_ message: ObjectChatMessage) {
        do {
            try chats.remove(message.id, in: chatID)
        } catch {
            failure = error.localizedDescription
        }
    }

    @ViewBuilder
    private func row(_ message: ObjectChatMessage) -> some View {
        switch message.role {
        case .user:
            editableRow(message)
        case .assistant:
            answer(message, calls: calls(of: message.id))
        }
    }

    @ViewBuilder
    private var streamingReply: some View {
        if let text = thread.replyText {
            let answered = Set(thread.messages.map(\.id))
            answer(
                ObjectChatMessage(
                    chatID: chatID,
                    index: -1,
                    role: .assistant,
                    author: nil,
                    bodyMarkdown: text,
                    modelID: chats.modelChoice(in: chatID).modelID),
                calls: thread.toolCalls.filter { !answered.contains($0.messageID) })
        }
    }

    private func editableRow(_ message: ObjectChatMessage) -> some View {
        let isEditing = editingMessageID == message.id
        return ConversationEditableMessage(
            isEditing: isEditing,
            editFocus: $editFocused,
            canEdit: chats.canEdit(message),
            canDelete: chats.canRemove(message),
            canSave: !editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onEdit: {
                editingDraft = message.bodyMarkdown
                editingMessageID = message.id
                DispatchQueue.main.async { editFocused = true }
            },
            onCancel: { editingMessageID = nil },
            onSave: { commitEdit(message) },
            onDelete: { pendingDeleteMessage = message }
        ) {
            if let reason = chats.unsent[message.id] {
                VStack(alignment: .trailing, spacing: 4) {
                    ConversationMessageRow(
                        message: message, isMine: chats.isMine(message), isEditing: isEditing, editingDraft: $editingDraft)
                        .opacity(0.55)
                    unsentNotice(for: message, reason: reason)
                }
            } else {
                ConversationMessageRow(message: message, isMine: chats.isMine(message), isEditing: isEditing, editingDraft: $editingDraft)
            }
        }
    }

    private func unsentNotice(for message: ObjectChatMessage, reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text("Not sent: \(reason)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if !chats.removedInLab.contains(chatID) {
                Button("Send Again") { chats.resend(message.id, in: chatID) }
                    .accessibilityIdentifier("chat.message.resend")
            }
            if chats.canRemove(message) {
                Button("Delete", role: .destructive) { pendingDeleteMessage = message }
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    private func answer(_ message: ObjectChatMessage, calls: [ObjectChatToolCall]) -> some View {
        ConversationMessageRow(message: message, isMine: chats.isMine(message), isEditing: false, editingDraft: .constant("")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(PharoChatSegment.split(message.bodyMarkdown, around: calls)) { segment in
                    switch segment {
                    case .text(let text, _):
                        ConversationBubble(markdown: text, speaker: .assistant)
                    case .call(let call):
                        PharoChatToolCallCard(call: call, engine: engine, onSelect: onSelect)
                    }
                }
                if let error = message.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let reason = chats.unsent[message.id] {
                    unsentNotice(for: message, reason: reason)
                }
            }
        }
    }

    private func calls(of messageID: UUID) -> [ObjectChatToolCall] {
        thread.toolCalls.filter { $0.messageID == messageID }
    }

    private func commitEdit(_ message: ObjectChatMessage) {
        let body = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingMessageID = nil
        guard !body.isEmpty, body != message.bodyMarkdown else { return }
        do {
            try chats.edit(message.id, in: chatID, to: body)
        } catch {
            failure = error.localizedDescription
        }
    }
}

private enum PharoChatSegment: Identifiable {
    case text(String, at: Int)
    case call(ObjectChatToolCall)

    var id: String {
        switch self {
        case .text(_, let offset): "text-\(offset)"
        case .call(let call): call.id.uuidString
        }
    }

    static func split(_ text: String, around calls: [ObjectChatToolCall]) -> [PharoChatSegment] {
        var segments: [PharoChatSegment] = []
        var cursor = 0
        for call in calls.sorted(by: { ($0.offset, $0.index) < ($1.offset, $1.index) }) {
            let end = min(call.offset, text.count)
            segments += piece(of: text, from: cursor, to: end)
            cursor = max(cursor, end)
            segments.append(.call(call))
        }
        segments += piece(of: text, from: cursor, to: text.count)
        return segments.isEmpty ? [.text("", at: 0)] : segments
    }

    private static func piece(of text: String, from start: Int, to end: Int) -> [PharoChatSegment] {
        guard end > start else { return [] }
        let piece = String(text.dropFirst(start).prefix(end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
        return piece.isEmpty ? [] : [.text(piece, at: start)]
    }
}
