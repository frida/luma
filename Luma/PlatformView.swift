import MetalKit
import SwiftUI

#if canImport(AppKit)
    import AppKit

    typealias PlatformView = NSView
    typealias PlatformViewRepresentable = NSViewRepresentable
#elseif canImport(UIKit)
    import UIKit

    typealias PlatformView = UIView
    typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// A SwiftUI view living inside a view hierarchy the platform lays out. AppKit
/// hosts one outright; UIKit hosts it through a controller, which has to be
/// kept alive for as long as the view is.
final class PlatformHostingView: PlatformView {
    #if canImport(AppKit)
        private let hosting: NSHostingView<AnyView>

        init(rootView: some View) {
            hosting = NSHostingView(rootView: AnyView(rootView))
            super.init(frame: .zero)
            addSubview(hosting)
        }

        override func layout() {
            super.layout()
            hosting.frame = bounds
        }

        var fittingHeight: CGFloat {
            layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }
    #elseif canImport(UIKit)
        private let hosting: UIHostingController<AnyView>

        init(rootView: some View) {
            hosting = UIHostingController(rootView: AnyView(rootView))
            super.init(frame: .zero)
            hosting.view.backgroundColor = .clear
            addSubview(hosting.view)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hosting.view.frame = bounds
        }

        var fittingHeight: CGFloat {
            hosting.sizeThatFits(in: CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlatformHostingView is not loaded from a nib")
    }
}

extension MTKView {
    /// How many pixels a point is worth where the view is not laid out yet and
    /// its own drawable cannot say.
    var pixelsPerPoint: CGFloat {
        #if canImport(AppKit)
            return window?.backingScaleFactor ?? 1
        #else
            return window?.screen.scale ?? contentScaleFactor
        #endif
    }
}
