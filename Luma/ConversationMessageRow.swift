import LumaCore
import SwiftUI

#if canImport(AppKit)
let conversationEditorBackground = Color(nsColor: .textBackgroundColor)
#else
let conversationEditorBackground = Color(uiColor: .secondarySystemBackground)
#endif

struct ConversationMessageRow<Message: ConversationMessage, Content: View>: View {
    let message: Message
    let isMine: Bool
    let isEditing: Bool
    @Binding var editingDraft: String
    let content: Content

    init(message: Message, isMine: Bool, isEditing: Bool, editingDraft: Binding<String>, @ViewBuilder content: () -> Content) {
        self.message = message
        self.isMine = isMine
        self.isEditing = isEditing
        _editingDraft = editingDraft
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if message.speaker != .assistant, let author = message.author {
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
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(conversationEditorBackground))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.secondary.opacity(0.3)))
                    .frame(height: 120)
            } else {
                content
            }
        }
    }

    private var icon: String {
        switch message.speaker {
        case .user: return "person.crop.circle"
        case .assistant: return "sparkles"
        }
    }

    private var tint: Color {
        switch message.speaker {
        case .user: return .accentColor
        case .assistant: return .purple
        }
    }

    private var roleLabel: String {
        switch message.speaker {
        case .user: return isMine ? "You" : message.author?.name ?? "You"
        case .assistant:
            if let modelID = message.modelID, !modelID.isEmpty, modelID != "default" {
                return modelID
            }
            return "Assistant"
        }
    }
}

extension ConversationMessageRow where Content == ConversationBubble {
    init(message: Message, isMine: Bool, isEditing: Bool, editingDraft: Binding<String>) {
        self.init(message: message, isMine: isMine, isEditing: isEditing, editingDraft: editingDraft) {
            ConversationBubble(markdown: message.bodyMarkdown, speaker: message.speaker)
        }
    }
}

struct ConversationBubble: View {
    let markdown: String
    let speaker: ConversationSpeaker

    var body: some View {
        MarkdownView(markdown, as: .conversation)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var background: AnyShapeStyle {
        switch speaker {
        case .user: return AnyShapeStyle(.fill.tertiary)
        case .assistant: return AnyShapeStyle(.fill.secondary)
        }
    }
}

struct ConversationErrorCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .textSelection(.enabled)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ConversationEditableMessage<Row: View>: View {
    let isEditing: Bool
    var editFocus: FocusState<Bool>.Binding
    let canEdit: Bool
    let canDelete: Bool
    let canSave: Bool
    let onEdit: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let row: Row

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            row
                .focused(editFocus, equals: isEditing)
            if isEditing {
                HStack(spacing: 6) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                    Button("Save", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
            }
        }
        .contextMenu {
            if canEdit {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
            }
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
