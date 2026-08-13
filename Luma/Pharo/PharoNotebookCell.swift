#if os(macOS)
import LumaCore
import SwiftUI
import SwiftyPharo

/// A notebook entry holding Smalltalk the reader can edit and run. Its result
/// stands to the right of the code as a compact preview; a button on it opens
/// the whole inspector in the pane beside the page. What the last run captured
/// is kept with the entry, so it can be reopened with no VM around.
struct PharoNotebookCell: View {
    let entry: NotebookEntry
    let engine: Engine
    let autoFocus: Bool
    let drillPath: PharoColumnPath
    @Binding var inspected: UUID?
    @Binding var centers: [UUID: CGFloat]

    @State private var source: String
    @State private var snapshot: PharoSnapshot?
    @State private var fuel: Data?
    @State private var failure: PharoEvaluationError?

    @State private var focused: UUID?
    @State private var evaluated: PharoObject?
    @State private var printString: String?
    @State private var isEvaluating = false

    private let runtime = PharoRuntime.shared

    init(
        entry: NotebookEntry,
        engine: Engine,
        autoFocus: Bool,
        drillPath: PharoColumnPath,
        inspected: Binding<UUID?>,
        centers: Binding<[UUID: CGFloat]>
    ) {
        self.entry = entry
        self.engine = engine
        self.autoFocus = autoFocus
        self.drillPath = drillPath
        _inspected = inspected
        _centers = centers
        _source = State(initialValue: entry.details)
        _snapshot = State(initialValue: entry.pharoSnapshot)
        _fuel = State(initialValue: entry.pharoResultFuel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            snippet
                .frame(maxWidth: .infinity, alignment: .leading)

            if failure == nil, let snapshot {
                resultBelow(snapshot)
            }
        }
        .onAppear { if autoFocus { focused = entry.id } }
    }

    private var snippet: some View {
        PharoSnippetView(
            id: entry.id,
            source: $source,
            focused: $focused,
            runtime: runtime,
            open: showInInspector,
            openResult: nil,
            evaluate: { Task { await run(.evaluate) } },
            printIt: { Task { await run(.print) } },
            evaluateAndInspect: { Task { await run(.inspect) } },
            format: { Task { await format() } },
            remove: nil,
            error: failure,
            printString: printString,
            isEvaluating: isEvaluating
        )
        .onChange(of: source) {
            forget()
            save()
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(pharoPageSpace)).midY
        } action: { center in
            centers[entry.id] = center
        }
    }

    private func resultBelow(_ snapshot: PharoSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            evaluatesTo
            PharoResultPreview(snapshot: snapshot)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) { inspectButton }
                .pharoPane()
        }
    }

    private var evaluatesTo: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    private var inspectButton: some View {
        Button(action: inspectResult) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(6)
        .help("Inspect")
        .accessibilityIdentifier("notebook.pharo.inspect")
    }

    private func inspectResult() {
        Task {
            if evaluated == nil {
                await revive()
            }
            guard let evaluated else { return }
            showInInspector(evaluated)
        }
    }

    private func showInInspector(_ object: PharoObject) {
        inspected = entry.id
        drillPath.startOver(at: object)
    }

    private func revive() async {
        guard let fuel else { return }
        do {
            try await runtime.startBundledImage(for: engine)
            evaluated = try await runtime.materialize(fuel)
        } catch {
            failure = evaluationError(from: error)
        }
    }

    private func evaluationError(from error: Error) -> PharoEvaluationError {
        PharoEvaluationError(
            message: error.localizedDescription,
            position: (error as? PharoRequestError)?.sourcePosition)
    }

    private func run(_ mode: PharoRunMode) async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        do {
            try await runtime.startBundledImage(for: engine)
            let produced = try await runtime.evaluate(source)
            evaluated = produced
            fuel = try? await runtime.serialize(produced)
            failure = nil
            if mode == .print {
                printString = produced.printString
                snapshot = nil
            } else {
                printString = nil
                snapshot = try await PharoSnapshot.capture(of: produced, using: runtime)
                if mode == .inspect { showInInspector(produced) }
            }
        } catch {
            failure = evaluationError(from: error)
            printString = nil
        }
        save()
    }

    private func format() async {
        try? await runtime.startBundledImage(for: engine)
        guard let formatted = try? await runtime.format(source: source), formatted != source else { return }
        source = formatted
    }

    private func forget() {
        evaluated = nil
        snapshot = nil
        fuel = nil
        failure = nil
        printString = nil
        if inspected == entry.id {
            drillPath.clear()
            inspected = nil
        }
    }

    private func save() {
        var updated = entry
        updated.details = source
        updated.pharoSnapshot = snapshot
        updated.pharoResultFuel = fuel
        engine.updateNotebookEntry(updated)
    }
}

/// The compact face of a result beside its code: its Preview when it declares
/// one, otherwise its first view -- words, or a table for a collection.
struct PharoResultPreview: View {
    let snapshot: PharoSnapshot

    var body: some View {
        switch preview?.content {
        case .text(let text):
            previewText(text)
        case .items(let rows, let total):
            previewTable(rows, total: total)
        case .graph:
            Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .chart:
            Label("Chart", systemImage: "chart.bar")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .canvas:
            Label("Canvas", systemImage: "cube.transparent")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .empty, .none:
            previewText(snapshot.printString)
        }
    }

    private var preview: PharoSnapshot.View? {
        snapshot.views.first { $0.title == "Preview" } ?? snapshot.views.first
    }

    private func previewText(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .rounded))
            .lineLimit(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    private func previewTable(_ rows: [[PharoSnapshot.View.Cell]], total: Int) -> some View {
        let leadingCharacters = rows.compactMap { $0.first?.text?.count }.max() ?? 0
        return List {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                PharoRowView(cells: row, leadingCharacters: leadingCharacters)
            }

            if rows.count < total {
                Text("\(total - rows.count) more\u{2026}")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .frame(height: 160)
    }
}
#endif
