import LumaCore
import SwiftUI
import SwiftyPharo

/// The space a page and its pane share, so a page can say where in it the
/// thing being inspected sits.
nonisolated let pharoPageSpace = "pharo.page"

struct PharoDrillArrow: View {
    var body: some View {
        Image(systemName: "arrowtriangle.right.fill")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: 24)
            .frame(maxHeight: .infinity)
    }
}

extension View {
    /// Lepiter floats each pane as a card, which is what tells one apart from
    /// the next once the arrow between them is all that separates them.
    func pharoPane() -> some View {
        background(.pharoPane)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
            .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
    }
}

extension ShapeStyle where Self == Color {
    static var pharoPane: Color {
        #if canImport(AppKit)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var pharoGutter: Color {
        #if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    /// Frida's brand colour, which the marks and the pager wear in place of the
    /// system accent so they read as part of the same tool.
    static var fridaBrand: Color {
        Color(red: 239 / 255, green: 100 / 255, blue: 86 / 255)
    }
}

/// The arrow into what a page opened, lined up with the cell it came from
/// rather than with the middle of the window.
struct PharoPointingArrow: View {
    let pointsFrom: CGFloat?

    @State private var top: CGFloat = 0

    var body: some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(pharoPageSpace)).minY
            } action: { top = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if let pointsFrom {
            VStack(spacing: 0) {
                // Measured against the page, so the arrow's own offset and its
                // height both come off before it lines up.
                Spacer().frame(height: max(0, pointsFrom - top - arrowHeight / 2))
                PharoDrillArrow().fixedSize()
                Spacer(minLength: 0)
            }
        } else {
            PharoDrillArrow()
        }
    }

    private let arrowHeight: CGFloat = 12
}
