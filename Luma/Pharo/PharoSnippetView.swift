import SwiftUI

/// A piece of Smalltalk on a page, sized to what it holds. Its actions stay out
/// of the way until the pointer is over it, so a page of snippets reads as
/// code rather than as a stack of controls.
struct PharoSnippetView: View {
    @Binding var source: String
    let evaluate: () -> Void
    let inspect: (() -> Void)?
    let remove: (() -> Void)?

    @State private var isPointedAt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            editor
            actions
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isPointedAt = $0 }
    }

    private var editor: some View {
        TextField("", text: $source, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1...)
            .padding(8)
            .accessibilityIdentifier("notebook.pharo.source")
            .onSubmit(evaluate)
    }

    @ViewBuilder
    private var actions: some View {
        if isPointedAt {
            HStack(spacing: 2) {
                action("play.fill", "Evaluate", evaluate)
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
        }
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
}
