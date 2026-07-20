import LumaCore
import SwiftUI
import SwiftyPharo

/// A notebook entry holding Smalltalk the reader can edit and run. What it
/// produces opens in the page's inspection pane; what the last run captured is
/// kept with the entry, so it can be reopened with no VM around.
struct PharoNotebookCell: View {
    let entry: NotebookEntry
    let engine: Engine
    @Binding var inspection: PharoInspection?

    @State private var source: String
    @State private var snapshot: PharoSnapshot?
    @State private var failure: String?

    private let runtime = PharoRuntime.shared

    init(entry: NotebookEntry, engine: Engine, inspection: Binding<PharoInspection?>) {
        self.entry = entry
        self.engine = engine
        _inspection = inspection
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

                if let snapshot {
                    Button { inspection = .captured(snapshot) } label: {
                        Image(systemName: "arrow.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notebook.pharo.inspect")
                }
            }

            if let failure {
                PharoFailureView(message: failure)
                    .frame(height: 60)
            }
        }
    }

    private func evaluate() async {
        do {
            try await runtime.startBundledImage()
            let evaluated = try await runtime.evaluate(source)
            snapshot = try await PharoSnapshot.capture(of: evaluated, using: runtime)
            inspection = .live(evaluated)
            failure = nil
        } catch {
            failure = error.localizedDescription
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
