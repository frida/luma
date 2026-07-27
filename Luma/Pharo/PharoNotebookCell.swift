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
    @Binding var inspected: UUID?
    @Binding var centers: [UUID: CGFloat]

    @State private var source: String
    @State private var snapshot: PharoSnapshot?
    @State private var failure: String?

    @State private var focused: UUID?
    @State private var evaluated: PharoObject?

    private let runtime = PharoRuntime.shared

    init(
        entry: NotebookEntry,
        engine: Engine,
        inspection: Binding<PharoInspection?>,
        inspected: Binding<UUID?>,
        centers: Binding<[UUID: CGFloat]>
    ) {
        self.entry = entry
        self.engine = engine
        _inspection = inspection
        _inspected = inspected
        _centers = centers
        _source = State(initialValue: entry.details)
        _snapshot = State(initialValue: entry.pharoSnapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PharoSnippetView(
                id: entry.id,
                source: $source,
                focused: $focused,
                runtime: runtime,
                open: { object in
                    inspected = entry.id
                    inspection = .live(object)
                },
                openResult: openResult,
                evaluate: { Task { await evaluate() } },
                remove: nil
            )
            .onChange(of: source) {
                evaluated = nil
                save()
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(pharoPageSpace)).midY
            } action: { center in
                centers[entry.id] = center
            }

            if let failure {
                PharoFailureView(message: failure)
                    .frame(height: 60)
            }
        }
    }

    /// The dot leads to the live result while the image still holds it, and to
    /// what the run captured once it does not.
    private var openResult: (() -> Void)? {
        if let evaluated {
            return {
                inspected = entry.id
                inspection = .live(evaluated)
            }
        }
        if let snapshot {
            return {
                inspected = entry.id
                inspection = .captured(snapshot)
            }
        }
        return nil
    }

    private func evaluate() async {
        inspected = entry.id
        do {
            try await runtime.startBundledImage(for: engine)
            let produced = try await runtime.evaluate(source)
            evaluated = produced
            snapshot = try await PharoSnapshot.capture(of: produced, using: runtime)
            inspection = .live(produced)
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
