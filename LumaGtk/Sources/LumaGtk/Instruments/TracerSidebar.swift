import Foundation
import Gtk
import LumaCore

@MainActor
enum TracerSidebar {
    static let inlineLimit = 5
    static let rowMarginStart = 64

    static func makeHookRow(hook: TracerConfig.Hook) -> (row: ListBoxRow, anchor: Box) {
        let row = ListBoxRow()
        let (rowBox, iconHost) = makeGrandchildRowBox()
        iconHost.append(child: makeHookKindIcon(kind: hook.kind))
        let label = Label(str: hook.displayName)
        label.halign = .start
        label.ellipsize = .end
        rowBox.append(child: label)
        if hook.state == .disabled {
            rowBox.opacity = 0.5
        }
        rowBox.tooltipText = hook.addressAnchor.displayString
        row.set(child: rowBox)
        return (row, rowBox)
    }

    private static func makeGrandchildRowBox() -> (rowBox: Box, iconHost: Box) {
        let rowBox = Box(orientation: .horizontal, spacing: 8)
        rowBox.halign = .start
        rowBox.marginStart = rowMarginStart
        rowBox.marginEnd = 12
        rowBox.marginTop = 2
        rowBox.marginBottom = 2
        let iconHost = Box(orientation: .horizontal, spacing: 0)
        iconHost.setSizeRequest(width: 24, height: -1)
        iconHost.hexpand = false
        rowBox.append(child: iconHost)
        return (rowBox, iconHost)
    }

    private static func makeHookKindIcon(kind: TracerHookKind) -> Widget {
        let label = Label(str: "")
        label.useMarkup = true
        switch kind {
        case .function:
            label.label = "<span size=\"medium\">𝑓</span>"
        case .instruction:
            label.label = "<i>i</i>"
        }
        label.hexpand = true
        label.halign = .center
        label.valign = .center
        label.add(cssClass: "dim-label")
        return label
    }

    static func makeBrowseAllRow(totalCount: Int) -> (row: ListBoxRow, anchor: Box) {
        let row = ListBoxRow()
        let (rowBox, iconHost) = makeGrandchildRowBox()
        let icon = Gtk.Image(iconName: "view-more-symbolic")
        icon.pixelSize = 12
        icon.hexpand = true
        icon.halign = .center
        icon.add(cssClass: "dim-label")
        iconHost.append(child: icon)
        let label = Label(str: "Browse all \(totalCount)\u{2026}")
        label.halign = .start
        label.add(cssClass: "dim-label")
        rowBox.append(child: label)
        row.set(child: rowBox)
        return (row, rowBox)
    }

    static func presentBrowser(
        hooks: [TracerConfig.Hook],
        anchor: Widget,
        onChoose: @escaping @MainActor (TracerConfig.Hook) -> Void
    ) {
        let browser = TracerHookBrowserPopover(hooks: hooks, onChoose: onChoose)
        browser.presentAnchored(to: anchor)
    }
}
