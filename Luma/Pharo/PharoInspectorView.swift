import SwiftUI
import SwiftyPharo

/// The columns opened from a page. A playground scrolls its page along with
/// them and counts it as the first slot; a notebook keeps its page aside.
@Observable
final class PharoColumnPath {
    var objects: [PharoObject] = []
    /// Which column is the current one, or nothing when the page itself is.
    var shown: Int?
    private(set) var scrollTarget: PharoScrollTarget?

    let includesPage: Bool

    init(includesPage: Bool = false) {
        self.includesPage = includesPage
    }

    static let pageID = 0

    /// A marker sits past the last column. Revealing the newest scrolls to it
    /// rather than to the column, whose own list is a scroller that throws off
    /// how far a scroll to the column reaches.
    static let trailingID = -1

    var slotCount: Int {
        pageSlots + objects.count
    }

    func slot(ofColumn depth: Int) -> Int {
        depth + pageSlots
    }

    var leadingSlot: Int {
        onScreenSlots.min() ?? 0
    }

    var visibleSlots: Int {
        max(onScreenSlots.count, 1)
    }

    func isOnScreen(_ slot: Int) -> Bool {
        onScreenSlots.contains(slot)
    }

    func show(slot: Int) {
        let clamped = min(max(slot, 0), slotCount - 1)
        shown = clamped < pageSlots ? nil : clamped - pageSlots
        bring(slot: clamped, to: .leading)
    }

    func startOver(at object: PharoObject) {
        objects = [object]
        shown = 0
        revealNewest()
    }

    func open(_ object: PharoObject, from depth: Int) {
        objects = objects.prefix(depth + 1) + [object]
        shown = objects.count - 1
        revealNewest()
    }

    /// Answers whether the page's own first column was the one closed, which is
    /// the whole inspection going away rather than a column of it.
    func close(from depth: Int) -> Bool {
        guard depth > 0 else { return true }
        objects = Array(objects.prefix(depth))
        shown = min(shown ?? 0, objects.count - 1)
        return false
    }

    func clear() {
        objects = []
        shown = nil
        bring(slot: 0, to: .leading)
    }

    func markVisible(_ ids: [Int]) {
        visibleIDs = Set(ids)
    }

    private func revealNewest() {
        scrollTarget = PharoScrollTarget(id: Self.trailingID, anchor: .trailing)
    }

    private func bring(slot: Int, to anchor: UnitPoint) {
        scrollTarget = PharoScrollTarget(id: id(atSlot: slot), anchor: anchor)
    }

    private var onScreenSlots: Set<Int> {
        Set(visibleIDs.compactMap(slot(ofID:)))
    }

    private func slot(ofID id: Int) -> Int? {
        guard id != Self.pageID else { return pageSlots > 0 ? 0 : nil }
        return objects.firstIndex { $0.handle == id }.map { $0 + pageSlots }
    }

    private func id(atSlot slot: Int) -> Int {
        slot < pageSlots ? Self.pageID : objects[slot - pageSlots].handle
    }

    private var pageSlots: Int {
        includesPage ? 1 : 0
    }

    private var visibleIDs: Set<Int> = []
}

/// A scroll the path is asking its scroller to make. The stamp sets each one
/// apart, so asking twice for the same place scrolls both times.
struct PharoScrollTarget: Equatable {
    let id: Int
    let anchor: UnitPoint
    let stamp = UUID()
}

/// The columns side by side, as loose content for the page's own scroller to
/// hold. Each is a direct child there, which is what has the scroller report it
/// as it comes and goes on screen; wrapped in a view of their own they would
/// not be seen. Whoever shows them does the scrolling.
@ViewBuilder
func pharoColumns(
    runtime: PharoRuntime,
    path: PharoColumnPath,
    onCloseAll: @escaping () -> Void
) -> some View {
    ForEach(Array(path.objects.enumerated()), id: \.element.handle) { depth, object in
        if depth > 0 {
            PharoDrillArrow()
        }

        PharoObjectColumn(
            runtime: runtime,
            object: object,
            onSelect: { path.open($0, from: depth) },
            onClose: { if path.close(from: depth) { onCloseAll() } })
        .frame(width: 320)
        .pharoPane()
        .id(object.handle)
    }

    Color.clear
        .frame(width: 1)
        .id(PharoColumnPath.trailingID)
}

/// Walks an object through the views it declares, opening each selection in a
/// column to its right so the path taken to reach a value stays on screen.
struct PharoInspectorView: View {
    let runtime: PharoRuntime
    let root: PharoObject
    let onClose: () -> Void

    @State private var path = PharoColumnPath()

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                pharoColumns(runtime: runtime, path: path, onCloseAll: onClose)
            }
            .scrollTargetLayout()
        }
        .pharoColumnScrolling(path)
        .onChange(of: root.handle, initial: true) { path.startOver(at: root) }
    }
}

extension View {
    /// Drives a horizontal scroller from a column path: it scrolls where the
    /// path asks, and the path learns which columns are on screen.
    func pharoColumnScrolling(_ path: PharoColumnPath) -> some View {
        modifier(PharoColumnScrolling(path: path))
    }
}

