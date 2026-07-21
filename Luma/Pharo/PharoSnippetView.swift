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
    let evaluate: () -> Void
    let inspect: (() -> Void)?
    let remove: (() -> Void)?

    @State private var isPointedAt = false
    @State private var expanded: [String] = []
    @State private var expandedClasses: [String: PharoObject] = [:]

    var body: some View {
        HStack(spacing: 0) {
            focusBar

            VStack(alignment: .leading, spacing: 0) {
                editor
                expansions
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
        PharoSourceEditor(
            id: id,
            source: $source,
            focused: $focused,
            runtime: runtime,
            expanded: Set(expanded),
            onToggle: toggle)
        .padding(4)
        .accessibilityIdentifier("notebook.pharo.source")
    }

    /// A class the reader opened stays open under the snippet, so the code and
    /// what it names are readable together.
    private var expansions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(expanded, id: \.self) { name in
                if let object = expandedClasses[name] {
                    PharoInspectorView(runtime: runtime, root: object) { toggle(name) }
                        .frame(height: 260)
                        .pharoPane()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, expanded.isEmpty ? 0 : 6)
    }

    private func toggle(_ name: String) {
        guard !expanded.contains(name) else {
            expanded.removeAll { $0 == name }
            return
        }

        expanded.append(name)
        Task { expandedClasses[name] = try? await runtime.evaluate(name) }
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
