import SwiftUI

struct WidgetFilterField: View {
    @Binding var text: String
    let rowsFocus: WidgetRowsFocus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onSubmit(rowsFocus.focus)
                .onKeyPress(.downArrow) {
                    rowsFocus.focus()
                    return .handled
                }
                .onKeyPress(.escape) {
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filter")
            }
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .frame(maxWidth: 160, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }
}
