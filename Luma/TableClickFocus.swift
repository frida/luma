import SwiftUI

extension View {
    @ViewBuilder
    func tableTakesFocusOnClick() -> some View {
        #if canImport(AppKit)
            background(TableClickFocus())
        #else
            self
        #endif
    }
}

#if canImport(AppKit)
private struct TableClickFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.watch(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var monitor: Any?
        private weak var view: NSView?

        func watch(_ view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.focusTable(under: event)
                return event
            }
        }

        private func focusTable(under event: NSEvent) {
            guard let view, let window = view.window, event.window === window,
                view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                let table = NSTableView.under(event.locationInWindow, in: window),
                window.firstResponder !== table
            else { return }
            window.makeFirstResponder(table)
        }

        func stop() {
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
        }
    }
}

extension NSTableView {
    static func under(_ point: NSPoint, in window: NSWindow) -> NSTableView? {
        var hit = window.contentView?.hitTest(point)
        while let view = hit {
            if let table = view as? NSTableView {
                return table
            }
            hit = view.superview
        }
        return nil
    }
}
#endif
