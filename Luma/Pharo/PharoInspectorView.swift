import SwiftUI
import SwiftyPharo

/// Walks an object through the views it declares, opening each selection in a
/// column to its right so the path taken to reach a value stays on screen.
struct PharoInspectorView: View {
    let runtime: PharoRuntime
    let root: PharoObject
    let onClose: () -> Void

    @State private var path: [PharoObject] = []
    @State private var shown: Int?
    @State private var leading: Int?
    @State private var visibleWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                overview
                thumb
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            Divider()
            columns
        }
        // SwiftUI hands a new root to the view it already has, so seeding the
        // path from an initializer would only ever run once.
        .onChange(of: root.handle, initial: true) { startOver(at: root) }
    }

    /// The panes as small squares, the way Glamorous Toolkit previews them: no
    /// words, just where in the path each one sits, gathered in the middle
    /// rather than stretched across the width. Clicking one brings its column
    /// to the front.
    private var overview: some View {
        HStack(spacing: previewSpacing) {
            ForEach(Array(path.enumerated()), id: \.element.handle) { depth, object in
                PharoOverviewSquare(
                    isCurrent: depth == shown,
                    isOnScreen: isOnScreen(depth),
                    printString: object.printString,
                    width: previewWidth,
                    height: previewHeight) {
                    shown = depth
                    leading = object.handle
                }
            }
        }
    }

    private let previewWidth: CGFloat = 22
    private let previewHeight: CGFloat = 12
    private let previewSpacing: CGFloat = 3

    /// Under the squares and no wider than them, the way Glamorous Toolkit does
    /// it: a scrollbar thumb as wide a fraction of the row as the columns it can
    /// see are of all of them, sitting over the squares they belong to.
    private var thumb: some View {
        let span = min(visibleColumns / CGFloat(max(path.count, 1)), 1)
        return PharoOverviewThumb(
            trackWidth: overviewWidth,
            fractionVisible: span,
            fractionLeading: min(CGFloat(leadingPane) / CGFloat(max(path.count, 1)), 1 - span))
    }

    private var overviewWidth: CGFloat {
        CGFloat(path.count) * previewWidth + CGFloat(max(path.count - 1, 0)) * previewSpacing
    }

    /// One column is a pane plus the arrow before it, save the first with none.
    private var visibleColumns: CGFloat {
        max(visibleWidth / columnStride, 1)
    }

    private let columnStride: CGFloat = 320 + 24

    private func isOnScreen(_ depth: Int) -> Bool {
        depth >= leadingPane && CGFloat(depth) < CGFloat(leadingPane) + visibleColumns
    }

    private var leadingPane: Int {
        path.firstIndex { $0.handle == leading } ?? 0
    }

    private var columns: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(path.enumerated()), id: \.element.handle) { depth, object in
                    if depth > 0 {
                        PharoDrillArrow()
                    }

                    PharoObjectColumn(
                        runtime: runtime,
                        object: object,
                        onSelect: { open($0, from: depth) },
                        onClose: { close(from: depth) })
                    .frame(width: 320)
                    .pharoPane()
                    .id(object.handle)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $leading, anchor: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
    }

    private func open(_ object: PharoObject, from depth: Int) {
        path = path.prefix(depth + 1) + [object]
        shown = path.count - 1
        revealLast()
    }

    private func startOver(at object: PharoObject) {
        path = [object]
        shown = 0
        leading = object.handle
    }

    /// Bring the newest column to the right edge, keeping as many of the ones
    /// before it on screen as fit.
    private func revealLast() {
        let onScreen = max(Int(visibleColumns), 1)
        leading = path[max(0, path.count - onScreen)].handle
    }

    private func close(from depth: Int) {
        guard depth > 0 else { return onClose() }
        path = Array(path.prefix(depth))
        shown = min(shown ?? 0, path.count - 1)
    }
}

