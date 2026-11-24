import Gtk

@MainActor
enum ConfirmationPopover {
    static func present(heading: String, destructiveLabel: String, at anchor: Widget, action: @escaping () -> Void) {
        let confirmation = Popover()
        confirmation.autohide = true
        confirmation.position = .bottom
        confirmation.set(parent: anchor)
        confirmation.onClosed { _ in MainActor.assumeIsolated { confirmation.unparent() } }

        let column = Box(orientation: .vertical, spacing: 8)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12

        let headingLabel = Label(str: heading)
        headingLabel.halign = .start
        headingLabel.xalign = 0
        headingLabel.add(cssClass: "heading")
        column.append(child: headingLabel)

        let buttonRow = Box(orientation: .horizontal, spacing: 6)
        buttonRow.halign = .end

        let cancelBtn = Button(label: "Cancel")
        cancelBtn.add(cssClass: "flat")
        cancelBtn.onClicked { _ in
            MainActor.assumeIsolated { confirmation.popdown() }
        }
        buttonRow.append(child: cancelBtn)

        let confirmBtn = Button(label: destructiveLabel)
        confirmBtn.add(cssClass: "destructive-action")
        confirmBtn.onClicked { _ in
            MainActor.assumeIsolated {
                confirmation.popdown()
                action()
            }
        }
        buttonRow.append(child: confirmBtn)
        column.append(child: buttonRow)

        confirmation.set(child: column)
        confirmation.popup()
    }
}
