import Foundation
import Gtk

@MainActor
final class ToastOverlay {
    let widget: Overlay

    private var current: Box?
    private var dismissTask: Task<Void, Never>?

    init(content: Widget) {
        widget = Overlay()
        widget.hexpand = true
        widget.vexpand = true
        widget.set(child: content)
    }

    func show(_ text: String, durationSeconds: Double = 3.0) {
        if let existing = current {
            widget.removeOverlay(widget: existing)
            current = nil
        }
        dismissTask?.cancel()

        let toast = Box(orientation: .horizontal, spacing: 8)
        toast.add(cssClass: "luma-toast")
        toast.add(cssClass: "osd")
        toast.halign = .center
        toast.valign = .end
        toast.marginBottom = 24

        let label = Label(str: text)
        label.halign = .start
        label.marginStart = 16
        label.marginEnd = 16
        label.marginTop = 10
        label.marginBottom = 10
        toast.append(child: label)

        widget.addOverlay(widget: toast)
        current = toast

        let nanos = UInt64(durationSeconds * 1_000_000_000)
        dismissTask = Task { @MainActor [weak self, weak toast] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self, let toast else { return }
            self.widget.removeOverlay(widget: toast)
            if self.current === toast {
                self.current = nil
            }
        }
    }
}
