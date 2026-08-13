import SwiftUI
import SwiftyPharo

/// A piece of Smalltalk on a page, sized to what it holds. Its actions stay in
/// place whether or not they are showing, so a page does not shift under the
/// pointer as snippets take and lose focus.
/// The three ways to run a snippet, the way Glamorous Toolkit offers them: run
/// it, run it and leave the print string beside it, or run it and open the
/// result in the inspector.
enum PharoRunMode {
    case evaluate
    case print
    case inspect
}

struct PharoSnippetView: View {
    let id: UUID
    @Binding var source: String
    @Binding var focused: UUID?
    let runtime: PharoRuntime
    let open: (PharoObject) -> Void
    let openResult: (() -> Void)?
    let evaluate: () -> Void
    let printIt: () -> Void
    let evaluateAndInspect: () -> Void
    let format: () -> Void
    let remove: (() -> Void)?
    var error: PharoEvaluationError? = nil
    var printString: String? = nil
    var isEvaluating: Bool = false

    @State private var isPointedAt = false
    @State private var showsSpinner = false
    @State private var openedClasses: [String: PharoObject] = [:]

    var body: some View {
        HStack(spacing: 0) {
            focusBar

            VStack(alignment: .leading, spacing: 0) {
                editor
                if let printString {
                    printResult(printString)
                }
                actions
            }
        }
        .background(.pharoPane)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary)
        }
        // Print it has no button, only a key, the way GT leaves it off the
        // toolbar; the hidden control gives the shortcut somewhere to live.
        .background {
            Button("Print it", action: printIt)
                .keyboardShortcut(shortcut(.init("p"), when: isFocused && !isEvaluating))
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // Format has no button either, only a key, the way GT keeps it off the
        // toolbar.
        .background {
            Button("Format", action: format)
                .keyboardShortcut(shortcut(.init("f"), modifiers: [.command, .shift], when: isFocused && !isEvaluating))
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onHover { isPointedAt = $0 }
    }

    private var focusBar: some View {
        Rectangle()
            .fill(isFocused ? Color.fridaBrand : .clear)
            .frame(width: 3)
    }

    /// What "Print it" leaves behind: the result's print string beside the code
    /// it came from, the way Glamorous Toolkit adorns the expression with it.
    private func printResult(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
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
            action("play.fill", "Evaluate and inspect (\u{2318}G)", loading: showsSpinner, evaluateAndInspect)
                // Only the focused snippet answers a shortcut, so the others'
                // identical bindings do not race it for the keypress.
                .keyboardShortcut(shortcut(.init("g"), when: isFocused))
                .disabled(isEvaluating)
                .accessibilityIdentifier("notebook.pharo.evaluateAndInspect")

            action("play", "Evaluate (\u{2318}D)", evaluate)
                .keyboardShortcut(shortcut(.init("d"), when: isFocused))
                .disabled(isEvaluating)
                .accessibilityIdentifier("notebook.pharo.evaluate")

            Spacer()

            examplesMenu

            if let remove {
                action("trash", "Remove", remove)
            }
        }
        // A run is often over in a blink; wait before spinning so a quick one
        // does not flash the indicator.
        .task(id: isEvaluating) {
            showsSpinner = false
            guard isEvaluating else { return }
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled { showsSpinner = true }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
    }

    private func action(_ symbol: String, _ name: String, loading: Bool = false, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            ZStack {
                Image(systemName: symbol)
                    .font(.caption)
                    .opacity(loading ? 0 : 1)
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                }
            }
            .frame(width: 16, height: 12)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(loading ? "Evaluating\u{2026}" : name)
    }

    private var examplesMenu: some View {
        Menu {
            ForEach(PharoExampleCatalog.sections, id: \.heading) { section in
                Section(section.heading) {
                    ForEach(section.examples) { example in
                        Button(example.title) { insert(example.code) }
                    }
                }
            }
        } label: {
            Image(systemName: "sparkles").font(.caption).frame(width: 16, height: 12)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert an example")
    }

    private func insert(_ code: String) {
        source = code
        focused = id
    }

    private func shortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command, when active: Bool) -> KeyboardShortcut? {
        active ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }

    private var isFocused: Bool {
        focused == id
    }

    private var showsActions: Bool {
        isFocused || isPointedAt || showsSpinner
    }
}
