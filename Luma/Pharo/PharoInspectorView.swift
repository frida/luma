import SwiftUI
import SwiftyPharo

/// The columns opened from a page. A playground scrolls its page along with
/// them and counts it as the first slot; a notebook keeps its page aside.
@Observable
final class PharoColumnPath {
    var objects: [PharoObject] = []
    /// Which column is the current one, or nothing when the page itself is.
    var shown: Int?
    /// Column handles the reader has shrunk to a strip, and the one blown up to
    /// fill, so a drill remembers how each pane was left.
    private(set) var collapsed: Set<Int> = []
    private(set) var maximized: Int?
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
        forgetPaneStates()
        revealNewest()
    }

    func open(_ object: PharoObject, from depth: Int) {
        objects = objects.prefix(depth + 1) + [object]
        shown = objects.count - 1
        keepPaneStatesOfCurrentObjects()
        revealNewest()
    }

    /// Answers whether the page's own first column was the one closed, which is
    /// the whole inspection going away rather than a column of it.
    func close(from depth: Int) -> Bool {
        guard depth > 0 else { return true }
        objects = Array(objects.prefix(depth))
        shown = min(shown ?? 0, objects.count - 1)
        keepPaneStatesOfCurrentObjects()
        return false
    }

    func clear() {
        objects = []
        shown = nil
        forgetPaneStates()
        if slotCount > 0 {
            bring(slot: 0, to: .leading)
        }
    }

    func isCollapsed(_ handle: Int) -> Bool {
        collapsed.contains(handle)
    }

    func toggleCollapsed(_ handle: Int) {
        if collapsed.contains(handle) {
            collapsed.remove(handle)
        } else {
            collapsed.insert(handle)
        }
    }

    func isMaximized(_ handle: Int) -> Bool {
        maximized == handle
    }

    /// When the leading column is folded away, its stack's own downward triangle
    /// stands in for the arrow that would otherwise point into it.
    var isFirstColumnCollapsed: Bool {
        objects.first.map { collapsed.contains($0.handle) } ?? false
    }

    func toggleMaximized(_ handle: Int) {
        maximized = maximized == handle ? nil : handle
    }

    private func forgetPaneStates() {
        collapsed = []
        maximized = nil
    }

    private func keepPaneStatesOfCurrentObjects() {
        let present = Set(objects.map(\.handle))
        collapsed.formIntersection(present)
        if let handle = maximized, !present.contains(handle) {
            maximized = nil
        }
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

let pharoColumnWidth: CGFloat = 400

/// The gap a column is scrolled to rest at, kept out of the height a column is
/// given so a row of them fits the scroller rather than overflowing it.
let pharoColumnMargin: CGFloat = 8

#if os(macOS)
extension View {
    /// Lays a maximized pane over the whole inspector -- page and carousel both
    /// -- the way Glamorous Toolkit fills its host when a pane is maximized.
    func pharoMaximizedPane(runtime: PharoRuntime, path: PharoColumnPath, onCloseAll: @escaping () -> Void) -> some View {
        overlay {
            if let object = path.objects.first(where: { path.isMaximized($0.handle) }) {
                PharoMaximizedPane(runtime: runtime, object: object, path: path, onCloseAll: onCloseAll)
            }
        }
    }
}

/// A pane blown up to cover the inspector, its buttons standing rather than
/// waiting for a hover: the corner menu at the right, and at the left the button
/// that drops it back to its column.
struct PharoMaximizedPane: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let path: PharoColumnPath
    let onCloseAll: () -> Void

    var body: some View {
        PharoObjectColumn(
            runtime: runtime,
            object: object,
            actions: PharoPaneActions(onMaximize: restore),
            isMaximized: true,
            onSelect: open,
            onClose: close)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pharoPane()
            .padding(8)
            .background(.pharoGutter)
    }

    private var depth: Int {
        path.objects.firstIndex { $0.handle == object.handle } ?? 0
    }

    private func restore() {
        path.toggleMaximized(object.handle)
    }

    private func open(_ selected: PharoObject) {
        let from = depth
        restore()
        path.open(selected, from: from)
    }

    private func close() {
        let from = depth
        restore()
        if path.close(from: from) { onCloseAll() }
    }
}

