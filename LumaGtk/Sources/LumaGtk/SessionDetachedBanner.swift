import Foundation
import Gtk
import LumaCore

@MainActor
enum SessionDetachedBanner {
    static func make(
        for session: LumaCore.ProcessSession,
        onReattach: @escaping () -> Void
    ) -> Box {
        let banner = Box(orientation: .horizontal, spacing: 12)
        banner.add(cssClass: "luma-banner")
        banner.add(cssClass: bannerStyleClass(for: session))
        banner.marginStart = 0
        banner.marginEnd = 0
        banner.marginTop = 0
        banner.marginBottom = 0
        banner.hexpand = true

        let leading = Box(orientation: .horizontal, spacing: 8)
        leading.marginStart = 16
        leading.marginEnd = 12
        leading.marginTop = 8
        leading.marginBottom = 8
        leading.hexpand = true

        let icon = Label(str: "⚡")
        icon.add(cssClass: "title-3")
        leading.append(child: icon)

        let title = Label(str: session.processName)
        title.add(cssClass: "heading")
        title.halign = .start
        leading.append(child: title)

        if let status = statusText(for: session) {
            let separator = Separator(orientation: .vertical)
            separator.marginStart = 4
            separator.marginEnd = 4
            leading.append(child: separator)

            let statusLabel = Label(str: status)
            statusLabel.add(cssClass: "dim-label")
            statusLabel.halign = .start
            statusLabel.hexpand = true
            statusLabel.ellipsize = .end
            leading.append(child: statusLabel)
        }

        banner.append(child: leading)

        let reattach = Button(label: "\(session.kind.reestablishLabel)…")
        reattach.marginEnd = 16
        reattach.marginTop = 6
        reattach.marginBottom = 6
        reattach.valign = .center
        reattach.sensitive = session.phase != .attaching
        reattach.onClicked { _ in
            MainActor.assumeIsolated {
                onReattach()
            }
        }
        banner.append(child: reattach)

        return banner
    }

    private static func bannerStyleClass(for session: LumaCore.ProcessSession) -> String {
        switch session.detachReason {
        case .applicationRequested:
            return "luma-banner-warning"
        default:
            return "luma-banner-error"
        }
    }

    private static func statusText(for session: LumaCore.ProcessSession) -> String? {
        if session.phase == .attaching {
            return "\(session.kind.reestablishLabel)ing\u{2026}"
        }
        if let lastError = session.lastError, !lastError.isEmpty {
            return "Last \(session.kind.verbDisplayName) attempt failed: \(lastError)"
        }
        switch session.detachReason {
        case .applicationRequested:
            return nil
        case .processReplaced:
            return "Detached because the process was replaced."
        case .processTerminated:
            return "Detached because the process terminated."
        case .connectionTerminated:
            return "Detached because the connection was terminated."
        case .deviceLost:
            return "Detached because the device connection was lost."
        }
    }

    static func shouldShow(for session: LumaCore.ProcessSession) -> Bool {
        if session.phase == .attached { return false }
        if session.phase == .attaching && session.lastAttachedAt == nil { return false }
        return true
    }
}
