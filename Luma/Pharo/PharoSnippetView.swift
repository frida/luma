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
    let result: PharoObject?
    let open: (PharoObject) -> Void
    let evaluate: () -> Void
    let inspect: (() -> Void)?
    let remove: (() -> Void)?

    @State private var isPointedAt = false
    @State private var openedClasses: [String: PharoObject] = [:]

    var body: some View {
        HStack(spacing: 0) {
            focusBar

            VStack(alignment: .leading, spacing: 0) {
                editor
                openedClassesView
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
            marks: marks,
            onToggleClass: toggle,
            onOpen: open)
        .padding(4)
        .accessibilityIdentifier("notebook.pharo.source")
    }

    /// An opened class renders here rather than in the text: NSTextView only
    /// instantiates an attachment's view at the layout where the attachment is
    /// first present, so one that appears on a later click stays a blank
    /// placeholder. The toggle in the text still says which classes are open.
    private var openedClassesView: some View {
        ForEach(Array(openedClasses.keys).sorted(), id: \.self) { name in
            if let object = openedClasses[name] {
                PharoObjectColumn(
                    runtime: runtime,
                    object: object,
                    onSelect: open,
                    onClose: { toggle(name) })
                .pharoPane()
                .frame(height: 260)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
        }
    }

    private var marks: PharoSnippetMarks {
        PharoSnippetMarks(openedClassNames: Set(openedClasses.keys), result: result)
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