/// The columns side by side, as loose content for the page's own scroller to
/// hold. Each is a direct child there, which is what has the scroller report it
/// as it comes and goes on screen; wrapped in a view of their own they would
/// not be seen. Whoever shows them does the scrolling.
func pharoColumns(
    runtime: PharoRuntime,
    path: PharoColumnPath,
    onCloseAll: @escaping () -> Void
) -> some View {
    let runs = pharoColumnRuns(path)

    return Group {
        ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
            switch run {
            case .collapsed(let objects):
                PharoCollapsedStack(
                    objects: objects,
                    hasFollowingExpanded: runs[safe: index + 1]?.isExpanded ?? false,
                    onExpand: { path.toggleCollapsed($0.handle) })
                    .id(run.id)
            case .expanded(let object, let depth):
                if runs[safe: index - 1]?.isExpanded ?? false {
                    PharoDrillArrow()
                }

                let handle = object.handle
                let close = { if path.close(from: depth) { onCloseAll() } }

                if path.isMaximized(handle) {
                    // The maximized overlay shows this pane; a second copy here
                    // would drill twice from one click through its own catcher.
                    Color.clear.frame(width: 0).id(handle)
                } else {
                    PharoObjectColumn(
                        runtime: runtime,
                        object: object,
                        actions: PharoPaneActions(
                            canCollapse: true,
                            canMaximize: true,
                            onCollapse: { path.toggleCollapsed(handle) },
                            onMaximize: { path.toggleMaximized(handle) }),
                        onSelect: { path.open($0, from: depth) },
                        onClose: close)
                    .frame(width: pharoColumnWidth)
                    .pharoPane()
                    .id(handle)
                }
            }
        }

        Color.clear
            .frame(width: 1)
            .id(PharoColumnPath.trailingID)
    }
}

/// A stretch of columns that render as one: consecutive collapsed panes fold
/// into a single stack, while an expanded pane stands on its own.
private enum PharoColumnRun: Identifiable {
    case collapsed([PharoObject])
    case expanded(PharoObject, depth: Int)

    var id: Int {
        switch self {
        case .collapsed(let objects): objects.first?.handle ?? 0
        case .expanded(let object, _): object.handle
        }
    }

    var isExpanded: Bool {
        if case .expanded = self { return true }
        return false
    }
}

