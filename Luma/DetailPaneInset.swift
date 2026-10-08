import SwiftUI

extension View {
    func detailPaneInset(_ edges: Edge.Set = .horizontal) -> some View {
        modifier(DetailPaneInset(edges: edges))
    }
}

private struct DetailPaneInset: ViewModifier {
    let edges: Edge.Set

    #if canImport(UIKit)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        private var inset: CGFloat { horizontalSizeClass == .compact ? 6 : 20 }
    #else
        private var inset: CGFloat { 20 }
    #endif

    func body(content: Content) -> some View {
        content.padding(edges, inset)
    }
}
