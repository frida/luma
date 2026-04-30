import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class SessionCollaborationHeader {
    let widget: Box

    private weak var engine: LumaCore.Engine?
    private let sessionID: UUID
    private let onClaimDriver: () -> Void
    private let onRehost: () -> Void

    init(
        engine: LumaCore.Engine,
        sessionID: UUID,
        onClaimDriver: @escaping () -> Void,
        onRehost: @escaping () -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.onClaimDriver = onClaimDriver
        self.onRehost = onRehost

        widget = Box(orientation: .horizontal, spacing: 8)
        widget.add(cssClass: "luma-session-collab-header")
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 6
        widget.marginBottom = 6

        applySessionState()
    }

    func applySessionState() {
        var child = widget.firstChild
        while let current = child {
            child = current.nextSibling
            widget.remove(child: current)
        }

        guard let engine else {
            widget.visible = false
            return
        }

        let host: LumaCore.CollaborationSession.UserInfo? = {
            guard let session = engine.sessions.first(where: { $0.id == sessionID }),
                  let host = session.host,
                  host.id != engine.collaboration.localUser?.id
            else { return nil }
            return host
        }()
        let driver: LumaCore.CollaborationSession.UserInfo? =
            engine.localUserIsDriver(ofSessionID: sessionID) ? nil : engine.driver(forSessionID: sessionID)

        guard host != nil || driver != nil else {
            widget.visible = false
            return
        }

        if let host {
            widget.append(child: makeChip(prefix: "Hosted by", user: host))
        }

        if host != nil, driver != nil {
            let dot = Label(str: "·")
            dot.add(cssClass: "dim-label")
            widget.append(child: dot)
        }

        if let driver {
            widget.append(child: makeChip(prefix: "Driving:", user: driver))
        }

        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        widget.append(child: spacer)

        if host != nil, engine.collaboration.isOwner {
            let button = Button(label: "Run on My Device\u{2026}")
            button.add(cssClass: "flat")
            button.onClicked { [onRehost] _ in
                MainActor.assumeIsolated { onRehost() }
            }
            widget.append(child: button)
        }

        if driver != nil, engine.collaboration.isOwner {
            let button = Button(label: "Take the wheel")
            button.add(cssClass: "flat")
            button.onClicked { [onClaimDriver] _ in
                MainActor.assumeIsolated { onClaimDriver() }
            }
            widget.append(child: button)
        }

        widget.visible = true
    }

    private func makeChip(prefix: String, user: LumaCore.CollaborationSession.UserInfo) -> Widget {
        let chip = Box(orientation: .horizontal, spacing: 6)
        chip.append(child: makeAvatar(user: user, size: 18))

        let displayName = user.name.isEmpty ? "@\(user.id)" : "@\(user.id)"
        let label = Label(str: "\(prefix) \(displayName)")
        label.add(cssClass: "caption")
        label.add(cssClass: "dim-label")
        chip.append(child: label)
        return chip
    }

    private func makeAvatar(user: LumaCore.CollaborationSession.UserInfo, size: Int) -> Widget {
        let displayName = user.name.isEmpty ? "@\(user.id)" : user.name
        let avatar = Adw.Avatar(size: size, text: displayName, showInitials: true)
        avatar.tooltipText = displayName
        if let url = user.avatarURL.flatMap({ URL(string: "\($0.absoluteString)&s=\(size * 2)") }) {
            Task { @MainActor [avatar] in
                guard let texture = await AvatarCache.shared.texture(for: url) else { return }
                avatar.set(customImage: texture)
            }
        }
        return avatar
    }
}
