import CGtk
import Gtk

@MainActor
enum StyleSheet {
    static let css = """
    .event-stream-pane {
        border-top: 1px solid alpha(@theme_fg_color, 0.18);
    }
    .event-stream-pane.is-expanded {
        background-color: @theme_base_color;
    }
    .luma-live-dot {
        color: @success_color;
    }
    .luma-paused-dot {
        color: alpha(@theme_fg_color, 0.45);
    }
    .event-stream-pane.has-pending-events {
        background-color: alpha(@accent_bg_color, 0.18);
        border-top-color: alpha(@accent_bg_color, 0.45);
    }

    .luma-banner {
        border-bottom: 1px solid alpha(currentColor, 0.15);
    }

    .luma-install-banner {
        background-color: alpha(@accent_bg_color, 0.12);
        border: 1px solid alpha(@accent_bg_color, 0.45);
        border-radius: 6px;
    }

    .luma-banner.luma-banner-warning {
        background-color: alpha(@warning_bg_color, 0.18);
        border-bottom-color: alpha(@warning_bg_color, 0.45);
    }

    .luma-banner.luma-banner-error {
        background-color: alpha(@error_bg_color, 0.20);
        border-bottom-color: alpha(@error_bg_color, 0.5);
    }

    .luma-disasm-row:hover {
        background-color: alpha(@theme_fg_color, 0.05);
        border-radius: 8px;
    }

    .luma-disasm-row.selected {
        background-color: alpha(@accent_bg_color, 0.25);
        border-radius: 8px;
    }

    .luma-disasm-row.pulsing {
        background-color: alpha(@accent_bg_color, 0.45);
        border-radius: 8px;
        animation: luma-disasm-pulse 1.08s ease-in-out;
    }

    @keyframes luma-disasm-pulse {
        0%, 100% { background-color: alpha(@accent_bg_color, 0.06); }
        16%, 50%, 84% { background-color: alpha(@accent_bg_color, 0.45); }
        33%, 67% { background-color: alpha(@accent_bg_color, 0.06); }
    }

    .luma-disasm-decoration {
        font-size: 0.55em;
        color: alpha(@theme_fg_color, 0.45);
    }

    button.luma-disasm-jump {
        min-height: 0;
        min-width: 0;
        padding: 1px 6px;
        border-radius: 999px;
        background-color: alpha(@theme_fg_color, 0.08);
        opacity: 0.75;
    }
    button.luma-disasm-jump:hover {
        opacity: 1.0;
        background-color: alpha(@theme_fg_color, 0.14);
    }

    .luma-loading-capsule {
        background-color: alpha(@theme_bg_color, 0.85);
        border: 1px solid alpha(@theme_fg_color, 0.12);
        border-radius: 999px;
        padding: 8px 12px;
        box-shadow: 0 1px 4px alpha(black, 0.15);
    }

    .luma-itrace-fn-0 { background-image: none; background-color: alpha(#1f77b4, 0.55); color: white; }
    .luma-itrace-fn-1 { background-image: none; background-color: alpha(#ff7f0e, 0.55); color: white; }
    .luma-itrace-fn-2 { background-image: none; background-color: alpha(#2ca02c, 0.55); color: white; }
    .luma-itrace-fn-3 { background-image: none; background-color: alpha(#d62728, 0.55); color: white; }
    .luma-itrace-fn-4 { background-image: none; background-color: alpha(#9467bd, 0.55); color: white; }
    .luma-itrace-fn-5 { background-image: none; background-color: alpha(#8c564b, 0.55); color: white; }
    .luma-itrace-fn-6 { background-image: none; background-color: alpha(#e377c2, 0.55); color: white; }
    .luma-itrace-fn-7 { background-image: none; background-color: alpha(#17becf, 0.55); color: white; }

    .luma-diff-same { }
    .luma-diff-added { background-color: alpha(#26a269, 0.15); }
    .luma-diff-removed { background-color: alpha(#c01c28, 0.15); }
    .luma-diff-changed { background-color: alpha(#e5a50a, 0.10); }
    .luma-diff-block-name { color: #2aa1b3; }
    .luma-diff-indicator-removed { color: #c01c28; }
    .luma-diff-indicator-added { color: #26a269; }
    .luma-diff-val-left { color: #c01c28; }
    .luma-diff-val-right { color: #26a269; }

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
    .luma-cfg-instr-list {
        background: transparent;
        padding: 0;
        margin: 0;
        min-height: 0;
    }
    .luma-cfg-instr-list > row {
        padding: 0 4px;
        min-height: 0;
    }
    scrolledwindow.luma-popover-scroll > viewport { color: #2e3436; }
    .luma-cfg-reg-changed { color: #1c71d8; font-weight: bold; }
    @media (prefers-color-scheme: dark) {
        scrolledwindow.luma-popover-scroll > viewport { color: #deddda; }
        .luma-cfg-reg-changed { color: #78aeed; }
    }

    .luma-js-expander {
        margin: 0;
        padding: 0;
    }
    .luma-js-expander > title {
        padding: 0;
        margin: 0;
        min-height: 0;
    }
    .luma-js-expander > title > arrow {
        min-width: 10px;
        min-height: 10px;
        -gtk-icon-size: 10px;
        margin: 0 0 0 -4px;
        opacity: 0.5;
    }

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

    .luma-section-body {
        background-color: alpha(@theme_fg_color, 0.06);
        border: 1px solid alpha(@theme_fg_color, 0.08);
        border-radius: 8px;
        padding: 10px 12px;
    }

    .luma-pid-badge {
        border-radius: 4px;
        padding: 1px 6px;
        background-color: alpha(@theme_fg_color, 0.12);
        color: alpha(@theme_fg_color, 0.75);
    }

    popover.menu button.luma-menu-destructive {
        color: @error_color;
        font-weight: normal;
        padding: 6px 8px;
        min-height: 0;
    }
    popover.menu button.luma-menu-destructive:hover {
        background-color: alpha(@error_color, 0.12);
    }
    popover.menu button.luma-menu-destructive:active {
        background-color: alpha(@error_color, 0.22);
    }
    popover.menu button.luma-menu-destructive label {
        padding-left: 0;
    }

    .luma-chat-bubble-local { background-color: alpha(@accent_bg_color, 0.20); border-radius: 12px; padding: 6px 10px; }
    .luma-chat-bubble-remote { background-color: alpha(@theme_fg_color, 0.08); border-radius: 12px; padding: 6px 10px; }
    .luma-invite-frame { border: 1px solid alpha(@theme_fg_color, 0.15); border-radius: 6px; padding: 8px 12px; }
    .luma-linked-lab-hint { border: 1px solid alpha(@theme_fg_color, 0.15); border-radius: 6px; padding: 6px 10px; }
    """

    // GTK4's default CSD adds an invisible margin around each window
    // so it can draw a drop shadow there. On X11/Wayland the
    // compositor blends that margin transparently, but on Windows
    // there's no compositor in the mix and the shadow area renders
    // as a solid black rectangle hugging the window. Collapse the
    // margin and suppress the shadow on Windows only.
    #if os(Windows)
    private static let platformCss = """
    window.csd,
    window.csd decoration,
    window.csd decoration-overlay {
        margin: 0;
        box-shadow: none;
        border-radius: 0;
    }
    """
    #else
    private static let platformCss = ""
    #endif

    static func install() {
        let provider = CssProvider()
        provider.loadFrom(string: css + "\n" + platformCss)
        guard let display = gdk_display_get_default() else { return }
        gtk_style_context_add_provider_for_display(
            display,
            provider.styleProvider.style_provider_ptr,
            UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
    }
}
