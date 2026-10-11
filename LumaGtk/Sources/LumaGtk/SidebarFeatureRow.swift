import Foundation
import Gtk
import LumaCore

@MainActor
enum SidebarFeatureRow {
    static let rowMarginStart = MainWindow.sessionGrandchildMarginStart

    struct Disclosure {
        let expansion: SidebarExpansion
        let onToggle: @MainActor () -> Void
    }

    static func make(
        icon: Widget,
        title: String,
        titleDimmed: Bool = false,
        dimmed: Bool = false,
        tooltip: String? = nil,
        accessory: Widget? = nil,
        depth: Int = 0,
        disclosure: Disclosure? = nil
    ) -> (row: ListBoxRow, anchor: Box) {
        let row = ListBoxRow()
        let (rowBox, iconHost) = makeGrandchildRowBox(depth: depth, disclosure: disclosure)
        iconHost.append(child: icon)
        let label = Label(str: title)
        label.halign = .start
        label.ellipsize = .end
        if titleDimmed {
            label.add(cssClass: "dim-label")
        }
        rowBox.append(child: label)
        if let accessory {
            rowBox.append(child: accessory)
        }
        if dimmed {
            rowBox.opacity = 0.5
        }
        rowBox.tooltipText = tooltip
        row.set(child: rowBox)
        return (row, rowBox)
    }

    static func makeBrowseAll(totalCount: Int, depth: Int = 0) -> (row: ListBoxRow, anchor: Box) {
        let icon = Gtk.Image(iconName: "view-more-symbolic")
        icon.pixelSize = 12
        icon.hexpand = true
        icon.halign = .center
        icon.add(cssClass: "dim-label")
        let result = make(icon: icon, title: "Browse all \(totalCount)\u{2026}", titleDimmed: true, depth: depth)
        result.row.selectable = false
        return result
    }

    static func makeCount(_ count: Int) -> Label {
        let label = Label(str: "\(count)")
        label.add(cssClass: "dim-label")
        label.add(cssClass: "caption")
        return label
    }

    private static let iconColumnWidth = 16
    private static let chevronColumnWidth = 16
    private static let spacing = 6

    private static func makeGrandchildRowBox(depth: Int, disclosure: Disclosure?) -> (rowBox: Box, iconHost: Box) {
        let rowBox = Box(orientation: .horizontal, spacing: spacing)
        rowBox.halign = .start
        rowBox.marginStart = rowMarginStart + depth * iconColumnWidth
        rowBox.marginEnd = 12
        rowBox.marginTop = 2
        rowBox.marginBottom = 2
        if let disclosure {
            rowBox.marginStart -= chevronColumnWidth + spacing
            rowBox.append(child: makeChevron(disclosure))
        }
        let iconHost = Box(orientation: .horizontal, spacing: 0)
        iconHost.setSizeRequest(width: 16, height: -1)
        iconHost.hexpand = false
        rowBox.append(child: iconHost)
        return (rowBox, iconHost)
    }

    private static func makeChevron(_ disclosure: Disclosure) -> Button {
        let image = Gtk.Image(iconName: disclosure.expansion == .expanded ? "pan-down-symbolic" : "pan-end-symbolic")
        image.pixelSize = 12
        image.add(cssClass: "dim-label")
        let button = Button()
        button.set(child: image)
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-sidebar-chevron")
        button.valign = .center
        button.setSizeRequest(width: chevronColumnWidth, height: -1)
        let onToggle = disclosure.onToggle
        button.onClicked { _ in
            MainActor.assumeIsolated { onToggle() }
        }
        return button
    }
}
