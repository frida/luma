import Foundation

/// The colours the moldable visualisations draw with, in light and dark, so a
/// graph or chart reads the same as the SwiftUI ones and follows the theme --
/// a node is a card with contrasting text, not an inverted block.
@MainActor
enum PharoVizColors {
    struct RGBA {
        let r, g, b, a: Double
        init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }
    }

    struct Palette {
        let nodeFill: RGBA
        let nodeText: RGBA
        let border: RGBA
        let borderHover: RGBA
        let edge: RGBA
        let axis: RGBA
        let grid: RGBA
        let label: RGBA
    }

    /// Frida's brand colour, worn by a selected node and its edges, a mark on a
    /// chart -- the same in either theme.
    static let brand = RGBA(0.937, 0.392, 0.337)

    /// Distinct hues for a chart's series, brand first.
    static let series: [RGBA] = [
        RGBA(0.937, 0.392, 0.337),
        RGBA(0.298, 0.651, 0.898),
        RGBA(0.451, 0.749, 0.451),
        RGBA(0.851, 0.647, 0.259),
        RGBA(0.596, 0.451, 0.804),
        RGBA(0.902, 0.541, 0.678),
    ]

    static var current: Palette {
        ThemeWatcher.currentAppearance() == .dark ? dark : light
    }

    private static let light = Palette(
        nodeFill: RGBA(0.99, 0.99, 1.0),
        nodeText: RGBA(0.13, 0.14, 0.16),
        border: RGBA(0.78, 0.78, 0.82),
        borderHover: RGBA(0.52, 0.52, 0.57),
        edge: RGBA(0.5, 0.5, 0.55, 0.55),
        axis: RGBA(0.5, 0.5, 0.55, 0.9),
        grid: RGBA(0.5, 0.5, 0.55, 0.16),
        label: RGBA(0.4, 0.4, 0.45, 1)
    )

    private static let dark = Palette(
        nodeFill: RGBA(0.19, 0.19, 0.22),
        nodeText: RGBA(0.92, 0.92, 0.94),
        border: RGBA(0.4, 0.4, 0.45),
        borderHover: RGBA(0.62, 0.62, 0.68),
        edge: RGBA(0.62, 0.62, 0.68, 0.55),
        axis: RGBA(0.6, 0.6, 0.65, 0.9),
        grid: RGBA(0.6, 0.6, 0.65, 0.18),
        label: RGBA(0.66, 0.66, 0.72, 1)
    )
}
