import Gtk
import LumaCore

@MainActor
enum PharoChatObjectID {
    static func make(_ objectID: String, collaboration: CollaborationSession, classes: [String]) -> Box {
        let parts = objectID.split(separator: ".", maxSplits: 1)
        let box = Box(orientation: .horizontal, spacing: 3)
        box.append(child: label(String(parts[0]), classes: classes))
        guard parts.count > 1, !collaboration.isSelf(String(parts[1])) else { return box }
        let maker = String(parts[1])
        if let user = collaboration.members.first(where: { $0.user.id == maker })?.user {
            let avatar = AuthorAvatarStack.picture(
                of: Author(id: user.id, name: user.name, avatarURL: user.avatarURL?.absoluteString ?? ""), size: 12)
            avatar.valign = .center
            avatar.tooltipText = "Made in \(user.name)'s Luma"
            box.append(child: avatar)
        } else {
            let quiet = label("@\(maker)", classes: ["caption", "dim-label"])
            quiet.tooltipText = "Made in @\(maker)'s Luma"
            box.append(child: quiet)
        }
        return box
    }

    private static func label(_ text: String, classes: [String]) -> Label {
        let label = Label(str: text)
        for cssClass in classes {
            label.add(cssClass: cssClass)
        }
        return label
    }
}
