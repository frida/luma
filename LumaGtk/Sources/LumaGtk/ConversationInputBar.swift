import Gtk

@MainActor
final class ConversationInputBar {
    let widget: Box
    let accessory = Box(orientation: .horizontal, spacing: 6)

    struct Action {
        let iconName: String
        let tooltip: String
        var unavailableReason: String? = nil
        let run: () -> Void
    }

    private let entry: TextView
    private let errorLabel: Label
    private let secondaryButton: Button
    private let secondaryIcon: Gtk.Image
    private let primaryButton: Button
    private let primaryIcon: Gtk.Image
    private let cancelIcon: Gtk.Image
    private let spinner: Spinner
    private var primary: Action
    private var secondary: Action?
    private var isSending = false

    init(primary: Action, secondary: Action?, onStop: @escaping () -> Void) {
        self.primary = primary
        self.secondary = secondary

        widget = Box(orientation: .vertical, spacing: 4)
        widget.marginStart = 10
        widget.marginEnd = 10
        widget.marginTop = 8
        widget.marginBottom = 10

        errorLabel = Label(str: "")
        errorLabel.add(cssClass: "error")
        errorLabel.add(cssClass: "caption")
        errorLabel.halign = .start
        errorLabel.xalign = 0
        errorLabel.visible = false
        widget.append(child: errorLabel)

        let row = Box(orientation: .horizontal, spacing: 6)
        row.hexpand = true

        entry = TextView()
        entry.wrapMode = .word
        entry.topMargin = 6
        entry.bottomMargin = 6
        entry.leftMargin = 8
        entry.rightMargin = 8
        entry.acceptsTab = false

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.setSizeRequest(width: -1, height: 64)
        scroll.add(cssClass: "card")
        scroll.set(child: entry)
        row.append(child: scroll)

        let buttonColumn = Box(orientation: .vertical, spacing: 4)
        buttonColumn.valign = .end

        secondaryButton = Button()
        secondaryIcon = Gtk.Image(iconName: secondary?.iconName ?? "")
        secondaryIcon.pixelSize = 14
        secondaryButton.set(child: secondaryIcon)
        secondaryButton.add(cssClass: "flat")
        buttonColumn.append(child: secondaryButton)

        primaryButton = Button()
        primaryIcon = Gtk.Image(iconName: primary.iconName)
        primaryIcon.pixelSize = 14
        cancelIcon = Gtk.Image(iconName: "media-playback-stop-symbolic")
        cancelIcon.pixelSize = 14
        cancelIcon.visible = false
        spinner = makeSpinner()
        spinner.visible = false
        let primaryContent = Box(orientation: .horizontal, spacing: 0)
        primaryContent.append(child: primaryIcon)
        primaryContent.append(child: cancelIcon)
        primaryContent.append(child: spinner)
        primaryButton.set(child: primaryContent)
        primaryButton.add(cssClass: "suggested-action")
        buttonColumn.append(child: primaryButton)

        row.append(child: buttonColumn)
        widget.append(child: row)
        widget.append(child: accessory)

        secondaryButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.secondary?.run() }
        }
        primaryButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isSending {
                    onStop()
                } else {
                    self.primary.run()
                }
            }
        }
        offer(primary: primary, secondary: secondary)
    }

    func offer(primary: Action, secondary: Action?) {
        self.primary = primary
        self.secondary = secondary
        primaryIcon.setFrom(iconName: primary.iconName)
        secondaryButton.visible = secondary != nil
        if let secondary {
            secondaryIcon.setFrom(iconName: secondary.iconName)
        }
        showAvailability()
    }

    private func showAvailability() {
        primaryButton.sensitive = isSending || primary.unavailableReason == nil
        primaryButton.tooltipText = isSending ? "Cancel reply" : primary.unavailableReason ?? primary.tooltip
        secondaryButton.sensitive = !isSending && secondary?.unavailableReason == nil
        secondaryButton.tooltipText = secondary.map { $0.unavailableReason ?? $0.tooltip }
    }

    var draft: String {
        entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearDraft() {
        entry.buffer?.set(text: "", len: 0)
    }

    func restore(draft: String) {
        entry.buffer?.set(text: draft, len: Int(draft.utf8.count))
    }

    func focus() {
        _ = entry.grabFocus()
    }

    func show(isSending: Bool, failure: String?) {
        self.isSending = isSending
        showAvailability()
        spinner.visible = isSending
        primaryIcon.visible = !isSending
        cancelIcon.visible = isSending
        if let failure {
            errorLabel.label = failure
            errorLabel.visible = true
        } else {
            errorLabel.visible = false
        }
    }
}
