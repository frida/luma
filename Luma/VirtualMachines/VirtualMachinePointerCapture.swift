import LumaCore
import SwiftUI

#if canImport(AppKit)
import AppKit

/// The guest's pointer, driven by the real thing: where it is, which button
/// went down, and how far the wheel turned.
struct VirtualMachinePointerCapture: PlatformViewRepresentable {
    let placement: CGRect
    let guestSize: CGSize?
    let isAbsolute: Bool
    let send: (VirtualMachineInputEvent) -> Void
    let captureChanged: (Bool) -> Void
    let hoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> PointerView {
        PointerView()
    }

    func updateNSView(_ view: PointerView, context: Context) {
        view.placement = placement
        view.guestSize = guestSize
        view.isAbsolute = isAbsolute
        view.send = send
        view.captureChanged = captureChanged
        view.hoverChanged = hoverChanged
    }

    static func dismantleNSView(_ view: PointerView, coordinator: ()) {
        view.releasePointer()
    }

    final class PointerView: NSView {
        var placement: CGRect = .zero
        var guestSize: CGSize?
        var isAbsolute = true
        var send: ((VirtualMachineInputEvent) -> Void)?
        var captureChanged: ((Bool) -> Void)?
        var hoverChanged: ((Bool) -> Void)?

        private var pointer: PointerMode = .free
        private var releaseChord: Any?
        private var windowResignation: Any?
        private var tracking: NSTrackingArea?

        /// A guest left with the PC's own mouse only hears how far the pointer
        /// moved, so the host's has to stop moving: it is parked and hidden
        /// while the guest's is being driven, leaving one pointer on screen
        /// instead of two drifting apart.
        private enum PointerMode {
            case free
            case captured(returningTo: CGPoint)
        }

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            releasePointer()

            if let windowResignation {
                NotificationCenter.default.removeObserver(windowResignation)
                self.windowResignation = nil
            }

            guard let window else { return }

            windowResignation = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releasePointer() }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let tracking {
                removeTrackingArea(tracking)
            }

            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            hoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            hoverChanged?(false)
        }

        override func mouseMoved(with event: NSEvent) {
            reportMove(event)
        }

        override func mouseDragged(with event: NSEvent) {
            reportMove(event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            reportMove(event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            reportMove(event)
        }

        override func mouseDown(with event: NSEvent) {
            if !isAbsolute, case .free = pointer {
                capturePointer()
                return
            }

            reportMove(event)
            send?(.pointerButtonDown(button: .left))
        }

        override func mouseUp(with event: NSEvent) {
            reportMove(event)
            send?(.pointerButtonUp(button: .left))
        }

        override func rightMouseDown(with event: NSEvent) {
            reportMove(event)
            send?(.pointerButtonDown(button: .right))
        }

        override func rightMouseUp(with event: NSEvent) {
            reportMove(event)
            send?(.pointerButtonUp(button: .right))
        }

        override func otherMouseDown(with event: NSEvent) {
            reportMove(event)
            send?(.pointerButtonDown(button: .middle))
        }

        override func otherMouseUp(with event: NSEvent) {
            reportMove(event)
            send?(.pointerButtonUp(button: .middle))
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0 else { return }
            send?(.scrolled(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY))
        }

        private func capturePointer() {
            pointer = .captured(returningTo: NSEvent.mouseLocation)
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
            releaseChord = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                if event.modifierFlags.isSuperset(of: [.control, .option]) {
                    MainActor.assumeIsolated { self?.releasePointer() }
                }
                return event
            }
            captureChanged?(true)
        }

        func releasePointer() {
            guard case .captured(let origin) = pointer else { return }
            pointer = .free

            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(CGPoint(x: origin.x, y: NSScreen.screens[0].frame.height - origin.y))
            NSCursor.unhide()

            if let releaseChord {
                NSEvent.removeMonitor(releaseChord)
                self.releaseChord = nil
            }
            captureChanged?(false)
        }

        /// A guest with a tablet is told where the pointer is; one left with
        /// the PC's own mouse is told how far it moved, in its own pixels
        /// rather than the points the screen happens to be drawn at.
        private func reportMove(_ event: NSEvent) {
            guard isAbsolute else {
                guard case .captured = pointer else { return }

                let scale = guestScale
                send?(.pointerMovedBy(dx: event.deltaX * scale.width, dy: event.deltaY * scale.height))
                return
            }

            guard let position = guestPosition(of: convert(event.locationInWindow, from: nil)) else { return }
            send?(.pointerMoved(x: position.x, y: position.y))
        }

        private var guestScale: CGSize {
            guard let guestSize, placement.width > 0, placement.height > 0 else { return CGSize(width: 1, height: 1) }
            return CGSize(width: guestSize.width / placement.width, height: guestSize.height / placement.height)
        }

        /// The view's own coordinates run from the bottom left, the guest's
        /// from the top left of where its frame was drawn.
        private func guestPosition(of point: CGPoint) -> CGPoint? {
            guard let guestSize, placement.width > 0, placement.height > 0 else { return nil }

            let x = (point.x - placement.minX) / placement.width * guestSize.width
            let y = (bounds.height - point.y - placement.minY) / placement.height * guestSize.height
            guard x >= 0, y >= 0, x < guestSize.width, y < guestSize.height else { return nil }

            return CGPoint(x: x, y: y)
        }
    }
}
#endif
