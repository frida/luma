import SwiftUI

struct ConversationInputBar: View {
    @Binding var draft: String
    let isSending: Bool
    let failure: String?
    var focus: FocusState<Bool>.Binding
    var secondary: ConversationInputAction? = nil
    let primary: ConversationInputAction
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .center, spacing: 6) {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(conversationEditorBackground))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.secondary.opacity(0.3)))
                    .frame(height: 64)
                    .focused(focus)
                VStack(spacing: 0) {
                    if let secondary {
                        Button(action: secondary.run) {
                            Image(systemName: secondary.symbol)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.bordered)
                        .help(secondary.help)
                        .disabled(isSending || draft.isEmpty)
                        .accessibilityIdentifier("conversation.secondary")
                    }
                    Spacer(minLength: 0)
                    Button {
                        if isSending {
                            onStop()
                        } else {
                            primary.run()
                        }
                    } label: {
                        Group {
                            if isSending {
                                Image(systemName: "stop.fill")
                            } else {
                                Image(systemName: primary.symbol)
                            }
                        }
                        .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .help(isSending ? "Cancel reply" : primary.help)
                    .disabled(!isSending && draft.isEmpty)
                    .accessibilityIdentifier("conversation.send")
                }
                .frame(height: 64)
            }
        }
        .padding(10)
    }
}

struct ConversationInputAction {
    let symbol: String
    let help: String
    let run: () -> Void
}
