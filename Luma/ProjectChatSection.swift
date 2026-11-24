import LumaCore
import SwiftUI
import SwiftyPharo

struct ProjectChatSection: View {
    let engine: Engine

    @State private var inspected: PharoObject?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project Chat")
                .font(.subheadline).bold()
            if engine.objectChats.conversation != nil {
                PharoChatThreadView(engine: engine, chatID: engine.objectChats.conversationID, onSelect: { inspected = $0 })
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .onAppear { _ = engine.objectChats.openConversation() }
        .sheet(isPresented: Binding(get: { inspected != nil }, set: { if !$0 { inspected = nil } })) {
            if let inspected {
                PharoInspectorSheet(engine: engine, first: { inspected }, onDone: { self.inspected = nil })
            }
        }
    }
}
