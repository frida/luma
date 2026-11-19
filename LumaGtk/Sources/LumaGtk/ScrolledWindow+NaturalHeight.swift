import CGtk
import Gtk

extension ScrolledWindow {
    func set(naturallyTallChild child: Widget) {
        set(child: child)
        gtk_scrollable_set_vscroll_policy(
            UnsafeMutableRawPointer(gtk_scrolled_window_get_child(scrolled_window_ptr))
                .assumingMemoryBound(to: GtkScrollable.self),
            GTK_SCROLL_NATURAL)
    }
}
