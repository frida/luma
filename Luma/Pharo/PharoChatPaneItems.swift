import LumaCore
import SwiftUI
import SwiftyPharo

@MainActor
struct PharoChatPaneItems {
    let object: PharoObject
    let chats: ObjectChats
    let origin: PharoChatOrigin?
    let errorPresenter: ErrorPresenter
    let onSelect: (PharoObject) -> Void

    private static let recentCount = 8

    var items: [PharoPaneMenuItem] {
        var items: [PharoPaneMenuItem] = []
        if let origin {
            items.append(
                PharoPaneMenuItem(title: "Chat about this object", symbol: "bubble.left.and.text.bubble.right") { start(from: origin) })
        }
        let additions = recentChats.flatMap(additions(to:))
        if !additions.isEmpty {
            items.append(PharoPaneMenuItem(title: "Add to Chat", symbol: "plus.bubble", children: additions))
        }
        return items
    }

    private func start(from origin: PharoChatOrigin) {
        Task {
            do {
                let started = try await chats.start(about: object, from: origin.origin, label: origin.label, source: origin.source)
                onSelect(started.column)
            } catch {
                errorPresenter.present("Can’t start a chat", error.localizedDescription)
            }
        }
    }

    private var recentChats: [ObjectChat] {
        Array(chats.chats.sorted { lastActivity(of: $0) > lastActivity(of: $1) }.prefix(Self.recentCount))
    }

    private func lastActivity(of chat: ObjectChat) -> Date {
        chats.thread(of: chat.id).messages.last?.createdAt ?? chat.createdAt
    }

    private func additions(to chat: ObjectChat) -> [PharoPaneMenuItem] {
        let title = chats.displayTitle(of: chat)
        var additions = [PharoPaneMenuItem(title: title, symbol: "plus") { add(to: chat, inPlaceOf: nil) }]
        if chats.thread(of: chat.id).objects.first(where: { $0.objectID == "o1" })?.className == object.className {
            additions.append(
                PharoPaneMenuItem(title: "\(title), in place of self", symbol: "arrow.triangle.swap") { add(to: chat, inPlaceOf: "o1") })
        }
        return additions
    }

    private func add(to chat: ObjectChat, inPlaceOf standsFor: String?) {
        Task {
            do {
                _ = try await chats.add(object, to: chat.id, named: nil, inPlaceOf: standsFor)
            } catch {
                errorPresenter.present("Can’t add to the chat", error.localizedDescription)
            }
        }
    }
}
