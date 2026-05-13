import AppKit
import SwiftUI

struct CursorOverrideRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CursorOverrideNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CursorOverrideNSView: NSView {
    private nonisolated(unsafe) var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            uninstallMonitor()
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self,
                let window = self.window,
                event.window === window,
                self.convert(self.bounds, to: nil).contains(event.locationInWindow)
            else {
                return event
            }
            NSCursor.arrow.set()
            return nil
        }
    }

    private func uninstallMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
