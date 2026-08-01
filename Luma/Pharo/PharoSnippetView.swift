import SwiftUI
import SwiftyPharo

/// A piece of Smalltalk on a page, sized to what it holds. Its actions stay in
/// place whether or not they are showing, so a page does not shift under the
/// pointer as snippets take and lose focus.
struct PharoSnippetView: View {
    let id: UUID
    @Binding var source: String
    @Binding var focused: UUID?
    let runtime: PharoRuntime
    let open: (PharoObject) -> Void
    let openResult: (() -> Void)?
    let evaluate: () -> Void
    let evaluateAndInspect: () -> Void
    let remove: (() -> Void)?
    var error: PharoEvaluationError? = nil
    var isEvaluating: Bool = false

    @State private var isPointedAt = false
    @State private var openedClasses: [String: PharoObject] = [:]

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
            .fill(isFocused ? Color.fridaBrand : .clear)
            .frame(width: 3)
    }

    private var editor: some View {
        PharoSourceEditor(
            id: id,
            source: $source,
            focused: $focused,
            runtime: runtime,
            marks: marks,
            onToggleClass: toggle,
            onOpen: open,
            onOpenResult: { openResult?() })
        .padding(4)
        .accessibilityIdentifier("notebook.pharo.source")
    }

    private var marks: PharoSnippetMarks {
        PharoSnippetMarks(openedClasses: openedClasses, hasResult: openResult != nil, error: error)
    }

    private func toggle(_ name: String) {
        guard openedClasses[name] == nil else {
            openedClasses[name] = nil
            return
        }

        Task { openedClasses[name] = try? await runtime.evaluate(name) }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if isEvaluating {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 12)
                    .accessibilityIdentifier("notebook.pharo.evaluating")
            } else {
                action("play.fill", "Evaluate and inspect (\u{2318}G)", evaluateAndInspect)
                    // Only the focused snippet answers a shortcut, so the others'
                    // identical bindings do not race it for the keypress.
                    .keyboardShortcut(shortcut(.init("g"), when: isFocused))
                    .accessibilityIdentifier("notebook.pharo.evaluateAndInspect")

                action("play", "Evaluate (\u{2318}D)", evaluate)
                    .keyboardShortcut(shortcut(.init("d"), when: isFocused))
                    .accessibilityIdentifier("notebook.pharo.evaluate")
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

    private func shortcut(_ key: KeyEquivalent, when active: Bool) -> KeyboardShortcut? {
        active ? KeyboardShortcut(key, modifiers: .command) : nil
    }

    private var isFocused: Bool {
        focused == id
    }

    private var showsActions: Bool {
        isFocused || isPointedAt || isEvaluating
    }
}
