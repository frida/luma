import SwiftUI

extension View {
    func detailPaneInset(_ edges: Edge.Set = .horizontal) -> some View {
        modifier(DetailPaneInset(edges: edges, hangingWidth: 0))
    }

    func detailPaneInset(hanging hangingWidth: CGFloat) -> some View {
        modifier(DetailPaneInset(edges: .horizontal, hangingWidth: hangingWidth))
    }
}

private struct DetailPaneInset: ViewModifier {
    let edges: Edge.Set
    let hangingWidth: CGFloat

    private static let regularInset: CGFloat = 20
    private static let compactInset: CGFloat = 6

    #if canImport(UIKit)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        private var inset: CGFloat { horizontalSizeClass == .compact ? Self.compactInset : Self.regularInset }
    #else
        private var inset: CGFloat { Self.regularInset }
    #endif

    func body(content: Content) -> some View {
        content
            .padding(edges.subtracting(.leading), inset)
            .padding(.leading, edges.contains(.leading) ? leadingInset : 0)
    }

    private var leadingInset: CGFloat {
        max(inset - hangingWidth, Self.compactInset)
    }
}
