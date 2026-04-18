import CLuma
import Gtk

/// Apply platform-specific tweaks to a freshly-created GtkWindow.
///
/// On Windows this tags the window with `.solid-csd` so GTK drops its
/// (black-on-Windows) shadow margin, and asks DWM for native rounded
/// corners on Windows 11. No-op elsewhere.
@MainActor
func applyWindowDecoration<W: WidgetProtocol>(_ window: W) {
    luma_prepare_window(UnsafeMutableRawPointer(window.widget_ptr))
}
