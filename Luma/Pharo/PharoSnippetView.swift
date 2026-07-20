import SwiftUI

/// A piece of Smalltalk on a page, sized to what it holds. Its actions stay in
/// place whether or not they are showing, so a page does not shift under the
/// pointer as snippets take and lose focus.
struct PharoSnippetView: View {
    @Binding var source: String
    let evaluate: () -> Void
    let inspect: (() -> Void)?
    let remove: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var isPointedAt = false

    var body: some View {
        HStack(spacing: 0) {
            focusBar

            VStack(alignment: .leading, spacing: 0) {
                editor
                actions
            }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isPointedAt = $0 }
    }

    private var focusBar: some View {
        Rectangle()
            .fill(isFocused ? Color.accentColor : .clear)
            .frame(width: 3)
    }

    private var editor: some View {
        TextField("", text: $source, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1...)
            .padding(8)
            .focused($isFocused)
            .accessibilityIdentifier("notebook.pharo.source")
    }

    private var actions: some View {
        HStack(spacing: 2) {
            action("play.fill", "Evaluate", evaluate)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("notebook.pharo.evaluate")

            if let inspect {
                action("arrow.right", "Inspect", inspect)
                    .accessibilityIdentifier("notebook.pharo.inspect")
            }

            Spacer()

            if let remove {
                action("trash", "Remove", remove)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
    }

    private func action(_ symbol: String, _ name: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.caption)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(name)
    }

    private var showsActions: Bool {
        isFocused || isPointedAt
    }
}
