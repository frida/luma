import Foundation
import GIO
import Gtk
import LumaCore

/// Shows native desktop notifications for incoming collaboration events —
/// a new member joining the lab, a new notebook entry, or a chat message.
/// The matching coverage on macOS is provided by APNs via the system UI,
/// so this class only exists on the LumaGtk side.
@MainActor
final class DesktopNotifier {
    private let app: Gtk.Application

    init(app: Gtk.Application) {
        self.app = app
    }

    func notifyMemberAdded(_ member: LumaCore.CollaborationSession.Member, labID: String?) {
        let name = displayName(member.user)
        deliver(
            kind: "member-added",
            title: "\(name) joined",
            body: "",
            labID: labID,
        )
    }

    func notifyChatMessage(_ message: LumaCore.CollaborationSession.ChatMessage, labID: String?) {
        guard !message.isLocal else { return }
        let name = displayName(message.sender)
        deliver(
            kind: "chat-message",
            title: name,
            body: message.text,
            labID: labID,
        )
    }

    func notifyEntryAdded(_ entry: NotebookEntry, labID: String?) {
        let author: String
        if let a = entry.author {
            author = a.name
        } else {
            author = "Someone"
        }
        let title = entry.title.isEmpty ? "(untitled)" : entry.title
        deliver(
            kind: "entry-added",
            title: "\(author) added an entry",
            body: title,
            labID: labID,
        )
    }

    private func displayName(_ user: LumaCore.CollaborationSession.UserInfo) -> String {
        user.name.isEmpty ? "@\(user.id)" : user.name
    }

    private func deliver(kind: String, title: String, body: String, labID: String?) {
        let notification = Notification(title: title)
        if !body.isEmpty {
            body.withCString { notification.set(body: $0) }
        }
        let id = labID.map { "\(kind)-\($0)" } ?? kind
        id.withCString { app.sendNotification(id: $0, notification: notification) }
    }
}
