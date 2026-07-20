import SwiftUI

/// A piece of Smalltalk on a page, sized to what it holds. Its actions stay in
/// place whether or not they are showing, so a page does not shift under the
/// pointer as snippets take and lose focus.
struct PharoSnippetView: View {
    let id: UUID
    @Binding var source: String
    @FocusState.Binding var focused: UUID?
    let evaluate: () -> Void
    let inspect: (() -> Void)?
    let remove: (() -> Void)?

    @State private var isPointedAt = false

    var body: some View {
        HStack(spacing: 0) {
            focusBar

            VStack(alignment: .leading, spacing: 0) {
                editor
                actions
            }
        }
        .background(.pharoPane)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary)
        }
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
            .focused($focused, equals: id)
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
                .frame(width: 16, height: 12)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(name)
    }

    private var isFocused: Bool {
        focused == id
    }

    private var showsActions: Bool {
        isFocused || isPointedAt
    }
}
