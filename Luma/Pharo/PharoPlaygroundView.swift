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
    @State private var pageWidth: CGFloat = 420
    @State private var resizingFrom: CGFloat?

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
                        .overlay(alignment: .trailing) { pageResizeHandle }
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
        .onAppear {
            snippets = engine.pharoSnippets.isEmpty ? [PharoPlaygroundSnippet(source: "1 to: 20")] : engine.pharoSnippets
            pageWidth = engine.pharoPageWidth.map { CGFloat($0) } ?? 420
        }
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


    /// The page keeps a width the reader sets by dragging its edge, the way a
    /// split's divider used to move it before the columns shared its scroller.
    private var pageResizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture()
                    .onChanged { drag in
                        let base = resizingFrom ?? pageWidth
                        resizingFrom = base
                        pageWidth = min(max(base + drag.translation.width, 260), 900)
                    }
                    .onEnded { _ in
                        resizingFrom = nil
                        engine.setPharoPageWidth(pageWidth)
                    })
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
            let snapshot = try await PharoSnapshot.capture(of: produced, using: runtime)
            keep(snapshot: snapshot, fuel: try? await runtime.serialize(produced), for: snippet.id)
            show(produced, from: snippet.id)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The dot leads to the result: the live object while the image holds it,
    /// the Fuel bytes brought back to a live one once a later session opens it,
    /// and the static capture when there is nothing to revive it from.
    private func openResult(for snippet: PharoPlaygroundSnippet) -> (() -> Void)? {
        guard results[snippet.id] != nil || snippet.resultFuel != nil || snippet.snapshot != nil else {
            return nil
        }
        return { Task { await reopen(snippet) } }
    }

    private func reopen(_ snippet: PharoPlaygroundSnippet) async {
        if let object = results[snippet.id] {
            return show(object, from: snippet.id)
        }
        if let fuel = snippet.resultFuel, isReady, let revived = try? await runtime.materialize(fuel) {
            results[snippet.id] = revived
            return show(revived, from: snippet.id)
        }
        if let snapshot = snippet.snapshot {
            showCaptured(snapshot, from: snippet.id)
        }
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

    private func keep(snapshot: PharoSnapshot, fuel: Data?, for snippet: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet }) else { return }
        snippets[index].snapshot = snapshot
        snippets[index].resultFuel = fuel
    }

    private func forget(_ snippet: UUID) {
        results[snippet] = nil
        guard let index = snippets.firstIndex(where: { $0.id == snippet }) else { return }
        snippets[index].snapshot = nil
        snippets[index].resultFuel = nil
    }

    private func remove(_ snippet: PharoPlaygroundSnippet) {
        snippets.removeAll { $0.id == snippet.id }
    }
}
