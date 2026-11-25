import LumaCore
import SwiftUI

struct ObjectChatProblemNotice: View {
    let problem: ObjectChatProblem
    let chats: ObjectChats
    var namesChat = true

    var body: some View {
        ProblemNotice(text: text, onDismiss: { chats.dismiss(problem.id) }) {}
    }

    private var text: String {
        let what =
            switch problem.kind {
            case .refusedByLab: "The lab turned a change away: \(problem.reason)"
            case .notSaved: "A chat change could not be saved: \(problem.reason)"
            }
        guard namesChat, let chatID = problem.chatID, let chat = chats.chat(withID: chatID) else { return what }
        return "\(chats.displayTitle(of: chat)): \(what)"
    }
}
