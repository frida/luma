import CGtk
import Gtk

extension Widget {
    func setAccessibleLabel(_ label: String) {
        var value = GValue()
        g_value_init(&value, GType(64))
        g_value_set_string(&value, label)
        var property = GTK_ACCESSIBLE_PROPERTY_LABEL
        let accessible = UnsafeMutableRawPointer(widget_ptr)?.assumingMemoryBound(to: GtkAccessible.self)
        gtk_accessible_update_property_value(accessible, 1, &property, &value)
        g_value_unset(&value)
    }
}
