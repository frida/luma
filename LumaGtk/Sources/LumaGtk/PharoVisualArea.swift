import CCairo
import Cairo
import Foundation

/// Shared drawing bits for the moldable visualisations -- the graph and the
/// chart each own their own area, but reach for the same font and label fitting.
@MainActor
enum PharoVisualArea {
    static let margin = 24.0

    static func setFont(_ ctx: Cairo.ContextRef, size: Double) {
        "monospace".withCString { ctx.selectFontFace($0, slant: .normal, weight: .normal) }
        ctx.fontSize = size
    }

    static func fit(_ label: String, into width: Double, ctx: Cairo.ContextRef) -> String {
        var text = label
        while text.count > 1, text.withCString({ ctx.textExtents($0).width }) > width {
            text = String(text.dropLast(2)) + "…"
        }
        return text
    }
}
