import Adw
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
struct PharoChatPaneItems {
    let object: PharoObject
    let chats: ObjectChats
    let origin: PharoChatOrigin?
    let alertParent: Widget
    let onSelect: (PharoObject) -> Void

    private static let recentCount = 8

    var items: [ContextMenu.Item] {
        var items: [ContextMenu.Item] = []
        if let origin {
            items.append(ContextMenu.Item("Chat about this object") { start(from: origin) })
        }
        let additions = recentChats.flatMap(additions(to:))
        if !additions.isEmpty {
            items.append(ContextMenu.Item("Add to Chat", children: additions))
        }
        return items
    }

    private func start(from origin: PharoChatOrigin) {
        Task { @MainActor in
            do {
                let started = try await chats.start(about: object, from: origin.origin, label: origin.label, source: origin.source)
                onSelect(started.column)
            } catch {
                present("Can’t start a chat", error.localizedDescription)
            }
        }
    }

    private func present(_ heading: String, _ message: String) {
        let alert = Adw.AlertDialog(heading: heading, body: message)
        alert.addResponse(id: "ok", label: "OK")
        alert.setDefault(response: "ok")
        alert.setClose(response: "ok")
        alert.present(parent: alertParent)
    }

    private var recentChats: [ObjectChat] {
        Array(chats.chats.sorted { lastActivity(of: $0) > lastActivity(of: $1) }.prefix(Self.recentCount))
    }

    private func lastActivity(of chat: ObjectChat) -> Date {
        chats.thread(of: chat.id).messages.last?.createdAt ?? chat.createdAt
    }

    private func additions(to chat: ObjectChat) -> [ContextMenu.Item] {
        let title = chats.displayTitle(of: chat)
        var additions = [ContextMenu.Item(title) { add(to: chat, inPlaceOf: nil) }]
        if chats.thread(of: chat.id).objects.first(where: { $0.objectID == "o1" })?.className == object.className {
            additions.append(ContextMenu.Item("\(title), in place of self") { add(to: chat, inPlaceOf: "o1") })
        }
        return additions
    }

    private func add(to chat: ObjectChat, inPlaceOf standsFor: String?) {
        Task { @MainActor in
            do {
                _ = try await chats.add(object, to: chat.id, named: nil, inPlaceOf: standsFor)
            } catch {
                present("Can’t add to the chat", error.localizedDescription)
            }
        }
    }
}
