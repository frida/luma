import Foundation
import LumaCore

struct PharoChatOrigin {
    let origin: ObjectChat.Origin
    let label: String
    let source: String?

    func reached() -> PharoChatOrigin {
        PharoChatOrigin(origin: origin, label: "an object reached from \(label)", source: source)
    }

    @MainActor
    static func of(_ objectID: String, in chatID: UUID, chats: ObjectChats) -> PharoChatOrigin {
        let thread = chats.thread(of: chatID)
        let producer = thread.objects.first { $0.objectID == objectID }?.producedBy
        let call = thread.toolCalls.first { $0.id == producer }
        var source: String?
        if case .string(let code) = call?.args["code"] {
            source = code
        }
        let title = chats.chats.first { $0.id == chatID }.map(chats.displayTitle(of:)) ?? ""
        return PharoChatOrigin(origin: .chat(chatID: chatID, objectID: objectID), label: "\(objectID) in “\(title)”", source: source)
    }
}
