import SwiftUI

/// What the image said went wrong, laid out like the content it stands in for
/// so a pane keeps its shape instead of collapsing to centred text.
struct PharoFailureView: View {
    let message: String

    var body: some View {
        ScrollView {
            Text(message)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
