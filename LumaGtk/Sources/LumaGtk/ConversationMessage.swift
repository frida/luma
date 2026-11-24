import Foundation
import LumaCore

protocol ConversationMessage {
    var id: UUID { get }
    var speaker: ConversationSpeaker { get }
    var author: Author? { get }
    var bodyMarkdown: String { get }
    var modelID: String? { get }
    var createdAt: Date { get }
}

enum ConversationSpeaker {
    case user
    case assistant
    case system
}

extension AddressNoteMessage: ConversationMessage {
    var speaker: ConversationSpeaker {
        switch role {
        case .user: .user
        case .assistant: .assistant
        case .system: .system
        }
    }
}

extension ObjectChatMessage: ConversationMessage {
    var speaker: ConversationSpeaker {
        switch role {
        case .user: .user
        case .assistant: .assistant
        }
    }
}
