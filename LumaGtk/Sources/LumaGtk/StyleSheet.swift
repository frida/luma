import CGtk
import Gtk

@MainActor
enum StyleSheet {
    static let css = """
    .event-stream-pane {
        border-top: 1px solid alpha(@theme_fg_color, 0.18);
    }
    .event-stream-pane.has-pending-events {
        background-color: alpha(@accent_bg_color, 0.18);
        border-top-color: alpha(@accent_bg_color, 0.45);
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

    .luma-empty-state {
        opacity: 0.95;
    }

    .luma-empty-state image {
        opacity: 0.55;
        margin-bottom: 6px;
    }

    .luma-sidebar-section-header {
        padding: 6px 8px 4px 4px;
        color: alpha(@theme_fg_color, 0.55);
        font-size: 0.78em;
        font-weight: 600;
    }
    expander title:hover .luma-sidebar-section-header {
        color: @theme_fg_color;
    }
    expander title {
        border-radius: 6px;
        padding: 2px 6px;
        margin: 0 8px;
    }
    expander title:hover {
        background: alpha(@theme_fg_color, 0.05);
    }

    box.luma-menu {
        padding: 4px;
        min-width: 200px;
    }
    button.luma-menu-item {
        padding: 6px 10px;
        border-radius: 6px;
        background: none;
        background-image: none;
        background-color: transparent;
        border: none;
        box-shadow: none;
        color: @theme_fg_color;
        text-shadow: none;
        -gtk-icon-shadow: none;
        min-width: 180px;
    }
    button.luma-menu-item label {
        color: @theme_fg_color;
    }
    button.luma-menu-item:hover,
    button.luma-menu-item:focus,
    button.luma-menu-item:focus:hover {
        background: none;
        background-image: none;
        background-color: alpha(@accent_bg_color, 0.18);
    }
    button.luma-menu-item.luma-menu-destructive,
    button.luma-menu-item.luma-menu-destructive label {
        color: #e01b24;
    }
    button.luma-menu-item.luma-menu-destructive:hover,
    button.luma-menu-item.luma-menu-destructive:focus:hover {
        background: none;
        background-image: none;
        background-color: alpha(#e01b24, 0.18);
    }
    .luma-menu separator {
        background-color: alpha(@theme_fg_color, 0.15);
        margin: 4px 2px;
        min-height: 1px;
    }

    .luma-session-icon {
        border-radius: 4px;
        border: 1px solid alpha(@accent_bg_color, 0.4);
    }

    .luma-event-badge {
        border-radius: 4px;
        padding: 1px 6px;
        font-size: 0.78em;
    }
    .luma-event-source-0 { background-color: alpha(#1f77b4, 0.18); color: #1f77b4; }
    .luma-event-source-1 { background-color: alpha(#ff7f0e, 0.18); color: #ff7f0e; }
    .luma-event-source-2 { background-color: alpha(#2ca02c, 0.18); color: #2ca02c; }
    .luma-event-source-3 { background-color: alpha(#d62728, 0.18); color: #d62728; }
    .luma-event-source-4 { background-color: alpha(#9467bd, 0.18); color: #9467bd; }
    .luma-event-source-5 { background-color: alpha(#8c564b, 0.18); color: #8c564b; }
    .luma-event-source-6 { background-color: alpha(#e377c2, 0.18); color: #e377c2; }
    .luma-event-source-7 { background-color: alpha(#17becf, 0.18); color: #17becf; }

    .luma-event-level-info { background-color: alpha(@accent_bg_color, 0.18); color: @accent_bg_color; }
    .luma-event-level-debug { background-color: alpha(#3584e4, 0.18); color: #3584e4; }
    .luma-event-level-warn { background-color: alpha(#e5a50a, 0.22); color: #c64600; }
    .luma-event-level-error { background-color: alpha(#c01c28, 0.22); color: #c01c28; }

    .luma-event-jserror { color: #c01c28; }
    .luma-event-delta { font-size: 0.78em; }

    .luma-event-pending-pill {
        border-radius: 999px;
        padding: 4px 12px;
        background-color: alpha(@accent_bg_color, 0.85);
        color: white;
        box-shadow: 0 2px 6px alpha(black, 0.3);
    }

    .luma-chat-bubble-local { background-color: alpha(@accent_bg_color, 0.20); border-radius: 12px; padding: 6px 10px; }
    .luma-chat-bubble-remote { background-color: alpha(@theme_fg_color, 0.08); border-radius: 12px; padding: 6px 10px; }
    .luma-invite-frame { border: 1px solid alpha(@theme_fg_color, 0.15); border-radius: 6px; padding: 8px 12px; }
    .luma-linked-room-hint { border: 1px solid alpha(@theme_fg_color, 0.15); border-radius: 6px; padding: 6px 10px; }
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
