import CAdw
import CGtk
import Gtk

@MainActor
enum StyleSheet {
    private static let accentColor = adwaitaColor("accent")
    private static let successColor = adwaitaColor("success")
    private static let errorColor = adwaitaColor("error")

    static let css = """
    .luma-flush-sidebar-list {
        padding: 0;
    }

    .luma-flush-sidebar-list > row {
        margin-left: 4px;
        margin-right: 4px;
    }

    .luma-tight-sidebar > row {
        padding-left: 4px;
        padding-right: 4px;
        margin-left: 0;
        margin-right: 0;
    }

    button.luma-sidebar-chevron {
        padding: 0;
        min-width: 24px;
        min-height: 24px;
    }

    button.luma-sidebar-detached {
        padding: 0;
        min-width: 24px;
        min-height: 24px;
    }

    .event-stream-pane {
        border-top: 1px solid alpha(@theme_fg_color, 0.18);
    }
    .event-stream-pane.is-expanded {
        background-color: @theme_base_color;
    }
    .luma-live-dot {
        color: \(successColor);
    }
    .luma-paused-dot {
        color: alpha(@theme_fg_color, 0.45);
    }
    .event-stream-pane.has-pending-events {
        background-color: alpha(@accent_bg_color, 0.18);
        border-top-color: alpha(@accent_bg_color, 0.45);
    }

    /* libadwaita's .monospace rule points font-family at
       --monospace-font-family, which on macOS is not populated by
       GtkSettings, so the class silently falls back to the inherited
       proportional font. Pin it to the CSS monospace keyword so Pango
       always resolves a monospace face. */
    .monospace {
        font-family: monospace;
    }

    .luma-install-banner {
        background-color: alpha(@accent_bg_color, 0.12);
        border: 1px solid alpha(@accent_bg_color, 0.45);
        border-radius: 6px;
    }

    window banner > revealer > widget,
    window banner > revealer > widget:backdrop {
        background-color: rgba(255, 149, 0, 0.15);
        border-bottom: 1px solid rgba(255, 149, 0, 0.40);
        color: @theme_fg_color;
        transition: none;
    }

    window banner > revealer > widget > label,
    window banner > revealer > widget > label:backdrop,
    window banner > revealer > widget:backdrop > label,
    window banner > revealer > widget > button,
    window banner > revealer > widget > button:backdrop,
    window banner > revealer > widget:backdrop > button {
        filter: none;
        opacity: 1;
        transition: none;
    }

    .luma-banner {
        padding: 8px 12px;
    }
    .luma-banner.luma-banner-question {
        padding: 12px;
    }
    .luma-banner.luma-banner-info {
        background-color: rgba(255, 204, 0, 0.15);
        border-bottom: 1px solid rgba(255, 204, 0, 0.30);
    }
    .luma-banner.luma-banner-news {
        background-color: alpha(@accent_bg_color, 0.12);
        border-bottom: 1px solid alpha(@accent_bg_color, 0.30);
    }
    .luma-banner.luma-banner-warning {
        background-color: rgba(255, 149, 0, 0.15);
        border-bottom: 1px solid rgba(255, 149, 0, 0.40);
    }
    .luma-banner.luma-banner-error {
        background-color: rgba(255, 69, 58, 0.15);
        border-bottom: 1px solid rgba(255, 69, 58, 0.40);
    }
    .luma-banner-divider {
        background-color: alpha(@theme_fg_color, 0.25);
        min-width: 1px;
        margin: 2px 0;
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

    .luma-dump-on-text-line {
        margin-top: -\(PatternDecodeView.riseOntoTextLine)px;
    }

    .luma-pattern-tree {
        background: transparent;
    }

    .luma-pattern-tree > row.luma-pattern-row {
        padding: 0;
        min-height: 0;
    }

    .luma-pattern-text {
        font-size: 12px;
    }

    .luma-pattern-name {
        font-weight: bold;
    }

    button.luma-pattern-chevron {
        padding: 0;
        min-width: 16px;
        min-height: 16px;
    }

    .luma-pattern-table {
        border: 1px solid alpha(@theme_fg_color, 0.15);
    }

    .luma-pattern-cell {
        padding: 3px 10px;
        border: 1px solid alpha(@theme_fg_color, 0.08);
    }

    .luma-hex-selection {
        background-color: alpha(@accent_bg_color, 0.3);
    }

    .luma-hex-caret {
        background-color: alpha(@accent_bg_color, 0.6);
    }

    .luma-wordmark {
        font-family: sans-serif;
        font-size: 64px;
        font-weight: 600;
        letter-spacing: -2px;
        color: #EF6456;
    }
    .luma-wordmark.is-dark {
        color: #EDE6E1;
    }

    .luma-welcome-sponsor {
        padding: 0;
        min-height: 0;
        background: none;
        border: none;
        box-shadow: none;
    }
    .luma-welcome-sponsor:hover {
        background: none;
    }
    .luma-welcome-sponsor-label {
        color: alpha(@window_fg_color, 0.55);
        font-weight: 500;
    }

    .luma-welcome-actions row {
        padding: 8px 6px;
    }

    .luma-wordmark-trail {
        min-height: 1.5px;
        min-width: 200px;
        background-image: linear-gradient(to right,
            alpha(#EF6456, 0.0) 0%,
            alpha(#EF6456, 0.55) 50%,
            alpha(#EF6456, 0.0) 100%);
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
    .luma-cfg-reg-changed { color: var(--accent-color); font-weight: bold; }

    .luma-js-expander {
        margin: 0;
        padding: 0;
    }
    .luma-js-expander > box > title {
        padding: 0;
        margin: 0;
        min-height: 0;
    }
    .luma-js-expander > box > title > expander {
        min-width: 0;
        min-height: 0;
        -gtk-icon-size: 12px;
        margin: 0 0 0 -3px;
        opacity: 0.5;
    }
    .luma-js-expander > box > title > expander:checked {
        margin-left: -1px;
    }

    expander title {
        border-radius: 6px;
        padding: 2px 6px;
        margin: 0 8px;
    }
    expander title:hover {
        background: alpha(@theme_fg_color, 0.05);
    }

    button.luma-link {
        background: none;
        border: none;
        box-shadow: none;
        padding: 0;
        min-height: 0;
        color: \(accentColor);
    }
    button.luma-link:hover {
        background: none;
    }
    button.luma-link > label {
        text-decoration: underline;
        font-weight: normal;
    }

    .luma-session-icon {
        border-radius: 4px;
        box-shadow: inset 0 0 0 1px alpha(@accent_bg_color, 0.4);
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

    .luma-pid-badge {
        border-radius: 4px;
        padding: 1px 6px;
        background-color: alpha(@theme_fg_color, 0.12);
        color: alpha(@theme_fg_color, 0.75);
    }

    popover button.luma-menu-destructive {
        color: \(errorColor);
        font-weight: normal;
        padding: 6px 12px;
        min-height: 0;
        margin: 0;
    }
    popover button.luma-menu-destructive:hover {
        background-color: alpha(\(errorColor), 0.12);
    }
    popover button.luma-menu-destructive:active {
        background-color: alpha(\(errorColor), 0.22);
    }
    popover button.luma-menu-destructive label {
        padding-left: 0;
    }

    .luma-widget-box {
        background-color: alpha(@window_fg_color, 0.035);
        border-radius: 8px;
    }
    label.luma-widget-title {
        font-size: 11px;
    }
    label.luma-widget-empty {
        font-size: 10px;
    }
    label.luma-counter-value {
        font-size: 28px;
        font-weight: 600;
    }
    label.luma-counter-unit {
        font-size: 13px;
    }
    label.luma-counter-delta {
        font-size: 10px;
    }
    label.luma-list-title {
        font-size: 13px;
    }
    label.luma-list-detail {
        font-size: 10px;
    }
    label.luma-table-text {
        font-family: monospace;
        font-size: 10px;
    }
    box.luma-table-header {
        min-height: 15px;
        padding: 2px 0;
        border-bottom: 1px solid alpha(@window_fg_color, 0.12);
    }
    box.luma-table-row {
        min-height: 15px;
        padding: 2px 0;
        border-bottom: 1px solid alpha(@window_fg_color, 0.05);
    }
    box.luma-table-row button.luma-widget-action {
        margin: -1px 0;
    }
    label.luma-chart-legend {
        font-size: 10px;
    }
    .luma-widget-console label.monospace,
    .luma-widget-console .monospace label {
        font-size: 10px;
    }
    .luma-widget-console label.luma-console-prompt {
        font-size: 13px;
    }
    .luma-widget-console entry {
        font-family: inherit;
        font-size: 13px;
        min-height: 24px;
    }
    .luma-widget-console button.suggested-action {
        min-height: 24px;
        padding-top: 0;
        padding-bottom: 0;
        font-weight: normal;
    }
    button.luma-widget-action,
    menubutton.luma-widget-action > button {
        min-height: 0;
        min-width: 0;
        min-height: 14px;
        padding: 1px 6px;
        border-radius: 4px;
        font-size: 11px;
        font-weight: normal;
        color: @accent_color;
        background-color: alpha(@accent_bg_color, 0.1);
        box-shadow: none;
    }
    button.luma-widget-action:hover,
    menubutton.luma-widget-action > button:hover {
        background-color: alpha(@accent_bg_color, 0.18);
    }
    button.luma-widget-action:active,
    menubutton.luma-widget-action > button:active,
    menubutton.luma-widget-action > button:checked {
        background-color: alpha(@accent_bg_color, 0.3);
    }
    button.luma-widget-action:disabled,
    menubutton.luma-widget-action > button:disabled {
        color: alpha(@theme_fg_color, 0.45);
        background-color: alpha(@theme_fg_color, 0.06);
    }
    menubutton.luma-widget-action > button image {
        -gtk-icon-size: 12px;
    }

    .luma-context-menu button.luma-menu-item {
        padding: 7px 14px;
        min-height: 0;
        font-weight: normal;
        border-radius: 6px;
        margin: 1px 0;
    }
    .luma-context-menu separator {
        margin: 4px 6px;
        min-height: 1px;
        background-color: alpha(@theme_fg_color, 0.12);
    }

    button.luma-notebook-fab:not(.suggested-action) {
        background-color: mix(@window_bg_color, @window_fg_color, 0.16);
    }
    button.luma-notebook-fab:not(.suggested-action):hover {
        background-color: mix(@window_bg_color, @window_fg_color, 0.22);
    }

    button.luma-fab {
        min-height: 0;
        padding: 6px 18px;
    }

    button.luma-gadget-offer {
        min-height: 0;
        padding: 3px 12px;
    }

    button.luma-pharo-inline-save {
        min-height: 0;
        min-width: 0;
        padding: 0 4px;
        border: none;
        border-spacing: 0;
        outline: none;
        font-size: 0.8em;
    }
    button.luma-pharo-inline-save label {
        margin: 0;
        padding: 0;
    }

    avatar.luma-editor-avatar {
        box-shadow: 0 0 0 2px @theme_base_color;
    }

    .luma-chat-bubble-local { background-color: alpha(@accent_bg_color, 0.20); border-radius: 12px; padding: 6px 10px; }
    .luma-chat-bubble-remote { background-color: alpha(@theme_fg_color, 0.08); border-radius: 12px; padding: 6px 10px; }
    .luma-invite-frame { border: 1px solid alpha(@theme_fg_color, 0.15); border-radius: 6px; padding: 8px 12px; }
    .luma-linked-lab-hint { border: 1px solid alpha(@theme_fg_color, 0.15); border-radius: 6px; padding: 6px 10px; }

    button.luma-avatar-button {
        padding: 0;
        min-width: 0;
        min-height: 0;
        border-radius: 999px;
        background: none;
    }
    button.luma-avatar-button:hover {
        background-color: alpha(@theme_fg_color, 0.08);
    }

    .luma-member-dot {
        min-width: 8px;
        min-height: 8px;
        margin: 2px;
        border-radius: 50%;
        box-shadow: 0 0 0 2px @theme_base_color;
    }
    .luma-member-dot.online {
        background-color: @success_bg_color;
    }
    .luma-member-dot.offline {
        background-color: alpha(@theme_fg_color, 0.4);
    }
    .luma-alarm-dot {
        min-width: 8px;
        min-height: 8px;
        margin: 4px;
        border-radius: 50%;
        background-color: @error_bg_color;
        box-shadow: 0 0 0 2px @window_bg_color;
    }
    .luma-machine-log {
        font-size: 0.8em;
    }
    .luma-member-owner-badge {
        color: \(accentColor);
        min-width: 12px;
        min-height: 12px;
        background-color: @theme_base_color;
        border-radius: 50%;
        padding: 1px;
    }

    .luma-mission-pill {
        background-color: alpha(currentColor, 0.18);
        border-radius: 999px;
        padding: 1px 8px;
        margin: 0;
    }

    .card.luma-mission-card {
        border-radius: 10px;
        background-clip: padding-box;
    }
    .card.luma-mission-card-assistant {
        background-color: alpha(@accent_bg_color, 0.07);
        border: 1px solid alpha(@accent_bg_color, 0.30);
    }
    .card.luma-mission-card-user {
        background-color: alpha(#9c5cd0, 0.08);
        border: 1px solid alpha(#9c5cd0, 0.32);
    }
    .card.luma-mission-card-tool {
        background-color: alpha(#e58a1f, 0.07);
        border: 1px solid alpha(#e58a1f, 0.32);
    }

    .luma-mission-tool-use {
        padding: 6px 8px;
        border-radius: 8px;
        background-color: alpha(@theme_fg_color, 0.04);
    }

    label.luma-mission-code {
        background-color: alpha(@theme_fg_color, 0.06);
        border-radius: 6px;
        padding: 6px 8px;
        font-family: monospace;
    }

    .card.luma-mission-queue-card {
        border-radius: 10px;
        background-color: alpha(@theme_fg_color, 0.04);
        border: 1px solid alpha(@theme_fg_color, 0.12);
    }

    .card.luma-mission-queue-input-card {
        border-radius: 10px;
        background-color: alpha(@accent_bg_color, 0.08);
        border: 1px solid alpha(@accent_bg_color, 0.40);
    }

    .card.luma-mission-finding-card {
        border-radius: 10px;
        background-color: alpha(@theme_fg_color, 0.04);
        border: 1px solid alpha(@theme_fg_color, 0.12);
    }

    .luma-mission-input-bar {
        border-top: 1px solid alpha(@theme_fg_color, 0.18);
        background-color: @theme_bg_color;
    }

    button.luma-itrace-pill {
        padding: 1px 8px;
        min-height: 0;
        border-radius: 999px;
        background-color: alpha(@theme_fg_color, 0.10);
        color: alpha(@theme_fg_color, 0.65);
    }
    button.luma-itrace-pill:hover {
        background-color: alpha(@theme_fg_color, 0.16);
    }
    button.luma-itrace-pill.luma-itrace-pill-on {
        background-color: alpha(@accent_bg_color, 0.18);
        color: \(accentColor);
    }
    button.luma-itrace-pill.luma-itrace-pill-on:hover {
        background-color: alpha(@accent_bg_color, 0.28);
    }
    button.luma-pharo-strip {
        min-width: 22px;
        min-height: 12px;
        padding: 0;
        margin: 0;
        border: none;
        border-radius: 2px;
        background-color: alpha(@window_fg_color, 0.22);
        box-shadow: none;
    }
    button.luma-pharo-strip:hover {
        background-color: rgba(239, 100, 86, 0.4);
    }
    button.luma-pharo-strip.current {
        background-color: rgba(239, 100, 86, 0.75);
    }
    button.luma-pharo-miniature {
        min-width: 22px;
        min-height: 26px;
        padding: 0;
        margin: 0;
        border: none;
        border-radius: 3px;
        background-color: alpha(@window_fg_color, 0.28);
        box-shadow: none;
    }
    button.luma-pharo-miniature:hover {
        background-color: rgb(239, 100, 86);
    }
    box.luma-pharo-connector {
        background-color: alpha(@window_fg_color, 0.4);
    }
    list.luma-pharo-table {
        padding: 0;
    }
    list.luma-pharo-table > row {
        padding: 0;
        min-height: 0;
    }
    list.luma-pharo-table > row,
    box.luma-pharo-table-header {
        margin-left: 6px;
        margin-right: 6px;
    }
    box.luma-layout-page {
        background-color: alpha(@window_fg_color, 0.035);
        border-radius: 8px;
    }
    box.luma-layout-page-line {
        border-top: 1px dashed @warning_color;
    }
    button.luma-layout-box,
    button.luma-layout-container {
        min-height: 0;
        min-width: 0;
        padding: 2px 6px;
        border-radius: 6px;
        box-shadow: none;
        font-weight: normal;
    }
    button.luma-layout-box {
        background-color: alpha(@accent_bg_color, 0.12);
        border: 1px solid alpha(@accent_bg_color, 0.35);
    }
    button.luma-layout-box:hover {
        background-color: alpha(@accent_bg_color, 0.2);
    }
    button.luma-layout-container {
        background: none;
        border: 1px dashed alpha(@window_fg_color, 0.35);
    }
    button.luma-layout-container.luma-layout-folded {
        border-color: @warning_color;
    }
    button.luma-layout-box.luma-layout-selected,
    button.luma-layout-container.luma-layout-selected {
        border: 2px solid @accent_color;
    }
    label.luma-layout-tag {
        font-size: 10px;
    }
    listview.luma-widget-rows {
        background: none;
    }
    scrolledwindow.luma-widget-rows > scrollbar slider {
        min-height: 8px;
    }
    listview.luma-widget-rows > row {
        padding: 0;
    }
    label.luma-pharo-tag {
        color: alpha(@window_fg_color, 0.7);
        background-color: alpha(@window_fg_color, 0.12);
        border-radius: 6px;
        padding: 1px 6px;
    }
    box.luma-pharo-maximized {
        background-color: @window_bg_color;
    }
    .luma-pharo-canvas-engaged {
        outline: 2px solid alpha(@accent_color, 0.5);
        outline-offset: -2px;
    }
    box.luma-pharo-body {
        margin: 2px 0;
        border: 1px solid alpha(@window_fg_color, 0.15);
        border-radius: 6px;
        background-color: alpha(@window_fg_color, 0.03);
    }
    box.luma-pharo-class-body {
        margin: 2px 0;
    }
    box.luma-approval-scrim {
        background-color: alpha(black, 0.35);
    }
    box.luma-approval-card {
        padding: 20px;
    }
    box.luma-drop-zone {
        border: 2px dashed \(accentColor);
        border-radius: 12px;
        background-color: alpha(@window_bg_color, 0.92);
        background-image: linear-gradient(alpha(@accent_bg_color, 0.12), alpha(@accent_bg_color, 0.12));
        color: \(accentColor);
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

    private static func adwaitaColor(_ name: String) -> String {
        adw_get_minor_version() >= 6 ? "var(--\(name)-color)" : "@\(name)_color"
    }
}
