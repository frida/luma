import MetalKit

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

class OnScreenMTKView: MTKView {
    enum Visibility {
        case onScreen
        case offScreen
    }

    private(set) var visibility: Visibility = .offScreen
    var visibilityChanged: ((Visibility) -> Void)?

    #if canImport(AppKit)
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            guard let newWindow else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reassessVisibility()
        }

        override func viewDidHide() {
            super.viewDidHide()
            reassessVisibility()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            reassessVisibility()
        }

        @objc private func windowOcclusionChanged(_ notification: Notification) {
            reassessVisibility()
        }
    #else
        override func didMoveToWindow() {
            super.didMoveToWindow()
            reassessVisibility()
        }
    #endif

    private func reassessVisibility() {
        let current = currentVisibility
        guard current != visibility else { return }
        visibility = current
        visibilityChanged?(current)
    }

    #if canImport(AppKit)
        private var currentVisibility: Visibility {
            guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { return .offScreen }
            return .onScreen
        }
    #else
        private var currentVisibility: Visibility {
            window == nil ? .offScreen : .onScreen
        }
    #endif
}
