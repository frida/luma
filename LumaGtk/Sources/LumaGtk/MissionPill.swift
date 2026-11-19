import Foundation
import Gtk
import LumaCore

@MainActor
enum MissionPill {
    static func makeStatus(_ status: MissionStatus) -> Label {
        make(text: MissionPalette.label(for: status), color: MissionPalette.color(for: status))
    }

    static func makeActionStatus(_ status: MissionActionStatus) -> Label {
        make(text: status.rawValue.capitalized, color: MissionPalette.color(for: status))
    }

    static func makeFindingStatus(_ status: MissionFindingStatus) -> Label {
        make(text: status.rawValue.capitalized, color: MissionPalette.color(for: status))
    }

    static func makeConfidence(_ confidence: MissionFindingConfidence) -> Label {
        make(
            text: confidence.rawValue.capitalized,
            color: MissionPalette.color(for: confidence)
        )
    }

    private static func make(text: String, color: MissionPalette.Color) -> Label {
        let label = Label(str: "")
        label.useMarkup = true
        let escaped = StyledTextPango.escape(text)
        label.setMarkup(
            str:
                "<span size=\"x-small\" weight=\"bold\" foreground=\"\(color.hex)\"> \(escaped) </span>"
        )
        label.add(cssClass: "luma-mission-pill")
        label.halign = .start
        label.valign = .center
        label.tooltipText = text
        return label
    }
}

@MainActor
enum MissionPalette {
    struct Color: Sendable {
        let r: Double
        let g: Double
        let b: Double

        var hex: String {
            String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
        }
    }

    static let assistant = Color(r: 0.20, g: 0.51, b: 0.98)
    static let user = Color(r: 0.62, g: 0.32, b: 0.92)
    static let tool = Color(r: 0.96, g: 0.55, b: 0.13)
    static let muted = Color(r: 0.50, g: 0.50, b: 0.55)
    static let success = Color(r: 0.18, g: 0.69, b: 0.32)
    static let warning = Color(r: 0.94, g: 0.59, b: 0.05)
    static let danger = Color(r: 0.84, g: 0.20, b: 0.18)
    static let paused = Color(r: 0.93, g: 0.74, b: 0.06)

    static func color(for status: MissionStatus) -> Color {
        switch status {
        case .drafting, .cancelled: return muted
        case .running: return assistant
        case .awaitingApproval: return warning
        case .paused: return paused
        case .completed: return success
        case .failed: return danger
        }
    }

    static func color(for status: MissionActionStatus) -> Color {
        switch status {
        case .pending: return warning
        case .approved, .running: return assistant
        case .rejected: return muted
        case .succeeded: return success
        case .failed: return danger
        }
    }

    static func color(for status: MissionFindingStatus) -> Color {
        switch status {
        case .proposed: return warning
        case .accepted: return success
        case .refuted: return danger
        case .superseded: return muted
        }
    }

    static func color(for confidence: MissionFindingConfidence) -> Color {
        switch confidence {
        case .low: return muted
        case .medium: return warning
        case .high: return success
        }
    }

    static func label(for status: MissionStatus) -> String {
        switch status {
        case .drafting: return "Drafting"
        case .running: return "Running"
        case .awaitingApproval: return "Awaiting"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Canceled"
        }
    }
}
