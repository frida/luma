import Adw
import CGLib
import Foundation
import GLibObject
import Gtk

@MainActor
final class ToastOverlay {
    let widget: Adw.ToastOverlay

    init(content: Widget) {
        widget = Adw.ToastOverlay()
        widget.hexpand = true
        widget.vexpand = true
        widget.set(child: content)
    }

    func show(_ text: String, durationSeconds: Double = 3.0) {
        widget.dismissAll()
        let toast = text.withCString { Adw.Toast(title: $0) }
        toast.set(timeout: Int(durationSeconds.rounded()))
        // adw_toast_overlay_add_toast is (transfer full), but the generated
        // binding passes the raw pointer without adding a reference. Bump
        // the refcount so the overlay has its own ref and our Swift
        // wrapper's unref on deinit doesn't leave a dangling pointer in
        // the overlay's queue.
        g_object_ref(gpointer(toast.toast_ptr))
        widget.add(toast: toast)
    }
}
