import Foundation
import LumaCore

protocol ConversationMessage: Identifiable {
    var speaker: ConversationSpeaker { get }
    var author: Author? { get }
    var bodyMarkdown: String { get }
    var modelID: String? { get }
    var createdAt: Date { get }
}

enum ConversationSpeaker {
    case user
    case assistant
}

extension ObjectChatMessage: ConversationMessage {
    var speaker: ConversationSpeaker {
        switch role {
        case .user: .user
        case .assistant: .assistant
        }
    }
}
