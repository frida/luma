import Foundation
import Gtk

@MainActor
enum SidebarFeatureRow {
    static let rowMarginStart = MainWindow.sessionGrandchildMarginStart

    static func make(
        icon: Widget,
        title: String,
        titleDimmed: Bool = false,
        dimmed: Bool = false,
        tooltip: String? = nil,
        accessory: Widget? = nil
    ) -> (row: ListBoxRow, anchor: Box) {
        let row = ListBoxRow()
        let (rowBox, iconHost) = makeGrandchildRowBox()
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

    static func makeBrowseAll(totalCount: Int) -> (row: ListBoxRow, anchor: Box) {
        let icon = Gtk.Image(iconName: "view-more-symbolic")
        icon.pixelSize = 12
        icon.hexpand = true
        icon.halign = .center
        icon.add(cssClass: "dim-label")
        let result = make(icon: icon, title: "Browse all \(totalCount)\u{2026}", titleDimmed: true)
        result.row.selectable = false
        return result
    }

    private static func makeGrandchildRowBox() -> (rowBox: Box, iconHost: Box) {
        let rowBox = Box(orientation: .horizontal, spacing: 6)
        rowBox.halign = .start
        rowBox.marginStart = rowMarginStart
        rowBox.marginEnd = 12
        rowBox.marginTop = 2
        rowBox.marginBottom = 2
        let iconHost = Box(orientation: .horizontal, spacing: 0)
        iconHost.setSizeRequest(width: 16, height: -1)
        iconHost.hexpand = false
        rowBox.append(child: iconHost)
        return (rowBox, iconHost)
    }
}
