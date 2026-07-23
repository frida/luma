import SwiftUI
import SwiftyPharo

/// The columns opened from a page, and where along them the reader is looking.
/// A playground scrolls its own page along with them and so counts it as the
/// first slot; a notebook keeps its page aside and counts only the columns.
@Observable
final class PharoColumnPath {
    var objects: [PharoObject] = []
    /// Which column is the current one, or nothing when the page itself is.
    var shown: Int?
    var leading: Int?
    var visibleWidth: CGFloat = 0

    let includesPage: Bool

    init(includesPage: Bool = false) {
        self.includesPage = includesPage
    }

    /// The page scrolls with the columns, so it needs an identity among them.
    static let pageID = 0

    /// One column is a pane plus the arrow before it, save the first with none.
    var visibleColumns: CGFloat {
        max(visibleWidth / 344, 1)
    }

    var slotCount: Int {
        pageSlots + objects.count
    }

    var leadingSlot: Int {
        guard let leading, leading != Self.pageID else { return 0 }
        return (objects.firstIndex { $0.handle == leading } ?? 0) + pageSlots
    }

    func isOnScreen(_ slot: Int) -> Bool {
        slot >= leadingSlot && CGFloat(slot) < CGFloat(leadingSlot) + visibleColumns
    }

    func slot(ofColumn depth: Int) -> Int {
        depth + pageSlots
    }

    func show(slot: Int) {
        let clamped = min(max(slot, 0), slotCount - 1)
        shown = clamped < pageSlots ? nil : clamped - pageSlots
        leading = id(atSlot: clamped)
    }

    func startOver(at object: PharoObject) {
        objects = [object]
        shown = 0
        leading = object.handle
    }

    func open(_ object: PharoObject, from depth: Int) {
        objects = objects.prefix(depth + 1) + [object]
        shown = objects.count - 1
        revealLast()
    }

    /// Answers whether the page's own first column was the one closed, which is
    /// the whole inspection going away rather than a column of it.
    func close(from depth: Int) -> Bool {
        guard depth > 0 else { return true }
        objects = Array(objects.prefix(depth))
        shown = min(shown ?? 0, objects.count - 1)
        return false
    }

    /// Nothing is open any more, so the path is back to the page alone.
    func clear() {
        objects = []
        shown = nil
        leading = Self.pageID
    }

    /// Bring the newest column to the right edge, keeping as many of the ones
    /// before it on screen as fit.
    private func revealLast() {
        let onScreen = max(Int(visibleColumns), 1)
        leading = id(atSlot: max(0, slotCount - 1 - onScreen + 1))
    }

    private func id(atSlot slot: Int) -> Int? {
        slot < pageSlots ? Self.pageID : objects[slot - pageSlots].handle
    }

    private var pageSlots: Int {
        includesPage ? 1 : 0
    }
}

/// The columns themselves, laid side by side. Whoever shows them does the
/// scrolling, so a playground can carry its page along in the same scroller.
struct PharoColumnsView: View {
    let runtime: PharoRuntime
    let path: PharoColumnPath
    let onCloseAll: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(path.objects.enumerated()), id: \.element.handle) { depth, object in
                // Whoever puts something before the first column draws the
                // arrow into it, so that one points across from its source.
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
        }
    }
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
            PharoColumnsView(runtime: runtime, path: path, onCloseAll: onClose)
                .scrollTargetLayout()
        }
        .scrollPosition(
            id: Binding { path.leading } set: { path.leading = $0 },
            anchor: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { path.visibleWidth = $0 }
        // SwiftUI hands a new root to the view it already has, so seeding the
        // path from an initializer would only ever run once.
        .onChange(of: root.handle, initial: true) { path.startOver(at: root) }
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
        .background(PharoDoubleClickCatcher {
            guard let row = selection else { return }
            Task { await drill(into: row) }
        })
        .onKeyPress(.return) {
            guard let row = selection else { return .ignored }
            Task { await drill(into: row) }
            return .handled
        }
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
    /// Where along the track the reader has dragged the thumb to, as a fraction
    /// of the whole path.
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

/// Closing a pane is a button, and says so: it fills in and takes the hand when
/// the pointer is over it.
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
private struct PharoDoubleClickCatcher: NSViewRepresentable {
    let activate: () -> Void

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
        var activate: () -> Void = {}
        private var monitor: Any?
        private weak var view: NSView?

        func watch(_ view: NSView, activate: @escaping () -> Void) {
            self.view = view
            self.activate = activate
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.noticed(event)
                return event
            }
        }

        private func noticed(_ event: NSEvent) {
            guard event.clickCount == 2, let view, let window = view.window, event.window === window else { return }
            let inView = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(inView) else { return }
            activate()
        }

        func stop() {
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
        }
    }
}

/// The pager's strip, sitting above the whole page: a square for the snippets
/// themselves and one for each column opened from them, with a scrollbar under
/// them showing which are on screen.
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

    /// The page of snippets is always on screen and always counted, so the
    /// strip measures the whole page rather than the columns alone.
    private var total: CGFloat {
        CGFloat(path.slotCount)
    }

    private var onScreen: CGFloat {
        min(path.visibleColumns, total)
    }

    private var overviewWidth: CGFloat {
        total * previewWidth + (total - 1) * previewSpacing
    }

    private let previewWidth: CGFloat = 22
    private let previewHeight: CGFloat = 12
    private let previewSpacing: CGFloat = 3
}
