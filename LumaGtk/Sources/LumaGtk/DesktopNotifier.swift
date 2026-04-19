import Foundation
import GIO
import Gtk
import LumaCore

/// Shows native desktop notifications for incoming collaboration events —
/// a new member joining the lab, a new notebook entry, or a chat message.
/// The matching coverage on macOS is provided by APNs via the system UI,
/// so this class only exists on the LumaGtk side.
///
/// Notifications are suppressed while this window is the active toplevel
/// (the user is already looking at the event live).
@MainActor
final class DesktopNotifier {
    private let app: Gtk.Application
    private weak var window: Gtk.Window?

    init(app: Gtk.Application, window: Gtk.Window) {
        self.app = app
        self.window = window
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
        let name = displayName(message.sender)
        deliver(
            kind: "chat-message",
            title: name,
            body: message.text,
            labID: labID,
        )
    }

    func notifyEntryAdded(_ entry: NotebookEntry, labID: String?) {
        let author = entry.author?.name ?? "Someone"
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
        if window?.isActive == true { return }
        let notification = Notification(title: title)
        if !body.isEmpty {
            body.withCString { notification.set(body: $0) }
        }
        let id = labID.map { "\(kind)-\($0)" } ?? kind
        id.withCString { app.sendNotification(id: $0, notification: notification) }
    }
}
