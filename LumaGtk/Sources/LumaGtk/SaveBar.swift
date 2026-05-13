import Gtk

@MainActor
final class SaveBar {
    let widget: Revealer

    init(saveTooltip: String, onSave: @escaping () -> Void) {
        widget = Revealer()
        widget.transitionType = .slideDown
        widget.transitionDuration = 200
        widget.revealChild = false
        widget.halign = .end
        widget.valign = .start
        widget.marginEnd = 16

        let bar = Box(orientation: .horizontal, spacing: 8)
        bar.add(cssClass: "osd")
        bar.add(cssClass: "luma-save-bar")
        bar.marginStart = 12
        bar.marginEnd = 12
        bar.marginTop = 6
        bar.marginBottom = 6

        let dot = Gtk.Image(iconName: "media-record-symbolic")
        dot.pixelSize = 10
        dot.add(cssClass: "accent")
        bar.append(child: dot)

        let label = Label(str: "Unsaved")
        label.add(cssClass: "dim-label")
        bar.append(child: label)

        let saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.tooltipText = saveTooltip
        saveButton.onClicked { _ in
            MainActor.assumeIsolated { onSave() }
        }
        bar.append(child: saveButton)

        widget.set(child: bar)
    }

    func setDirty(_ dirty: Bool) {
        widget.revealChild = dirty
    }
}
