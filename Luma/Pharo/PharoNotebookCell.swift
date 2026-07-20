import LumaCore
import SwiftUI
import SwiftyPharo

/// A notebook entry holding Smalltalk the reader can edit and run, with the
/// result opened for inspection below it.
struct PharoNotebookCell: View {
    let entry: NotebookEntry
    let engine: Engine

    @State private var source: String
    @State private var result: PharoObject?
    @State private var failure: String?

    private let runtime = PharoRuntime.shared

    init(entry: NotebookEntry, engine: Engine) {
        self.entry = entry
        self.engine = engine
        _source = State(initialValue: entry.details)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 44)
                .onChange(of: source) { save() }
                .accessibilityIdentifier("notebook.pharo.source")

            HStack {
                Button("Evaluate") { Task { await evaluate() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("notebook.pharo.evaluate")
                Spacer()
            }

            outcome
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if let failure {
            Text(failure)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.red)
        } else if let result {
            PharoInspectorView(runtime: runtime, root: result)
                .frame(height: 260)
        }
    }

    private func evaluate() async {
        do {
            try await runtime.startBundledImage()
            result = try await runtime.evaluate(source)
            failure = nil
        } catch {
            result = nil
            failure = "\(error)"
        }
    }

    private func save() {
        var updated = entry
        updated.details = source
        engine.updateNotebookEntry(updated)
    }
}
