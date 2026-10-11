import SwiftUI

struct DetailFilterBar<Trailing: View>: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(isFocused)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Button("") { isFocused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }
}

struct DetailFilterStatus: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.system(size: 11))
    }
}