private func pharoColumnRuns(_ path: PharoColumnPath) -> [PharoColumnRun] {
    var runs: [PharoColumnRun] = []
    var depth = 0
    while depth < path.objects.count {
        if path.isCollapsed(path.objects[depth].handle) {
            var group: [PharoObject] = []
            while depth < path.objects.count, path.isCollapsed(path.objects[depth].handle) {
                group.append(path.objects[depth])
                depth += 1
            }
            runs.append(.collapsed(group))
        } else {
            runs.append(.expanded(path.objects[depth], depth: depth))
            depth += 1
        }
    }
    return runs
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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

/// One inspector's views as a tab per view, scrolling when there are more than
/// fit across the card.
struct PharoTabBar: View {
    let tabs: [(id: String, title: String)]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal) {
            Picker("", selection: $selection) {
                ForEach(tabs, id: \.id) { tab in
                    Text(tab.title).tag(Optional(tab.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .scrollIndicators(.hidden)
        .padding(6)
    }
}

/// A class shows as Glamorous Toolkit's class coder; any other object shows its
/// declared views as tabs -- Preview, Print and a Meta that is that same coder
/// for its class among them.
struct PharoObjectColumn: View {
    let runtime: PharoRuntime
    let object: PharoObject
    var actions = PharoPaneActions()
    var isMaximized = false
    let onSelect: (PharoObject) -> Void
    let onClose: () -> Void

    @State private var declared: Declared = .pending
    @State private var shown: String?
    @State private var receiverClass: PharoObject?
    @State private var reloadToken = 0
    @State private var isPointedAt = false

    private static let metaView = "swpMeta"

    private enum Declared {
        case pending
        case ready([PharoViewDeclaration])
        case failed(String)
    }

    var body: some View {
        Group {
            if object.isClass {
                PharoClassBrowser(runtime: runtime, classObject: object, onSelect: onSelect)
            } else {
                objectInspector
            }
        }
        .overlay(alignment: .topLeading) { if isMaximized { restoreButton } }
        .overlay(alignment: .topTrailing) { menuButton }
        .onHover { isPointedAt = $0 }
        .task(id: reloadToken) { await load() }
    }

    private var restoreButton: some View {
        Button(action: actions.onMaximize) {
            PharoRoundIcon(systemName: "arrow.down.right.and.arrow.up.left")
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Restore pane")
        .padding(6)
        .accessibilityIdentifier("pharo.inspection.restore")
    }

    private var objectInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            printStringHeader
            PharoTabBar(tabs: declarations.map { ($0.methodSelector, $0.title) }, selection: $shown)
            Divider()
            content
        }
    }

    private var printStringHeader: some View {
        Text("\(article(for: object.className)) \(object.className) \(object.display)")
            .font(.headline)
            .lineLimit(2)
            .accessibilityIdentifier("pharo.inspector.printString")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    private func article(for className: String) -> String {
        "aeiouAEIOU".contains(className.first ?? "x") ? "an" : "a"
    }

    private var menuButton: some View {
        PharoPaneMenuButton(
            isRevealed: isPointedAt || isMaximized,
            actions: isMaximized ? PharoPaneActions() : actions,
            onClose: onClose,
            onUpdate: { reloadToken &+= 1 })
            .padding(6)
            .accessibilityIdentifier("pharo.inspection.menu")
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
        switch declaration.title {
        case "Preview":
            preview(declaration.text ?? object.printString)
        case "Print":
            source(object.printString)
        case "Meta":
            if let receiverClass {
                PharoClassBrowser(runtime: runtime, classObject: receiverClass, onSelect: onSelect)
            }
        default:
            declaredBody(of: declaration)
        }
    }

    private func preview(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.largeTitle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private func source(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    @ViewBuilder
    private func declaredBody(of declaration: PharoViewDeclaration) -> some View {
        switch declaration.viewName {
        case "list", "columnedList", "tree":
            PharoItemsList(
                runtime: runtime,
                object: object,
                view: declaration.methodSelector,
                columns: declaration.columns ?? [],
                reloadToken: reloadToken,
                onSelect: onSelect)
        case "text":
            ScrollView {
                Text(declaration.text ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        case "graph":
            if let graph = declaration.graph {
                PharoGraphView(
                    graph: graph,
                    onDrill: { try? await runtime.drillInto(object, view: declaration.methodSelector, index: $0 + 1) },
                    onSelect: onSelect)
            }
        case "chart":
            if let chart = declaration.chart {
                PharoChartView(
                    chart: chart,
                    onDrill: { try? await runtime.drillInto(object, view: declaration.methodSelector, index: $0 + 1) },
                    onSelect: onSelect)
            }
        case "canvas":
            if let canvas = declaration.canvas {
                PharoCanvasSceneView(scene: canvas.scene)
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
        guard case .ready(let loaded) = declared else { return [] }
        let declared = loaded.filter { $0.title != "Meta" }
        return declared + [printDeclaration, metaDeclaration]
    }

    private var printDeclaration: PharoViewDeclaration {
        PharoViewDeclaration(viewName: "print", title: "Print", priority: .max - 1, methodSelector: "swpPrint")
    }

    private var metaDeclaration: PharoViewDeclaration {
        PharoViewDeclaration(viewName: "meta", title: "Meta", priority: .max, methodSelector: Self.metaView)
    }

    private func load() async {
        if !object.isClass {
            receiverClass = try? await runtime.classObject(of: object)
        }
        do {
            let loaded = try await runtime.views(of: object)
            declared = .ready(loaded)
            shown = declarations.first?.methodSelector
        } catch {
            declared = .failed(error.localizedDescription)
        }
    }
}

/// The system search field, so filtering a list wears the magnifier, the clear
/// button, and the look every other macOS search does.
struct PharoSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.setAccessibilityLabel(prompt)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Pages its rows in as they are needed, so a large collection costs only the
/// rows that have been looked at.
private struct PharoItemsList: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let view: String
    let columns: [String]
    let reloadToken: Int
    let onSelect: (PharoObject) -> Void

    @State private var loaded = Loaded()
    @State private var selection: Int?
    @State private var failure: String?
    @State private var query = ""
    @State private var fullCount = 0

    private let pageSize = 50
    private let searchThreshold = 12

    /// The rows and the columns that head them, held together so the table never
    /// renders one against the other's shape while a view switch is in flight.
    private struct Loaded {
        var columns: [String] = []
        var rows: [Row] = []
        var total = 0
    }

    private struct Row: Identifiable {
        let id: Int
        let cells: [PharoCell]
    }

    var body: some View {
        VStack(spacing: 0) {
            if fullCount > searchThreshold {
                PharoSearchField(text: $query, prompt: "Filter")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                Divider()
            }
            table
            footer
        }
        // GT drills on activation rather than on merely selecting a row. Watching
        // for the second click leaves the table's own handling of the first alone,
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
        .onChange(of: view) { query = "" }
        // A view switch or refresh reloads at once; typing waits a beat first, so
        // a burst of keystrokes coalesces into one request against the image.
        .task(id: "\(view)\u{1}\(reloadToken)\u{1}\(query)") {
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            await reload()
        }
    }

    private var table: some View {
        Table(loaded.rows, selection: $selection) {
            TableColumnForEach(Array(loaded.columns.enumerated()), id: \.offset) { column, title in
                TableColumn(title) { row in
                    cell(row.cells[column], isIndex: column == 0)
                }
                .width(column == 0 ? indexColumnWidth : nil)
            }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, let row = loaded.rows.first(where: { $0.id == id }) {
                Button { copyRow(row) } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        }
        // A column-count change rebuilds the table rather than diffing a new
        // column onto rows still shaped for the old one, which AppKit traps on.
        .id(loaded.columns)
    }

    private func copyRow(_ row: Row) {
        let text = row.cells.dropFirst().compactMap { $0.text }.joined(separator: "\t")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private func cell(_ cell: PharoCell, isIndex: Bool) -> some View {
        if let png = cell.png, let image = NSImage(data: png) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Text(cell.text ?? "")
                .foregroundStyle(isIndex ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
        }
    }

    private var indexColumnWidth: CGFloat {
        let digits = max(String(loaded.total).count, 3)
        return CGFloat(digits) * PharoRowView.characterWidth + 24
    }

    @ViewBuilder
    private var footer: some View {
        if loaded.rows.count < loaded.total {
            Button("Show more (\(loaded.total - loaded.rows.count) left)") {
                Task { await loadNextPage() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }

        if let failure {
            Text(failure)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
    }

    private var filter: String? {
        query.isEmpty ? nil : query
    }

    private func drill(into index: Int) async {
        do {
            onSelect(try await runtime.drillInto(object, view: view, index: index + 1, filter: filter))
        } catch {
            failure = error.localizedDescription
        }
    }

    private func reload() async {
        loaded = Loaded(columns: columns)
        selection = nil
        failure = nil
        await loadNextPage()
    }

    private func loadNextPage() async {
        do {
            let page = try await runtime.items(
                of: object, view: view, from: loaded.rows.count + 1, count: pageSize, filter: filter)
            let rows = page.items.enumerated().map { offset, cells in
                Row(id: loaded.rows.count + offset, cells: cells)
            }
            loaded.total = page.total
            loaded.rows += rows
            if filter == nil { fullCount = page.total }
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
/// How a pane can be arranged, beyond the close and update its corner button
/// always offers. A pane that stands on its own -- a class opened in the text --
/// neither collapses nor maximizes; the first column of a drill cannot collapse.
struct PharoPaneActions {
    var canCollapse = false
    var canMaximize = false
    var onCollapse: () -> Void = {}
    var onMaximize: () -> Void = {}
}

/// The round button Glamorous Toolkit puts in a pane's corner. It opens a menu
/// of pane actions, unless a modifier is held: Command collapses the pane and
/// Command-Shift closes it, the icon changing to say which as the reader holds
/// the keys.
struct PharoPaneMenuButton: View {
    let isRevealed: Bool
    var canClose = true
    let actions: PharoPaneActions
    let onClose: () -> Void
    let onUpdate: () -> Void

    @State private var modifiers: NSEvent.ModifierFlags = []
    @State private var flagsMonitor: Any?

    private enum Mode { case menu, collapse, close }

    private var mode: Mode {
        let held = modifiers.intersection([.command, .shift])
        if canClose, held == [.command, .shift] { return .close }
        if actions.canCollapse, held == [.command] { return .collapse }
        return .menu
    }

    var body: some View {
        Button(action: activate) {
            PharoRoundIcon(systemName: icon)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help)
        .opacity(isRevealed ? 1 : 0)
        .allowsHitTesting(isRevealed)
        .onChange(of: isRevealed, initial: true) { _, revealed in
            revealed ? watchModifiers() : forgetModifiers()
        }
        .onDisappear(perform: forgetModifiers)
    }

    private func activate() {
        switch mode {
        case .menu: showMenu()
        case .collapse: actions.onCollapse()
        case .close: onClose()
        }
    }

    private var icon: String {
        switch mode {
        case .menu: "chevron.down"
        case .collapse: "poweron"
        case .close: "xmark"
        }
    }

    private var help: String {
        switch mode {
        case .menu: "Display menu"
        case .collapse: "Collapse pane"
        case .close: "Close pane"
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        var runners: [PharoMenuRunner] = []

        func add(_ title: String, _ symbol: String, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(PharoMenuRunner.fire), keyEquivalent: "")
            let runner = PharoMenuRunner(run)
            runners.append(runner)
            item.target = runner
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }

        if actions.canCollapse { add("Collapse pane", "poweron", actions.onCollapse) }
        if canClose { add("Close pane", "xmark", onClose) }
        if actions.canMaximize { add("Maximize pane", "arrow.up.left.and.arrow.down.right", actions.onMaximize) }
        add("Update pane tool", "arrow.clockwise", onUpdate)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func watchModifiers() {
        modifiers = NSEvent.modifierFlags
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            modifiers = event.modifierFlags
            return event
        }
    }

    private func forgetModifiers() {
        flagsMonitor.map(NSEvent.removeMonitor)
        flagsMonitor = nil
        modifiers = []
    }
}

/// Carries a menu item's action, since an NSMenuItem calls a selector rather
/// than a closure.
final class PharoMenuRunner: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func fire() {
        run()
    }
}

/// The round white disc a pane's corner buttons wear.
struct PharoRoundIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.pharoPane))
            .overlay(Circle().strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
    }
}

/// A run of collapsed panes, the way Glamorous Toolkit stacks them beside their
/// neighbours: a triangle pointing down into the stack, the panes as miniatures
/// below it, and an edge off the last one when an open pane follows.
struct PharoCollapsedStack: View {
    let objects: [PharoObject]
    let hasFollowingExpanded: Bool
    let onExpand: (PharoObject) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(Array(objects.enumerated()), id: \.element.handle) { index, object in
                PharoCollapsedMiniature(
                    object: object,
                    showsConnector: hasFollowingExpanded && index == objects.count - 1,
                    onExpand: { onExpand(object) })
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 8)
    }
}

/// One collapsed pane in a stack: a small badge that wears the accent on hover,
/// opens the pane on a click, and trails an edge to the open pane that follows.
struct PharoCollapsedMiniature: View {
    let object: PharoObject
    let showsConnector: Bool
    let onExpand: () -> Void

    @State private var isPointedAt = false

    var body: some View {
        Button(action: onExpand) {
            RoundedRectangle(cornerRadius: 3)
                .fill(isPointedAt ? Color.fridaBrand : Color.secondary.opacity(0.3))
                .frame(width: 22, height: 26)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { isPointedAt = $0 }
        .help("Expand \(object.className)")
        .overlay(alignment: .trailing) { if showsConnector { connector } }
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 10, height: 1.5)
            .offset(x: 10)
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
#endif
