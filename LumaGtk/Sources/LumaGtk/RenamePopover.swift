import Gtk

@MainActor
enum RenamePopover {
    static func present(heading: String, title: String, at anchor: Widget, onCommit: @escaping (String) -> Void) {
        let popover = Popover()
        popover.autohide = true
        popover.position = .bottom
        popover.set(parent: anchor)
        popover.onClosed { _ in MainActor.assumeIsolated { popover.unparent() } }

        let column = Box(orientation: .vertical, spacing: 8)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12

        let headingLabel = Label(str: heading)
        headingLabel.add(cssClass: "heading")
        headingLabel.halign = .start
        headingLabel.xalign = 0
        column.append(child: headingLabel)

        let entry = Entry()
        entry.text = title
        entry.placeholderText = "Title"
        entry.widthChars = 28
        column.append(child: entry)

        let buttonRow = Box(orientation: .horizontal, spacing: 6)
        buttonRow.halign = .end

        let cancelBtn = Button(label: "Cancel")
        cancelBtn.add(cssClass: "flat")
        cancelBtn.onClicked { _ in
            MainActor.assumeIsolated { popover.popdown() }
        }
        buttonRow.append(child: cancelBtn)

        let saveBtn = Button(label: "Save")
        saveBtn.add(cssClass: "suggested-action")
        saveBtn.onClicked { _ in
            MainActor.assumeIsolated {
                popover.popdown()
                onCommit(entry.text)
            }
        }
        buttonRow.append(child: saveBtn)

        entry.onActivate { _ in
            MainActor.assumeIsolated {
                popover.popdown()
                onCommit(entry.text)
            }
        }

        column.append(child: buttonRow)
        popover.set(child: column)
        popover.popup()
        _ = entry.grabFocus()
    }
}
