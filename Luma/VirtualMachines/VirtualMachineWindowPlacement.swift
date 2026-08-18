import LumaCore
import SwiftUI

#if canImport(AppKit)
import AppKit

/// Keeps a guest's own window sitting exactly where the host has made room
/// for it, so what is drawn is the guest's window rather than a copy of it.
struct VirtualMachineWindowPlacement: PlatformViewRepresentable {
    let source: any VirtualMachineWindowSource

    func makeNSView(context: Context) -> PlacementView {
        PlacementView(source: source)
    }

    func updateNSView(_ view: PlacementView, context: Context) {
        view.source = source
        view.placeGuest()
    }

    static func dismantleNSView(_ view: PlacementView, coordinator: ()) {
        view.source?.hide()
    }

    final class PlacementView: NSView {
        var source: (any VirtualMachineWindowSource)?

        private var observers: [Any] = []

        init(source: any VirtualMachineWindowSource) {
            self.source = source
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not decoded")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []

            guard let window else {
                source?.hide()
                return
            }

            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification] {
                observe(name, on: window) { $0.placeGuest() }
            }
            observe(NSWindow.didResignKeyNotification, on: window) { $0.source?.hide() }
            placeGuest()
        }

        private func observe(_ name: Notification.Name, on window: NSWindow, react: @escaping @MainActor (PlacementView) -> Void) {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        react(self)
                    }
                }
            )
        }

        override func layout() {
            super.layout()
            placeGuest()
        }

        func placeGuest() {
            guard let source, let window, window.isKeyWindow, !bounds.isEmpty else { return }

            let inWindow = convert(bounds, to: nil)
            let onScreen = window.convertToScreen(inWindow)
            source.place(
                in: VirtualMachineScreenRect(
                    x: onScreen.minX,
                    y: onScreen.minY,
                    width: onScreen.width,
                    height: onScreen.height
                )
            )
        }
    }
}
#endif
