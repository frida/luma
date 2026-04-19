import Adw
import Foundation
import Gtk

@MainActor
final class ToastOverlay {
    let widget: Adw.ToastOverlay

    private var current: Adw.Toast?

    init(content: Widget) {
        widget = Adw.ToastOverlay()
        widget.hexpand = true
        widget.vexpand = true
        widget.set(child: content)
    }

    func show(_ text: String, durationSeconds: Double = 3.0) {
        current?.dismiss()
        let toast = Adw.Toast(title: text)
        toast.set(timeout: Int(durationSeconds.rounded()))
        widget.add(toast: toast)
        current = toast
    }
}
