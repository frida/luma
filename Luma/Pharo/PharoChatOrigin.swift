import LumaCore
import SwiftUI
import SwiftyPharo

struct PharoChatOrigin: Sendable {
    let origin: ObjectChat.Origin
    let label: String
    let source: String?

    func reached() -> PharoChatOrigin {
        PharoChatOrigin(origin: origin, label: "an object reached from \(label)", source: source)
    }
}

extension EnvironmentValues {
    @Entry var engine: Engine?
    @Entry var pharoChatOrigin: PharoChatOrigin?
    @Entry var pharoColumn: PharoColumnPresence?
}

extension View {
    func pharoChatOrigin(at depth: Int, of path: PharoColumnPath) -> some View {
        modifier(PharoChatOriginAtDepth(depth: depth, path: path))
    }
}

private struct PharoChatOriginAtDepth: ViewModifier {
    let depth: Int
    let path: PharoColumnPath

    @Environment(\.engine) private var engine
    @Environment(\.pharoChatOrigin) private var host
    @State private var found: PharoChatOrigin?

    func body(content: Content) -> some View {
        content
            .environment(\.pharoChatOrigin, found ?? (depth == 0 ? host : host?.reached()))
            .task(id: path.objects.prefix(depth + 1).map(\.handle)) { await find() }
    }

    private func find() async {
        guard let chats = engine?.objectChats else { return }
        let objects = Array(path.objects.prefix(depth + 1))
        for opener in stride(from: depth, through: 0, by: -1) {
            if let location = try? await chats.location(of: objects[opener]) {
                let origin = origin(of: location.objectID, in: location.chatID, chats: chats)
                found = opener == depth ? origin : origin.reached()
                return
            }
        }
        found = nil
    }

    private func origin(of objectID: String, in chatID: UUID, chats: ObjectChats) -> PharoChatOrigin {
        let thread = chats.thread(of: chatID)
        let producer = thread.objects.first { $0.objectID == objectID }?.producedBy
        let call = thread.toolCalls.first { $0.id == producer }
        var source: String?
        if case .string(let code) = call?.args["code"] {
            source = code
        }
        let title = chats.displayTitle(of: chats.chat(withID: chatID)!)
        return PharoChatOrigin(origin: .chat(chatID: chatID, objectID: objectID), label: "\(objectID) in “\(title)”", source: source)
    }
}
