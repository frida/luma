import CGtk
import Gtk

@MainActor
enum StyleSheet {
    static let css = """
    .event-stream-pane.has-pending-events {
        background-color: alpha(@accent_bg_color, 0.18);
        border-top: 1px solid alpha(@accent_bg_color, 0.45);
    }

    .luma-banner {
        border-bottom: 1px solid alpha(currentColor, 0.15);
    }

    .luma-banner.luma-banner-warning {
        background-color: alpha(@warning_bg_color, 0.18);
        border-bottom-color: alpha(@warning_bg_color, 0.45);
    }

    .luma-banner.luma-banner-error {
        background-color: alpha(@error_bg_color, 0.20);
        border-bottom-color: alpha(@error_bg_color, 0.5);
    }

    .luma-disasm-row.selected {
        background-color: alpha(@accent_bg_color, 0.25);
    }
    """

    static func install() {
        let provider = CssProvider()
        provider.loadFrom(string: css)
        guard let display = gdk_display_get_default() else { return }
        gtk_style_context_add_provider_for_display(
            display,
            provider.styleProvider.style_provider_ptr,
            UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
    }
}
