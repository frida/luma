import CGtk
import Gtk
import LumaCore

@MainActor
final class RevealingText {
    let widget: Box

    private let styled: StyledText
    private var reveal: TextReveal
    private let label: Label
    private let buttonRow: Box
    private let onExpand: () -> Void

    init(_ styled: StyledText, allowance: TextReveal.Allowance, wraps: Bool, onExpand: @escaping () -> Void = {}) {
        self.styled = styled
        self.reveal = TextReveal(styled.plainText, allowance: allowance)
        self.onExpand = onExpand

        widget = Box(orientation: .vertical, spacing: 2)
        widget.hexpand = true
        widget.valign = .start

        label = Label(str: "")
        label.add(cssClass: "monospace")
        label.useMarkup = true
        label.wrap = wraps
        label.halign = wraps ? .fill : .start
        label.hexpand = wraps
        label.xalign = 0
        label.selectable = true

        if wraps {
            widget.append(child: label)
        } else {
            let scroll = ScrolledWindow()
            scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .never)
            scroll.propagateNaturalHeight = true
            scroll.hexpand = true
            scroll.vexpand = false
            scroll.valign = .start
            scroll.set(child: label)
            widget.append(child: scroll)
        }

        let moreButton = Self.makeLinkButton("Show more")
        let allButton = Self.makeLinkButton("Show all")

        buttonRow = Box(orientation: .horizontal, spacing: 12)
        buttonRow.halign = .start
        buttonRow.append(child: moreButton)
        buttonRow.append(child: allButton)
        widget.append(child: buttonRow)

        moreButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.revealMore() }
        }
        allButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.revealAll() }
        }

        render()
    }

    private static func makeLinkButton(_ title: String) -> Button {
        let button = Button(label: title)
        button.add(cssClass: "luma-link")
        button.add(cssClass: "caption")
        return button
    }

    private func revealMore() {
        reveal.revealMore()
        render()
        onExpand()
    }

    private func revealAll() {
        reveal.revealAll()
        render()
        onExpand()
    }

    private func render() {
        label.setMarkup(str: StyledTextPango.markup(for: styled.slice(charRange: 0..<reveal.revealed)))
        buttonRow.visible = !reveal.isComplete
    }
}
