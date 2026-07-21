import LumaCore
import SwiftUI
import SwiftyPharo

/// A scratch page of Smalltalk snippets, opening what they produce in the pane
/// beside it. Nothing here is kept; the notebook is where work is saved.
struct PharoPlaygroundView: View {
    let engine: Engine

    @State private var snippets: [PharoPlaygroundSnippet] = []
    @State private var inspection: PharoInspection?
    @State private var inspected: UUID?
    @State private var centers: [UUID: CGFloat] = [:]
    @State private var failure: String?
    @State private var isReady = false
    @State private var focused: UUID?
    @State private var results: [UUID: PharoObject] = [:]

    private let runtime = PharoRuntime.shared

    var body: some View {
        HSplitView {
            page
                .pharoPane()
                .padding(8)
                .frame(minWidth: 280, idealWidth: 420)

            inspectionSide
                .padding(.vertical, 8)
                .padding(.trailing, 8)
                .frame(minWidth: 320)
        }
        .coordinateSpace(name: pharoPageSpace)
        .background(.pharoGutter)
        .task { await start() }
        .onAppear { snippets = engine.pharoSnippets.isEmpty ? [PharoPlaygroundSnippet(source: "1 to: 20")] : engine.pharoSnippets }
        .onChange(of: snippets) { engine.setPharoSnippets(snippets) }
    }


    /// Always the same view, whether or not it is showing anything: swapping
    /// one out for another has HSplitView lay the divider out afresh, undoing
    /// wherever the reader had put it.
    private var inspectionSide: some View {
        ZStack {
            Color.clear

            if let inspection {
                PharoInspectionPane(inspection: inspection, pointsFrom: inspected.flatMap { centers[$0] }) {
                    self.inspection = nil
                }
            }
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($snippets) { $snippet in
                    PharoSnippetView(
                        id: snippet.id,
                        source: $snippet.source,
                        focused: $focused,
                        runtime: runtime,
                        result: results[snippet.id],
                        open: { show($0, from: snippet.id) },
                        evaluate: { Task { await evaluate(snippet) } },
                        inspect: nil,
                        remove: snippets.count > 1 ? { remove(snippet) } : nil
                    )
                    .onChange(of: snippet.source) { results[snippet.id] = nil }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named(pharoPageSpace)).midY
                    } action: { center in
                        centers[snippet.id] = center
                    }
                }

                addSnippetButton

                if let failure {
                    PharoFailureView(message: failure)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var addSnippetButton: some View {
        Button {
            let added = PharoPlaygroundSnippet(source: "")
            snippets.append(added)
            focused = added.id
        } label: {
            Label("Add Snippet", systemImage: "plus")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!isReady)
        .accessibilityIdentifier("pharo.playground.addSnippet")
    }

    private func start() async {
        guard !isReady else { return }

        do {
            try await runtime.startBundledImage(for: engine)
            isReady = true
        } catch {
            failure = error.localizedDescription
        }
    }

    private func evaluate(_ snippet: PharoPlaygroundSnippet) async {
        do {
            let produced = try await runtime.evaluate(snippet.source)
            results[snippet.id] = produced
            show(produced, from: snippet.id)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func show(_ object: PharoObject, from snippet: UUID) {
        inspected = snippet
        inspection = .live(object)
    }

    private func remove(_ snippet: PharoPlaygroundSnippet) {
        snippets.removeAll { $0.id == snippet.id }
    }
}