/// One object's declared views, as a tab per view.
struct PharoObjectColumn: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let onSelect: (PharoObject) -> Void
    let onClose: () -> Void

    @State private var declared: Declared = .pending
    @State private var shown: String?

    /// Nothing declared and not asked yet are different things: rendering them
    /// alike flashes "No views" over every object on its way in.
    private enum Declared {
        case pending
        case ready([PharoViewDeclaration])
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .overlay(alignment: .topTrailing) { closeButton }

            if declarations.count > 1 {
                // More tabs than the card is wide should scroll rather than
                // squeeze every title down to an ellipsis.
                ScrollView(.horizontal) {
                    Picker("", selection: $shown) {
                        ForEach(declarations, id: \.methodSelector) { declaration in
                            Text(declaration.title).tag(Optional(declaration.methodSelector))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .scrollIndicators(.hidden)
                .padding(6)
            }

            Divider()
            content
        }
        .task { await loadDeclarations() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(object.printString)
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("pharo.inspector.printString")
            Text(object.className)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(6)
        .accessibilityIdentifier("pharo.inspection.close")
    }

    @ViewBuilder
    private var content: some View {
        switch declared {
        case .pending:
            Color.clear
        case .failed(let message):
            PharoFailureView(message: message)
        case .ready:
            if let shownDeclaration {
                body(of: shownDeclaration)
            } else {
                ContentUnavailableView("No views", systemImage: "square.dashed")
            }
        }
    }

    @ViewBuilder
    private func body(of declaration: PharoViewDeclaration) -> some View {
        switch declaration.viewName {
        case "list", "columnedList", "tree":
            PharoItemsList(
                runtime: runtime,
                object: object,
                view: declaration.methodSelector,
                onSelect: onSelect)
        case "text":
            ScrollView {
                Text(declaration.text ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        default:
            ContentUnavailableView(
                "\(declaration.viewName) views are not rendered yet", systemImage: "square.dashed")
        }
    }

    private var shownDeclaration: PharoViewDeclaration? {
        declarations.first { $0.methodSelector == shown } ?? declarations.first
    }

    private var declarations: [PharoViewDeclaration] {
        guard case .ready(let declarations) = declared else { return [] }
        return declarations
    }

    private func loadDeclarations() async {
        do {
            let loaded = try await runtime.views(of: object)
            declared = .ready(loaded)
            shown = loaded.first?.methodSelector
        } catch {
            declared = .failed(error.localizedDescription)
        }
    }
}

/// Pages its rows in as they are needed, so a large collection costs only the
/// rows that have been looked at.
private struct PharoItemsList: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let view: String
    let onSelect: (PharoObject) -> Void

    @State private var rows: [[PharoCell]] = []
    @State private var total = 0
    @State private var selection: Int?
    @State private var failure: String?

    private let pageSize = 50

    private var leadingCharacters: Int {
        rows.compactMap { $0.first?.text?.count }.max() ?? 0
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                PharoRowView(cells: row, leadingCharacters: leadingCharacters)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .tag(index)
                    // GT drills on activation, not on merely selecting a row.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        Task { await drill(into: index) }
                    })
            }

            if rows.count < total {
                Button("Show more (\(total - rows.count) left)") {
                    Task { await loadNextPage() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 18)
        // Switching tabs hands the same list a different view to page through.
        .task(id: view) { await reload() }
    }

    private func reload() async {
        rows = []
        total = 0
        selection = nil
        failure = nil
        await loadNextPage()
    }

    private func loadNextPage() async {
        do {
            let page = try await runtime.items(
                of: object, view: view, from: rows.count + 1, count: pageSize)
            total = page.total
            rows += page.items
        } catch {
            failure = error.localizedDescription
        }
    }

    private func drill(into index: Int) async {
        do {
            onSelect(try await runtime.drillInto(object, view: view, index: index + 1))
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The pager's scroll thumb: a thin bar the width of the columns on screen,
/// resting over the squares for those columns, and blue while pointed at.
private struct PharoOverviewThumb: View {
    let trackWidth: CGFloat
    let fractionVisible: CGFloat
    let fractionLeading: CGFloat

    @State private var isPointedAt = false

    var body: some View {
        Capsule()
            .fill(isPointedAt ? Color.fridaBrand : Color.secondary.opacity(0.5))
            .frame(width: max(trackWidth * fractionVisible, 10), height: 3)
            .padding(.leading, trackWidth * fractionLeading)
            .frame(width: trackWidth, height: 8, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isPointedAt = $0 }
    }
}

/// One pane's square in the overview strip. It lights up on hover the way the
/// thumb does, and stands out while it is the pane on top.
private struct PharoOverviewSquare: View {
    let isCurrent: Bool
    let isOnScreen: Bool
    let printString: String
    let width: CGFloat
    let height: CGFloat
    let activate: () -> Void

    @State private var isPointedAt = false

    var body: some View {
        Button(action: activate) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fill)
                .opacity(isOnScreen ? 1 : 0.4)
                .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .onHover { isPointedAt = $0 }
        .help(printString)
    }

    private var fill: Color {
        if isCurrent { return .fridaBrand.opacity(0.75) }
        if isPointedAt { return .fridaBrand.opacity(0.4) }
        return .secondary.opacity(0.25)
    }
}
