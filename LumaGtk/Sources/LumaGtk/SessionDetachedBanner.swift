import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
enum SessionDetachedBanner {
    static func make(
        for session: LumaCore.ProcessSession,
        onReattach: @escaping () -> Void
    ) -> Adw.Banner {
        let banner = title(for: session).withCString { Adw.Banner(title: $0) }
        banner.useMarkup = true
        banner.buttonLabel = "\(session.kind.reestablishLabel)\u{2026}"
        banner.setButton(style: .suggested)
        banner.revealed = true
        banner.sensitive = session.phase != .attaching
        banner.onButtonClicked { _ in
            MainActor.assumeIsolated { onReattach() }
        }
        return banner
    }

    private static func title(for session: LumaCore.ProcessSession) -> String {
        let name = escapeMarkup(session.processName)
        guard let status = statusText(for: session) else {
            return "<b>\(name)</b>"
        }
        return "<b>\(name)</b> · \(escapeMarkup(status))"
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

    private static func escapeMarkup(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "'": out.append("&apos;")
            case "\"": out.append("&quot;")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func shouldShow(for session: LumaCore.ProcessSession) -> Bool {
        if session.phase == .attached { return false }
        if session.phase == .attaching && session.lastAttachedAt == nil { return false }
        return true
    }
}
