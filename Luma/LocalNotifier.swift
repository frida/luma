#if os(macOS)
    import AppKit
    import LumaCore
    import UserNotifications

    /// Shows native local notifications for incoming collaboration events —
    /// a new member joining the lab, a new notebook entry, or a message in the project chat.
    /// Push notifications already cover offline users; this class closes the
    /// blind spot where the Mac app is still connected to the portal but not
    /// frontmost (backgrounded, hidden, or covered by other windows), so the
    /// server never routes a push to APNs.
    ///
    /// Notifications are suppressed while Luma is the active application (the
    /// user is already looking at the event live).
    @MainActor
    final class LocalNotifier {
        init() {}

        static func requestAuthorization() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        func notifyMemberAdded(_ member: LumaCore.CollaborationSession.Member, labID: String?) {
            let name = displayName(member.user)
            deliver(
                kind: "member-added",
                title: "\(name) joined",
                body: "",
                labID: labID
            )
        }

        func notifyChatMessage(_ message: ObjectChatMessage, in chatTitle: String, labID: String?) {
            let sender = message.role == .assistant ? "Assistant" : message.author?.name ?? "Someone"
            deliver(
                kind: "chat-message",
                title: "\(sender) in \(chatTitle)",
                body: message.bodyMarkdown,
                labID: labID
            )
        }

        func notifyActionAwaitingApproval(_ action: MissionAction, additionalPending: Int) {
            let body: String
            if additionalPending > 0 {
                body = "\(action.toolName) (+\(additionalPending) more pending)"
            } else {
                body = action.toolName
            }
            deliver(
                kind: "mission-action-pending",
                title: "Luma needs approval",
                body: body,
                labID: nil
            )
        }

        func notifyEntryAdded(_ entry: NotebookEntry, labID: String?) {
            let author = entry.author?.name ?? "Someone"
            let title = entry.title.isEmpty ? "(untitled)" : entry.title
            deliver(
                kind: "entry-added",
                title: "\(author) added an entry",
                body: title,
                labID: labID
            )
        }

        private func displayName(_ user: LumaCore.CollaborationSession.UserInfo) -> String {
            user.name.isEmpty ? "@\(user.id)" : user.name
        }

        private func deliver(kind: String, title: String, body: String, labID: String?) {
            if NSApplication.shared.isActive { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if !body.isEmpty {
                content.body = body
            }
            content.sound = .default
            let id = labID.map { "\(kind)-\($0)" } ?? kind
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
#endif
