import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class SessionRowIndicators {
    enum Detachment: Equatable {
        case reestablishing(label: String)
        case detached(label: String, tint: Tint)
    }

    enum Tint: String {
        case warning
        case error
    }

    let widget: Box
    var onReestablish: () -> Void = {}

    private let hostAvatar: Adw.Avatar
    private let spinner: Spinner
    private let reestablishButton: Button
    private let reestablishIcon: Gtk.Image
    private var hostID: String?

    private static let avatarSize = 18

    init() {
        widget = Box(orientation: .horizontal, spacing: 0)
        widget.valign = .center

        hostAvatar = Adw.Avatar(size: Self.avatarSize, text: nil, showInitials: true)
        hostAvatar.visible = false
        widget.append(child: hostAvatar)

        spinner = makeSpinner()
        spinner.visible = false
        widget.append(child: spinner)

        reestablishIcon = Gtk.Image(iconName: "view-refresh-symbolic")
        reestablishIcon.pixelSize = 14
        reestablishButton = Button()
        reestablishButton.set(child: reestablishIcon)
        reestablishButton.add(cssClass: "flat")
        reestablishButton.add(cssClass: "luma-sidebar-detached")
        reestablishButton.valign = .center
        reestablishButton.visible = false
        reestablishButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.onReestablish() }
        }
        widget.append(child: reestablishButton)
    }

    func show(remoteHost host: CollaborationSession.UserInfo?, deviceName: String) {
        hostAvatar.visible = host != nil
        guard let host else {
            hostID = nil
            return
        }
        hostAvatar.tooltipText = "Hosted by @\(host.id) on \(deviceName)"
        guard host.id != hostID else { return }
        hostID = host.id
        hostAvatar.text = host.name.isEmpty ? "@\(host.id)" : host.name
        hostAvatar.set(customImage: nil)
        loadAvatarImage(of: host)
    }

    func show(_ detachment: Detachment?) {
        switch detachment {
        case nil:
            spinner.visible = false
            reestablishButton.visible = false
        case .reestablishing(let label):
            spinner.tooltipText = "\(label)ing\u{2026}"
            spinner.visible = true
            reestablishButton.visible = false
        case .detached(let label, let tint):
            reestablishButton.tooltipText = "\(label)\u{2026}"
            reestablishIcon.remove(cssClass: Tint.warning.rawValue)
            reestablishIcon.remove(cssClass: Tint.error.rawValue)
            reestablishIcon.add(cssClass: tint.rawValue)
            spinner.visible = false
            reestablishButton.visible = true
        }
    }

    private func loadAvatarImage(of host: CollaborationSession.UserInfo) {
        guard let url = host.avatarURL.flatMap({ URL(string: "\($0.absoluteString)&s=\(Self.avatarSize * 2)") }) else { return }
        Task { @MainActor [weak self] in
            guard let texture = await AvatarCache.shared.texture(for: url),
                  let self, self.hostID == host.id
            else { return }
            self.hostAvatar.set(customImage: texture)
        }
    }
}
