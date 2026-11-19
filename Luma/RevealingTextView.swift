import LumaCore
import SwiftUI

struct RevealingTextView: View {
    let styled: LumaCore.StyledText
    let wraps: Bool

    @State private var reveal: TextReveal
    @Environment(\.replExpandAction) private var onExpand

    init(styled: LumaCore.StyledText, allowance: TextReveal.Allowance, wraps: Bool) {
        self.styled = styled
        self.wraps = wraps
        _reveal = State(initialValue: TextReveal(styled.plainText, allowance: allowance))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if wraps {
                text
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    text.fixedSize(horizontal: true, vertical: true)
                }
            }
            if !reveal.isComplete {
                HStack(spacing: 12) {
                    Button("Show more") { reveal.revealMore(); onExpand() }
                    Button("Show all") { reveal.revealAll(); onExpand() }
                }
                .font(.caption2)
                .platformLinkButtonStyle()
            }
        }
    }

    private var text: some View {
        Text(styled.slice(charRange: 0..<reveal.revealed).attributed)
            .textSelection(.enabled)
    }
}
