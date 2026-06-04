import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
enum SessionDetachedBanner {
    static func make(
        for session: LumaCore.ProcessSession,
        gatingActive: Bool,
        onReattach: @escaping () -> Void,
        onDisarm: @escaping () -> Void,
        onArm: @escaping () -> Void,
        onResumeGating: @escaping () -> Void
    ) -> Widget {
        if isArmedAndIdle(session) {
            return makeArmed(
                for: session,
                gatingActive: gatingActive,
                onDisarm: onDisarm,
                onResumeGating: onResumeGating
            )
        }
        let hasError = session.lastError?.isEmpty == false
        if session.lastAttachedAt == nil, !hasError, case .spawn = session.kind {
            return makeIdle(for: session, onReattach: onReattach, onArm: onArm)
        }
        let style: LumaBannerStyle = hasError || session.detachReason != .applicationRequested ? .error : .warning
        let actionLabel = "\(session.kind.reestablishLabel)\u{2026}"
        return buildBanner(
            style: style,
            iconName: "network-offline-symbolic",
            processName: session.processName,
            message: statusText(for: session),
            actionLabel: actionLabel,
            actionStyle: .suggested,
            actionEnabled: session.phase != .attaching,
            onAction: onReattach
        )
    }

    private static func makeArmed(
        for session: LumaCore.ProcessSession,
        gatingActive: Bool,
        onDisarm: @escaping () -> Void,
        onResumeGating: @escaping () -> Void
    ) -> Widget {
        let hasError = session.lastError?.isEmpty == false
        let style: LumaBannerStyle = hasError ? .error : (gatingActive ? .info : .warning)
        let actionLabel: String
        let actionStyle: BannerActionStyle
        let onAction: () -> Void
        if !gatingActive {
            actionLabel = "Resume"
            actionStyle = .suggested
            onAction = onResumeGating
        } else {
            actionLabel = "Disarm"
            actionStyle = .normal
            onAction = onDisarm
        }
        return buildBanner(
            style: style,
            iconName: "find-location-symbolic",
            processName: session.processName,
            message: armedStatusText(for: session, gatingActive: gatingActive),
            actionLabel: actionLabel,
            actionStyle: actionStyle,
            actionEnabled: true,
            onAction: onAction
        )
    }

    private static func makeIdle(
        for session: LumaCore.ProcessSession,
        onReattach: @escaping () -> Void,
        onArm: @escaping () -> Void
    ) -> Widget {
        return buildBanner(
            style: .warning,
            iconName: "network-offline-symbolic",
            processName: session.processName,
            message: "Idle — not waiting for a launch.",
            actionLabel: "\(session.kind.reestablishLabel)\u{2026}",
            actionStyle: .suggested,
            actionEnabled: true,
            onAction: onReattach,
            secondaryActionLabel: "Arm\u{2026}",
            onSecondaryAction: onArm
        )
    }

    private static func buildBanner(
        style: LumaBannerStyle,
        iconName: String,
        processName: String,
        message: String?,
        actionLabel: String,
        actionStyle: BannerActionStyle,
        actionEnabled: Bool,
        onAction: @escaping () -> Void,
        secondaryActionLabel: String? = nil,
        onSecondaryAction: (() -> Void)? = nil
    ) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.hexpand = true
        row.add(cssClass: "luma-banner")
        row.add(cssClass: style.cssClass)

        let leading = Box(orientation: .horizontal, spacing: 8)
        leading.hexpand = true
        leading.valign = .center

        let icon = Image(iconName: iconName)
        icon.pixelSize = 16
        leading.append(child: icon)

        let nameLabel = Label(str: processName)
        nameLabel.add(cssClass: "heading")
        nameLabel.xalign = 0
        leading.append(child: nameLabel)

        if let message {
            let divider = Box(orientation: .vertical, spacing: 0)
            divider.add(cssClass: "luma-banner-divider")
            leading.append(child: divider)

            let messageLabel = Label(str: message)
            messageLabel.add(cssClass: "caption")
            messageLabel.add(cssClass: "dim-label")
            messageLabel.xalign = 0
            messageLabel.wrap = true
            messageLabel.hexpand = true
            leading.append(child: messageLabel)
        }

        row.append(child: leading)

        if let secondaryActionLabel, let onSecondaryAction {
            let secondaryButton = Button(label: secondaryActionLabel)
            secondaryButton.valign = .center
            secondaryButton.onClicked { _ in
                MainActor.assumeIsolated { onSecondaryAction() }
            }
            row.append(child: secondaryButton)
        }

        let button = Button(label: actionLabel)
        button.valign = .center
        button.sensitive = actionEnabled
        if actionStyle == .suggested {
            button.add(cssClass: "suggested-action")
        }
        button.onClicked { _ in
            MainActor.assumeIsolated { onAction() }
        }
        row.append(child: button)

        return row
    }

    private static func armedStatusText(for session: LumaCore.ProcessSession, gatingActive: Bool) -> String {
        if let lastError = session.lastError, !lastError.isEmpty {
            return "Armed but inactive — \(lastError)"
        }
        if !gatingActive {
            return "Armed but inactive — spawn gating is paused. Resume to enable it."
        }
        let pattern = session.armingState.matchPattern ?? ""
        return pattern.isEmpty
            ? "Waiting for the next matching launch."
            : "Waiting for the next launch matching \(pattern)."
    }

    private static func isArmedAndIdle(_ session: LumaCore.ProcessSession) -> Bool {
        guard case .armed = session.armingState else { return false }
        return session.phase != .attached
    }

    private static func statusText(for session: LumaCore.ProcessSession) -> String? {
        if let lastError = session.lastError, !lastError.isEmpty {
            return "Last \(session.kind.verbDisplayName) attempt failed: \(lastError)"
        }
        switch session.detachReason {
        case .applicationRequested:
            return "Not currently attached."
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
        if session.phase == .attaching { return false }
        return true
    }
}

enum LumaBannerStyle {
    case info
    case warning
    case error

    var cssClass: String {
        switch self {
        case .info: return "luma-banner-info"
        case .warning: return "luma-banner-warning"
        case .error: return "luma-banner-error"
        }
    }
}

private enum BannerActionStyle {
    case suggested
    case normal
}
