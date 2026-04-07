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

    .luma-itrace-fn-0 { background-image: none; background-color: alpha(#1f77b4, 0.55); color: white; }
    .luma-itrace-fn-1 { background-image: none; background-color: alpha(#ff7f0e, 0.55); color: white; }
    .luma-itrace-fn-2 { background-image: none; background-color: alpha(#2ca02c, 0.55); color: white; }
    .luma-itrace-fn-3 { background-image: none; background-color: alpha(#d62728, 0.55); color: white; }
    .luma-itrace-fn-4 { background-image: none; background-color: alpha(#9467bd, 0.55); color: white; }
    .luma-itrace-fn-5 { background-image: none; background-color: alpha(#8c564b, 0.55); color: white; }
    .luma-itrace-fn-6 { background-image: none; background-color: alpha(#e377c2, 0.55); color: white; }
    .luma-itrace-fn-7 { background-image: none; background-color: alpha(#17becf, 0.55); color: white; }
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
