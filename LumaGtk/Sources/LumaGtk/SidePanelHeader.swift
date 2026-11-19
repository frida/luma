import Gtk

@MainActor
enum SidePanelHeader {
    static func make(title: String, accessory: Widget? = nil, onClose: @escaping () -> Void) -> Box {
        let header = Box(orientation: .horizontal, spacing: 8)

        let heading = Label(str: title)
        heading.add(cssClass: "title-4")
        heading.xalign = 0
        heading.hexpand = true
        header.append(child: heading)

        if let accessory {
            header.append(child: accessory)
        }

        let close = Button(iconName: "window-close-symbolic")
        close.add(cssClass: "flat")
        close.tooltipText = "Close"
        close.onClicked { _ in
            MainActor.assumeIsolated { onClose() }
        }
        header.append(child: close)

        return header
    }
}
