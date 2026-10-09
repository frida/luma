import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class SessionDetachedBanner {
    struct Actions {
        var reattach: @MainActor (LumaCore.ProcessSession) -> Void
        var disarm: @MainActor (LumaCore.ProcessSession) -> Void
        var arm: @MainActor (LumaCore.ProcessSession) -> Void
        var resumeGating: @MainActor (LumaCore.ProcessSession) -> Void
    }

    let widget: Box

    private let icon: Image
    private let nameLabel: Label
    private let divider: Box
    private let messageLabel: Label
    private let secondaryButton: Button
    private let primaryButton: Button
    private let state = State()
    private var styleCssClass: String?

    private final class State {
        var session: LumaCore.ProcessSession?
        var primaryAction: Action?
        var secondaryAction: Action?
    }

    private enum Action {
        case reattach
        case disarm
        case arm
        case resumeGating

        @MainActor
        func perform(_ actions: Actions, on session: LumaCore.ProcessSession) {
            switch self {
            case .reattach: actions.reattach(session)
            case .disarm: actions.disarm(session)
            case .arm: actions.arm(session)
            case .resumeGating: actions.resumeGating(session)
            }
        }
    }

    private struct Content {
        var style: LumaBannerStyle
        var iconName: String
        var message: String?
        var primary: ActionButton
        var secondary: ActionButton?

        struct ActionButton {
            var label: String
            var action: Action
            var isSuggested: Bool
            var isEnabled: Bool
        }
    }

    init(actions: Actions) {
        widget = Box(orientation: .horizontal, spacing: 8)
        widget.hexpand = true
        widget.visible = false
        widget.add(cssClass: "luma-banner")

        let leading = Box(orientation: .horizontal, spacing: 8)
        leading.hexpand = true
        leading.valign = .center

        icon = Image(iconName: "network-offline-symbolic")
        icon.pixelSize = 16
        icon.valign = .center
        leading.append(child: icon)

        nameLabel = Label(str: "")
        nameLabel.add(cssClass: "heading")
        nameLabel.xalign = 0
        nameLabel.valign = .center
        leading.append(child: nameLabel)

        divider = Box(orientation: .vertical, spacing: 0)
        divider.add(cssClass: "luma-banner-divider")
        divider.valign = .center
        divider.setSizeRequest(width: 1, height: 16)
        leading.append(child: divider)

        messageLabel = Label(str: "")
        messageLabel.add(cssClass: "caption")
        messageLabel.add(cssClass: "dim-label")
        messageLabel.xalign = 0
        messageLabel.valign = .center
        messageLabel.wrap = true
        messageLabel.hexpand = true
        leading.append(child: messageLabel)

        widget.append(child: leading)

        let state = state
        secondaryButton = Button(label: "")
        secondaryButton.valign = .center
        secondaryButton.onClicked { _ in
            MainActor.assumeIsolated {
                state.secondaryAction!.perform(actions, on: state.session!)
            }
        }
        widget.append(child: secondaryButton)

        primaryButton = Button(label: "")
        primaryButton.valign = .center
        primaryButton.onClicked { _ in
            MainActor.assumeIsolated {
                state.primaryAction!.perform(actions, on: state.session!)
            }
        }
        widget.append(child: primaryButton)
    }

    func update(for session: LumaCore.ProcessSession?, engine: Engine?) {
        state.session = session
        guard let session, Self.shouldShow(for: session) else {
            widget.visible = false
            return
        }
        let gatingActive = engine?.isGatingActive(forDeviceID: session.deviceID) ?? false
        let canReattach = engine?.canTakeHosting(session) ?? true
        apply(Self.content(for: session, gatingActive: gatingActive, canReattach: canReattach), processName: session.processName)
        widget.visible = true
    }

    private static func shouldShow(for session: LumaCore.ProcessSession) -> Bool {
        if session.phase == .attached { return false }
        if session.phase == .attaching { return false }
        return true
    }

    private static func content(
        for session: LumaCore.ProcessSession,
        gatingActive: Bool,
        canReattach: Bool
    ) -> Content {
        if isArmedAndIdle(session) {
            return armedContent(for: session, gatingActive: gatingActive)
        }
        let reestablish = Content.ActionButton(
            label: "\(session.kind.reestablishLabel)\u{2026}",
            action: .reattach,
            isSuggested: true,
            isEnabled: canReattach && session.phase != .attaching
        )
        let hasError = session.lastError?.isEmpty == false
        if session.lastAttachedAt == nil, !hasError, case .spawn = session.kind {
            return Content(
                style: .warning,
                iconName: "network-offline-symbolic",
                message: "Idle — not waiting for a launch.",
                primary: reestablish,
                secondary: Content.ActionButton(label: "Arm\u{2026}", action: .arm, isSuggested: false, isEnabled: true)
            )
        }
        return Content(
            style: hasError || session.detachReason != .applicationRequested ? .error : .warning,
            iconName: "network-offline-symbolic",
            message: statusText(for: session),
            primary: reestablish
        )
    }

    private static func isArmedAndIdle(_ session: LumaCore.ProcessSession) -> Bool {
        guard case .armed = session.armingState else { return false }
        return session.phase != .attached
    }

    private static func armedContent(for session: LumaCore.ProcessSession, gatingActive: Bool) -> Content {
        let hasError = session.lastError?.isEmpty == false
        let primary = gatingActive
            ? Content.ActionButton(label: "Disarm", action: .disarm, isSuggested: false, isEnabled: true)
            : Content.ActionButton(label: "Resume", action: .resumeGating, isSuggested: true, isEnabled: true)
        return Content(
            style: hasError ? .error : (gatingActive ? .info : .warning),
            iconName: "find-location-symbolic",
            message: armedStatusText(for: session, gatingActive: gatingActive),
            primary: primary
        )
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

    private func apply(_ content: Content, processName: String) {
        if let styleCssClass {
            widget.remove(cssClass: styleCssClass)
        }
        styleCssClass = content.style.cssClass
        widget.add(cssClass: content.style.cssClass)

        icon.setFrom(iconName: content.iconName)
        nameLabel.label = processName
        divider.visible = content.message != nil
        messageLabel.visible = content.message != nil
        messageLabel.label = content.message ?? ""

        configure(primaryButton, with: content.primary)
        state.primaryAction = content.primary.action
        secondaryButton.visible = content.secondary != nil
        if let secondary = content.secondary {
            configure(secondaryButton, with: secondary)
        }
        state.secondaryAction = content.secondary?.action
    }

    private func configure(_ button: Button, with content: Content.ActionButton) {
        button.label = content.label
        button.sensitive = content.isEnabled
        if content.isSuggested {
            button.add(cssClass: "suggested-action")
        } else {
            button.remove(cssClass: "suggested-action")
        }
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
