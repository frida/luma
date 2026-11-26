import Gtk
import LumaCore

@MainActor
enum ObjectChatProblemNotice {
    static func make(_ problem: LabProblem, engine: Engine, onShow: @escaping (LabSubject) -> Void) -> Box {
        let dismiss = { engine.dismiss(problem) }
        switch problem.concern {
        case .objectChat(let chatProblem):
            return make(chatProblem, chats: engine.objectChats, namesChat: true)
        case .missionDeletedInLab, .keptFromLab:
            return notice(problem.reason, onDismiss: dismiss)
        case .missionStoppedByOwner(let missionID, _):
            guard engine.missions.contains(where: { $0.id == missionID }) else { return notice(problem.reason, onDismiss: dismiss) }
            return notice(problem.reason, actions: [("Show", { onShow(LabSubject(.mission, missionID)) })], onDismiss: dismiss)
        case .copyKeptFromLab(let subject, _):
            guard engine.subjectsKeptFromLab.contains(subject) else { return notice(problem.reason, onDismiss: dismiss) }
            let show: [(String, () -> Void)] = engine.canShow(subject) ? [("Show", { onShow(subject) })] : []
            return notice(problem.reason, actions: show + [("Add to Lab", { engine.addToLab(subject) })], onDismiss: dismiss)
        }
    }

    static func make(_ problem: ObjectChatProblem, chats: ObjectChats, namesChat: Bool) -> Box {
        notice(description(of: problem, chats: chats, namesChat: namesChat)) { chats.dismiss(problem.id) }
    }

    private static func notice(
        _ description: String, actions: [(String, () -> Void)] = [], onDismiss: @escaping () -> Void
    ) -> Box {
        let notice = Box(orientation: .horizontal, spacing: 6)

        let icon = Gtk.Image(iconName: "dialog-warning-symbolic")
        icon.add(cssClass: "warning")
        icon.valign = .start
        notice.append(child: icon)

        let text = Label(str: description)
        text.add(cssClass: "caption")
        text.selectable = true
        text.wrap = true
        text.xalign = 0
        text.hexpand = true
        if actions.isEmpty {
            notice.append(child: text)
        } else {
            let column = Box(orientation: .vertical, spacing: 4)
            column.hexpand = true
            column.append(child: text)
            let buttons = Box(orientation: .horizontal, spacing: 12)
            for (label, action) in actions {
                let button = Button(label: label)
                button.add(cssClass: "flat")
                button.add(cssClass: "caption")
                button.onClicked { _ in
                    MainActor.assumeIsolated { action() }
                }
                buttons.append(child: button)
            }
            column.append(child: buttons)
            notice.append(child: column)
        }

        let dismiss = Button(iconName: "window-close-symbolic")
        dismiss.add(cssClass: "flat")
        dismiss.valign = .start
        dismiss.tooltipText = "Dismiss"
        dismiss.onClicked { _ in
            MainActor.assumeIsolated { onDismiss() }
        }
        notice.append(child: dismiss)
        return notice
    }

    private static func description(of problem: ObjectChatProblem, chats: ObjectChats, namesChat: Bool) -> String {
        let what =
            switch problem.kind {
            case .refusedByLab: "The lab turned a change away: \(problem.reason)"
            case .notSaved: "A chat change could not be saved: \(problem.reason)"
            }
        guard namesChat, let chat = chats.chats.first(where: { $0.id == problem.chatID }) else { return what }
        return "\(chats.displayTitle(of: chat)): \(what)"
    }
}
