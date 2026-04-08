import CGtk
import Gdk
import Gtk

@MainActor
extension Popover {
    func presentPointing(at x: Double, y: Double) {
        var rect = GdkRectangle(x: gint(x), y: gint(y), width: 1, height: 1)
        withUnsafeMutablePointer(to: &rect) { ptr in
            gtk_popover_set_pointing_to(self.popover_ptr, ptr)
        }
        self.popup()
    }
}
