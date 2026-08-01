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
    @State private var isPageMaximized = false
    @State private var isPagePointedAt = false
    @State private var errors: [UUID: PharoEvaluationError] = [:]

    private let runtime = PharoRuntime.shared

    var body: some View {
        Group {
            if snippets.isEmpty {
                PharoPlaygroundEmptyState(onAddSnippet: addSnippet)
            } else {
                workspace
            }
        }
        .coordinateSpace(name: pharoPageSpace)
        .background(.pharoGutter)
        .pharoMaximizedPane(runtime: runtime, path: columnPath, onCloseAll: columnPath.clear)
        .overlay { if isPageMaximized { maximizedPage } }
        .task { await start() }
        .onAppear {
            snippets = engine.pharoSnippets
            pageWidth = engine.pharoPageWidth.map { CGFloat($0) } ?? 420
            isPageMaximized = engine.pharoPageMaximized
        }
        .onChange(of: snippets) { engine.setPharoSnippets(snippets) }
        .onChange(of: isPageMaximized) { engine.setPharoPageMaximized(isPageMaximized) }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            // The strip stands over the whole page, snippets included, rather
            // than over the columns alone.
            PharoOverviewStrip(path: columnPath)
            Divider()

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    Group {
                        // The maximized overlay holds the live page; a second copy
                        // here would run the snippet editors twice over.
                        if isPageMaximized {
                            Color.clear
                        } else {
                            page
                        }
                    }
                    .frame(width: pageWidth)
                    .pharoPane()
                    .overlay(alignment: .trailing) { pageResizeHandle }
                    .overlay(alignment: .topTrailing) { if !isPageMaximized { pageMenuButton } }
                    .onHover { isPagePointedAt = $0 }
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
    }


    /// The columns ride in the page's own scroller, so the playground lays out
    /// the arrow into them and the columns themselves rather than handing both
    /// to a pane that would scroll on its own.
    @ViewBuilder
    private var inspectionSide: some View {
        if !columnPath.objects.isEmpty {
            if !columnPath.isFirstColumnCollapsed {
                PharoPointingArrow(pointsFrom: inspected.flatMap { centers[$0] })
            }
            pharoColumns(runtime: runtime, path: columnPath, onCloseAll: columnPath.clear)
        } else if let captured {
            PharoPointingArrow(pointsFrom: inspected.flatMap { centers[$0] })
            PharoSnapshotView(snapshot: captured)
                .frame(width: pharoColumnWidth)
                .pharoPane()
        }
    }


    /// The page is a pane too: it maximizes over the whole playground, though
    /// unlike a column it cannot be collapsed or closed, the way GT holds its
    /// first pane in place.
    private var pageMenuButton: some View {
        PharoPaneMenuButton(
            isRevealed: isPagePointedAt,
            canClose: false,
            actions: PharoPaneActions(canMaximize: true, onMaximize: { isPageMaximized = true }),
            onClose: {},
            onUpdate: {})
            .padding(6)
    }

    private var maximizedPage: some View {
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pharoPane()
            .overlay(alignment: .topLeading) { pageRestoreButton }
            .overlay(alignment: .topTrailing) { pageMaximizedMenuButton }
            .padding(8)
            .background(.pharoGutter)
    }

    private var pageRestoreButton: some View {
        Button(action: { isPageMaximized = false }) {
            PharoRoundIcon(systemName: "arrow.down.right.and.arrow.up.left")
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Restore pane")
        .padding(6)
    }

    private var pageMaximizedMenuButton: some View {
        PharoPaneMenuButton(
            isRevealed: true,
            canClose: false,
            actions: PharoPaneActions(),
            onClose: {},
            onUpdate: {})
            .padding(6)
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
                // Measured globally: the handle rides the page's edge, so a
                // local translation would shrink as the page grows under it.
                DragGesture(coordinateSpace: .global)
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
                        evaluate: { Task { await run(snippet, inspect: false) } },
                        evaluateAndInspect: { Task { await run(snippet, inspect: true) } },
                        remove: { remove(snippet) },
                        error: errors[snippet.id]
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
        Button(action: addSnippet) {
            Label("Add Snippet", systemImage: "plus")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!isReady)
        .accessibilityIdentifier("pharo.playground.addSnippet")
    }

    private func addSnippet() {
        let added = PharoPlaygroundSnippet(source: "")
        snippets.append(added)
        focused = added.id
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

    private func run(_ snippet: PharoPlaygroundSnippet, inspect: Bool) async {
        do {
            let produced = try await runtime.evaluate(snippet.source)
            results[snippet.id] = produced
            let snapshot = try await PharoSnapshot.capture(of: produced, using: runtime)
            keep(snapshot: snapshot, fuel: try? await runtime.serialize(produced), for: snippet.id)
            if inspect { show(produced, from: snippet.id) }
            errors[snippet.id] = nil
        } catch {
            errors[snippet.id] = evaluationError(from: error)
        }
    }

    private func evaluationError(from error: Error) -> PharoEvaluationError {
        PharoEvaluationError(
            message: error.localizedDescription,
            position: (error as? PharoRequestError)?.sourcePosition)
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
        isPageMaximized = false
        columnPath.startOver(at: object)
    }

    private func showCaptured(_ snapshot: PharoSnapshot, from snippet: UUID) {
        inspected = snippet
        isPageMaximized = false
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
        errors[snippet] = nil
        guard let index = snippets.firstIndex(where: { $0.id == snippet }) else { return }
        snippets[index].snapshot = nil
        snippets[index].resultFuel = nil
    }

    private func remove(_ snippet: PharoPlaygroundSnippet) {
        snippets.removeAll { $0.id == snippet.id }
    }
}

/// Greets an empty playground the way the notebook and the REPL greet their
/// own empty pages: what it is for, and a way to begin.
private struct PharoPlaygroundEmptyState: View {
    let onAddSnippet: () -> Void

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer(minLength: 0)

                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)

                        Text("Playground")
                            .font(.title2.weight(.semibold))

                        Text("Slice, dice, and visualize your project's data with Pharo.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    if !isCompact {
                        tips
                    }

                    Button(action: onAddSnippet) {
                        Label("New Snippet", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("pharo.playground.empty.addSnippet")
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(tipLines.enumerated()), id: \.offset) { index, text in
                tip(number: index + 1, text: text)
            }
        }
        .font(.callout)
    }

    private var tipLines: [String] {
        [
            "Type an expression and press \u{2318}D to evaluate it.",
            "Press \u{2318}G to evaluate and open the result beside the page; double-click a row to drill in.",
            "Script your own views, or export what you find to a file.",
            "Try LumaProject events, or LumaProject sessions.",
        ]
    }

    private func tip(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
