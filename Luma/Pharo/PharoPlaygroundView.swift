import LumaCore
import SwiftUI
import SwiftyPharo

/// A page of Smalltalk snippets, opening what they produce in the pane beside
/// them. The snippets and their last results are kept with the project.
struct PharoPlaygroundView: View {
    let engine: Engine

    @State private var snippets: [PharoPlaygroundSnippet] = []
    @State private var inspected: UUID?
    @State private var centers: [UUID: CGFloat] = [:]
    @State private var failure: String?
    @State private var isReady = false
    @State private var focused: UUID?
    @State private var results: [UUID: PharoObject] = [:]
    @State private var captured: PharoSnapshot?
    @State private var columnPath = PharoColumnPath(includesPage: true)

    private let runtime = PharoRuntime.shared

    var body: some View {
        VStack(spacing: 0) {
            // The strip stands over the whole page, snippets included, rather
            // than over the columns alone.
            PharoOverviewStrip(path: columnPath)
            Divider()

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    page
                        .frame(width: pageWidth)
                        .pharoPane()
                        .id(PharoColumnPath.pageID)

                    inspectionSide
                }
                .scrollTargetLayout()
            }
            // A margin rather than padding, so that scrolling something to the
            // leading edge leaves the same gap before it that it had at rest.
            .contentMargins(8, for: .scrollContent)
            .pharoColumnScrolling(columnPath)
        }
        .coordinateSpace(name: pharoPageSpace)
        .background(.pharoGutter)
        .task { await start() }
        .onAppear { snippets = engine.pharoSnippets.isEmpty ? [PharoPlaygroundSnippet(source: "1 to: 20")] : engine.pharoSnippets }
        .onChange(of: snippets) { engine.setPharoSnippets(snippets) }
    }


    /// The columns ride in the page's own scroller, so the playground lays out
    /// the arrow into them and the columns themselves rather than handing both
    /// to a pane that would scroll on its own.
    @ViewBuilder
    private var inspectionSide: some View {
        if !columnPath.objects.isEmpty {
            PharoPointingArrow(pointsFrom: inspected.flatMap { centers[$0] })
            pharoColumns(runtime: runtime, path: columnPath, onCloseAll: columnPath.clear)
        } else if let captured {
            PharoPointingArrow(pointsFrom: inspected.flatMap { centers[$0] })
            PharoSnapshotView(snapshot: captured)
                .frame(width: 320)
                .pharoPane()
        }
    }

    private let pageWidth: CGFloat = 420

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($snippets) { $snippet in
                    PharoSnippetView(
                        id: snippet.id,
                        source: $snippet.source,
                        focused: $focused,
                        runtime: runtime,
                        open: { show($0, from: snippet.id) },
                        openResult: openResult(for: snippet),
                        evaluate: { Task { await evaluate(snippet) } },
                        remove: snippets.count > 1 ? { remove(snippet) } : nil
                    )
                    .onChange(of: snippet.source) { forget(snippet.id) }
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
            keep(try await PharoSnapshot.capture(of: produced, using: runtime), for: snippet.id)
            show(produced, from: snippet.id)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The dot leads to the live result while the image still holds it, and to
    /// what the run captured once it does not.
    private func openResult(for snippet: PharoPlaygroundSnippet) -> (() -> Void)? {
        if let object = results[snippet.id] {
            return { show(object, from: snippet.id) }
        }
        if let snapshot = snippet.snapshot {
            return { showCaptured(snapshot, from: snippet.id) }
        }
        return nil
    }

    private func show(_ object: PharoObject, from snippet: UUID) {
        inspected = snippet
        captured = nil
        columnPath.startOver(at: object)
    }

    private func showCaptured(_ snapshot: PharoSnapshot, from snippet: UUID) {
        inspected = snippet
        columnPath.clear()
        captured = snapshot
    }

    private func keep(_ snapshot: PharoSnapshot, for snippet: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet }) else { return }
        snippets[index].snapshot = snapshot
    }

    private func forget(_ snippet: UUID) {
        results[snippet] = nil
        keepNothing(for: snippet)
    }

    private func keepNothing(for snippet: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet }) else { return }
        snippets[index].snapshot = nil
    }

    private func remove(_ snippet: PharoPlaygroundSnippet) {
        snippets.removeAll { $0.id == snippet.id }
    }
}
