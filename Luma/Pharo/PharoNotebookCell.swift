import LumaCore
import SwiftUI
import SwiftyPharo

/// A notebook entry holding Smalltalk the reader can edit and run, with the
/// result opened for inspection below it. What the last run produced is kept
/// with the entry, so the cell still shows its result with no VM around.
struct PharoNotebookCell: View {
    let entry: NotebookEntry
    let engine: Engine

    @State private var source: String
    @State private var result: PharoObject?
    @State private var snapshot: PharoSnapshot?
    @State private var failure: String?

    private let runtime = PharoRuntime.shared

    init(entry: NotebookEntry, engine: Engine) {
        self.entry = entry
        self.engine = engine
        _source = State(initialValue: entry.details)
        _snapshot = State(initialValue: entry.pharoSnapshot)
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
        } else if let snapshot {
            PharoSnapshotView(snapshot: snapshot)
                .frame(height: 260)
        }
    }

    private func evaluate() async {
        do {
            try await runtime.startBundledImage()
            let evaluated = try await runtime.evaluate(source)
            result = evaluated
            snapshot = try await PharoSnapshot.capture(of: evaluated, using: runtime)
            failure = nil
        } catch {
            result = nil
            failure = "\(error)"
        }
        save()
    }

    private func save() {
        var updated = entry
        updated.details = source
        updated.pharoSnapshot = snapshot
        engine.updateNotebookEntry(updated)
    }
}