private struct PharoColumnScrolling: ViewModifier {
    let path: PharoColumnPath

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: path.scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
                .onScrollTargetVisibilityChange(idType: Int.self) { path.markVisible($0) }
        }
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
        PharoCloseButton(close: onClose)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .tag(index)
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
        // GT drills on activation rather than on merely selecting a row. Watching
        // for the second click leaves the list's own handling of the first alone,
        // so selection stays quick and the arrow keys still walk the rows.
        .background(PharoDoubleClickCatcher { row in
            selection = row
            Task { await drill(into: row) }
        })
        .onKeyPress(.return) {
            guard let row = selection else { return .ignored }
            Task { await drill(into: row) }
            return .handled
        }
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

/// The pager's scroll thumb, resting over the squares it stands for.
private struct PharoOverviewThumb: View {
    let trackWidth: CGFloat
    let fractionVisible: CGFloat
    let fractionLeading: CGFloat
    let scrollTo: (CGFloat) -> Void

    @State private var isPointedAt = false
    @State private var draggedFrom: CGFloat?

    var body: some View {
        Capsule()
            .fill(isPointedAt || draggedFrom != nil ? Color.fridaBrand : Color.secondary.opacity(0.5))
            .frame(width: max(trackWidth * fractionVisible, 10), height: 3)
            .padding(.leading, trackWidth * fractionLeading)
            .frame(width: trackWidth, height: 8, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isPointedAt = $0 }
            .pointerStyle(.link)
            .gesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { movement in
                let start = draggedFrom ?? fractionLeading
                draggedFrom = start
                scrollTo(start + movement.translation.width / max(trackWidth, 1))
            }
            .onEnded { _ in draggedFrom = nil }
    }
}

/// One pane's square in the overview strip.
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

/// Closing a pane.
private struct PharoCloseButton: View {
    let close: () -> Void

    @State private var isPointedAt = false

    var body: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.caption2)
                .foregroundStyle(isPointedAt ? Color.fridaBrand : .secondary)
                .frame(width: 16, height: 16)
                .background(isPointedAt ? Color.secondary.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .pointerStyle(.link)
        .help("Close")
    }
}

/// Notices a double-click over the list without taking the click, so the list
/// keeps handling selection and keyboard travel itself.
/// Reports which row a double-click landed on, read from the table under the
/// pointer rather than from the selection, which the first click of the two has
/// not always finished settling by the time the second arrives.
private struct PharoDoubleClickCatcher: NSViewRepresentable {
    let activate: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.watch(view, activate: activate)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.activate = activate
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var activate: (Int) -> Void = { _ in }
        private var monitor: Any?
        private weak var view: NSView?

        func watch(_ view: NSView, activate: @escaping (Int) -> Void) {
            self.view = view
            self.activate = activate
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.noticed(event)
                return event
            }
        }

        private func noticed(_ event: NSEvent) {
            guard event.clickCount == 2, let view, let window = view.window, event.window === window,
                view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                let table = table(under: event.locationInWindow, in: window)
            else { return }

            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            guard row >= 0 else { return }
            activate(row)
        }

        private func table(under point: NSPoint, in window: NSWindow) -> NSTableView? {
            var hit = window.contentView?.hitTest(point)
            while let view = hit {
                if let table = view as? NSTableView {
                    return table
                }
                hit = view.superview
            }
            return nil
        }

        func stop() {
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
        }
    }
}

/// The pager's strip: a square for the page and one for each column, with a
/// scrollbar under them.
struct PharoOverviewStrip: View {
    let path: PharoColumnPath

    var body: some View {
        VStack(spacing: 2) {
            squares
            thumb
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var squares: some View {
        HStack(spacing: previewSpacing) {
            PharoOverviewSquare(
                isCurrent: path.shown == nil,
                isOnScreen: path.isOnScreen(0),
                printString: "Snippets",
                width: previewWidth,
                height: previewHeight) {
                path.show(slot: 0)
            }

            ForEach(Array(path.objects.enumerated()), id: \.element.handle) { depth, object in
                PharoOverviewSquare(
                    isCurrent: path.shown == depth,
                    isOnScreen: path.isOnScreen(path.slot(ofColumn: depth)),
                    printString: object.printString,
                    width: previewWidth,
                    height: previewHeight) {
                    path.show(slot: path.slot(ofColumn: depth))
                }
            }
        }
    }

    private var thumb: some View {
        let span = min(onScreen / total, 1)
        return PharoOverviewThumb(
            trackWidth: overviewWidth,
            fractionVisible: span,
            fractionLeading: min(CGFloat(path.leadingSlot) / total, 1 - span),
            scrollTo: { path.show(slot: Int(($0 * total).rounded())) })
    }

    private var total: CGFloat {
        CGFloat(path.slotCount)
    }

    private var onScreen: CGFloat {
        min(CGFloat(path.visibleSlots), total)
    }

    private var overviewWidth: CGFloat {
        total * previewWidth + (total - 1) * previewSpacing
    }

    private let previewWidth: CGFloat = 22
    private let previewHeight: CGFloat = 12
    private let previewSpacing: CGFloat = 3
}
