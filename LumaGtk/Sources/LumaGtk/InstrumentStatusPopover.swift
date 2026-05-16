import Gtk
import LumaCore

@MainActor
enum InstrumentStatusPopover {
    static func makeIndicator(status: InstrumentStatus) -> MenuButton {
        let menuButton = MenuButton()
        menuButton.iconName = status.gtkIconName
        menuButton.hasFrame = false
        menuButton.tooltipText = status.summary
        menuButton.add(cssClass: "luma-instrument-status")
        menuButton.set(popover: makePopover(status: status))
        return menuButton
    }

    private static func makePopover(status: InstrumentStatus) -> Popover {
        let popover = Popover()
        popover.position = .bottom

        let column = Box(orientation: .vertical, spacing: 8)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12
        column.halign = .start
        column.valign = .start

        let header = Box(orientation: .horizontal, spacing: 6)
        let icon = Gtk.Image(iconName: status.gtkIconName)
        icon.pixelSize = 14
        header.append(child: icon)
        let headline = Label(str: status.headline)
        headline.halign = .start
        headline.add(cssClass: "title-4")
        header.append(child: headline)
        column.append(child: header)

        if status.summary != status.headline {
            let summary = Label(str: status.summary)
            summary.halign = .start
            summary.wrap = true
            summary.selectable = true
            summary.canFocus = false
            summary.xalign = 0
            column.append(child: summary)
        }

        if let stack = status.stack, !stack.isEmpty {
            column.append(child: Separator(orientation: .horizontal))

            let scroll = ScrolledWindow()
            scroll.propagateNaturalWidth = true
            scroll.propagateNaturalHeight = true
            scroll.maxContentWidth = 960
            scroll.maxContentHeight = 480
            scroll.halign = .start
            scroll.valign = .start
            scroll.setPolicy(
                hscrollbarPolicy: PolicyType.automatic,
                vscrollbarPolicy: PolicyType.automatic
            )

            let body = Label(str: stack)
            body.halign = .start
            body.valign = .start
            body.selectable = true
            body.canFocus = false
            body.xalign = 0
            body.wrap = false
            body.add(cssClass: "monospace")
            scroll.set(child: body)
            column.append(child: scroll)
        }

        popover.set(child: column)
        return popover
    }
}

extension InstrumentStatus {
    var headline: String {
        switch self {
        case .incompatible: return "Incompatible"
        case .loadFailed: return "Failed to load"
        case .reloadFailed: return "Failed to reload"
        case .configInvalid: return "Compilation failed"
        }
    }
}
