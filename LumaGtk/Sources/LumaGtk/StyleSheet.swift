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

    .luma-diff-same { color: @theme_fg_color; }
    .luma-diff-added { background-color: alpha(#26a269, 0.15); }
    .luma-diff-removed { background-color: alpha(#c01c28, 0.15); }
    .luma-diff-changed { background-color: alpha(#e5a50a, 0.15); }

    .luma-cfg-node { border: 1px solid alpha(@theme_fg_color, 0.4); border-radius: 6px; padding: 6px 10px; background-color: alpha(@theme_bg_color, 0.85); }
    .luma-cfg-node.selected { border-color: @accent_bg_color; background-color: alpha(@accent_bg_color, 0.18); }

    .luma-cfg-section-0 { border-left: 3px solid #1f77b4; }
    .luma-cfg-section-1 { border-left: 3px solid #ff7f0e; }
    .luma-cfg-section-2 { border-left: 3px solid #2ca02c; }
    .luma-cfg-section-3 { border-left: 3px solid #d62728; }
    .luma-cfg-section-4 { border-left: 3px solid #9467bd; }
    .luma-cfg-section-5 { border-left: 3px solid #8c564b; }
    .luma-cfg-section-6 { border-left: 3px solid #e377c2; }
    .luma-cfg-section-7 { border-left: 3px solid #17becf; }
    .luma-cfg-section-current { box-shadow: 0 0 0 2px alpha(@accent_bg_color, 0.6); }
    .luma-cfg-instr { padding: 0 4px; }
    .luma-cfg-regdiff { color: alpha(@accent_fg_color, 0.9); }

    .luma-toast {
        border-radius: 999px;
        background-color: alpha(@theme_fg_color, 0.85);
        color: @theme_bg_color;
        box-shadow: 0 2px 6px alpha(black, 0.3);
        padding: 0;
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
