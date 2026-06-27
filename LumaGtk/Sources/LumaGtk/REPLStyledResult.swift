import CGtk
import Gtk
import LumaCore

/// Renders an r2/text REPL result: a non-wrapping, horizontally scrollable
/// view of styled text, revealed in chunks so a huge output doesn't build
/// one enormous label up front.
@MainActor
final class REPLStyledResult {
    let widget: Box

    private let styled: StyledText
    private let total: Int
    private var revealed: Int
    private let label: Label
    private let buttonRow: Box
    private let onExpand: () -> Void

    private static let chunk = 4096

    init(_ styled: StyledText, onExpand: @escaping () -> Void) {
        self.styled = styled
        self.total = styled.plainText.count
        self.revealed = min(Self.chunk, total)
        self.onExpand = onExpand

        widget = Box(orientation: .vertical, spacing: 2)
        widget.hexpand = true
        widget.valign = .start

        label = Label(str: "")
        label.add(cssClass: "monospace")
        label.useMarkup = true
        label.wrap = false
        label.halign = .start
        label.xalign = 0
        label.selectable = true

        let scroll = ScrolledWindow()
        scroll.setPolicy(hscrollbarPolicy: GTK_POLICY_AUTOMATIC, vscrollbarPolicy: GTK_POLICY_NEVER)
        scroll.propagateNaturalHeight = true
        scroll.hexpand = true
        scroll.vexpand = false
        scroll.valign = .start
        scroll.set(child: label)
        widget.append(child: scroll)

        let moreButton = Button(label: "Show more")
        moreButton.hasFrame = false
        moreButton.add(cssClass: "flat")
        let allButton = Button(label: "Show all")
        allButton.hasFrame = false
        allButton.add(cssClass: "flat")

        buttonRow = Box(orientation: .horizontal, spacing: 8)
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

    private func revealMore() {
        revealed = min(revealed + Self.chunk, total)
        render()
        onExpand()
    }

    private func revealAll() {
        revealed = total
        render()
        onExpand()
    }

    private func render() {
        label.setMarkup(str: StyledTextPango.markup(for: styled.slice(charRange: 0..<revealed)))
        buttonRow.visible = revealed < total
    }
}
