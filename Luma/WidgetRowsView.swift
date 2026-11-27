import LumaCore
import SwiftUI

enum WidgetRowContent: Equatable {
    case list([WidgetListItem])
    case table(columns: [InstrumentWidget.Column], rows: [WidgetTableRow])

    var columns: [InstrumentWidget.Column]? {
        switch self {
        case .list: nil
        case .table(let columns, _): columns
        }
    }

    var count: Int {
        switch self {
        case .list(let items): items.count
        case .table(_, let rows): rows.count
        }
    }

    func id(at index: Int) -> String {
        switch self {
        case .list(let items): items[index].id
        case .table(_, let rows): rows[index].id
        }
    }

    var ids: [String] {
        switch self {
        case .list(let items): items.map(\.id)
        case .table(_, let rows): rows.map(\.id)
        }
    }

    func hasSameRow(at index: Int, as other: WidgetRowContent, at otherIndex: Int) -> Bool {
        switch (self, other) {
        case (.list(let items), .list(let others)): items[index] == others[otherIndex]
        case (.table(_, let rows), .table(_, let others)): rows[index] == others[otherIndex]
        default: false
        }
    }

    func index(of id: String) -> Int? {
        switch self {
        case .list(let items): items.firstIndex { $0.id == id }
        case .table(_, let rows): rows.firstIndex { $0.id == id }
        }
    }

    func copiedText(at index: Int) -> String {
        switch self {
        case .list(let items): items[index].copiedText
        case .table(let columns, let rows): rows[index].copiedText(columns: columns)
        }
    }

    func typeSelectText(at index: Int) -> String {
        switch self {
        case .list(let items): items[index].title
        case .table(let columns, let rows): columns.first.flatMap { rows[index].cells[$0.id] } ?? ""
        }
    }

    func isTwoLine(at index: Int) -> Bool {
        switch self {
        case .list(let items): items[index].subtitle != nil
        case .table: false
        }
    }
}

struct WidgetRowActions {
    var buttons: [InstrumentWidget.Action]
    var activation: InstrumentWidget.Action?
    var selection: InstrumentWidget.Action?
    var isEnabled: Bool
    var refusal: String?
    var invoke: (_ action: String, _ item: String) -> Void

    var menuActions: [InstrumentWidget.Action] {
        (activation.map { [$0] } ?? []) + buttons
    }
}

@MainActor
final class WidgetRowsFocus {
    fileprivate var focusRows: () -> Void = {}

    func focus() {
        focusRows()
    }
}

enum WidgetRowsMetrics {
    static var selectionSettleDelay: Duration {
        #if os(macOS)
        .seconds(NSEvent.keyRepeatInterval * 1.5)
        #else
        .milliseconds(150)
        #endif
    }
    static var minimumColumnCharacters: Int { 6 }
    static var sampledRowsForColumnWidths: Int { 200 }
    static var largestIncrementalChange: Int { 500 }
}

struct WidgetRowChanges {
    enum Kind {
        case none
        case incremental(removals: IndexSet, insertions: IndexSet, reloads: IndexSet)
        case wholesale
    }

    let kind: Kind

    init(from previous: WidgetRowContent, to content: WidgetRowContent) {
        guard content != previous else {
            kind = .none
            return
        }
        let previousIDs = previous.ids
        let ids = content.ids
        let difference = ids.difference(from: previousIDs)
        guard difference.count <= WidgetRowsMetrics.largestIncrementalChange else {
            kind = .wholesale
            return
        }
        kind = .incremental(
            removals: IndexSet(difference.removals.map(\.offset)),
            insertions: IndexSet(difference.insertions.map(\.offset)),
            reloads: Self.rowsWhoseValueChanged(in: content, ids: ids, since: previous, previousIDs: previousIDs))
    }

    private static func rowsWhoseValueChanged(
        in content: WidgetRowContent, ids: [String], since previous: WidgetRowContent, previousIDs: [String]
    ) -> IndexSet {
        if ids == previousIDs {
            return IndexSet(ids.indices.filter { !content.hasSameRow(at: $0, as: previous, at: $0) })
        }
        let previousIndex = Dictionary(previousIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return IndexSet(ids.indices.filter { index in
            previousIndex[ids[index]].map { !content.hasSameRow(at: index, as: previous, at: $0) } ?? false
        })
    }
}

private extension CollectionDifference.Change {
    var offset: Int {
        switch self {
        case .insert(let offset, _, _), .remove(let offset, _, _): offset
        }
    }
}

private extension InstrumentWidget.Column.Alignment {
    var textAlignment: NSTextAlignment {
        self == .leading ? .left : .right
    }
}

#if os(macOS)

struct WidgetRowsView: NSViewRepresentable {
    let content: WidgetRowContent
    let actions: WidgetRowActions
    let focus: WidgetRowsFocus

    func makeCoordinator() -> WidgetRowsController {
        WidgetRowsController(content: content, actions: actions)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView(focus: focus)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(content: content, actions: actions)
    }
}

@MainActor
final class WidgetRowsController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var content: WidgetRowContent
    private var actions: WidgetRowActions
    private let tableView = WidgetRowsTableView()
    private var selectedID: String?
    private var hoveredRow: Int?
    private var revealedSelectedRow: Int?
    private var isRestoringSelection = false
    private var pendingSelectionAction: Task<Void, Never>?
    private var hasSizedColumns = false

    init(content: WidgetRowContent, actions: WidgetRowActions) {
        self.content = content
        self.actions = actions
    }

    func makeScrollView(focus: WidgetRowsFocus) -> NSScrollView {
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: Self.columnSpacing, height: 0)
        tableView.rowHeight = InstrumentLayout.Metrics.page.rowHeight
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateClickedRow)
        tableView.menu = makeMenu()
        tableView.onHoverRow = { [weak self] row in self?.hover(row) }
        tableView.onActivateSelection = { [weak self] in self?.activateSelectedRow() }
        tableView.onCopy = { [weak self] in self?.copySelectedRow() }
        focus.focusRows = { [weak self] in self?.focusRows() }
        configureColumns()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        return scrollView
    }

    func update(content newContent: WidgetRowContent, actions newActions: WidgetRowActions) {
        let columnsChanged = newContent.columns != content.columns || newActions.buttons != actions.buttons
        let gateChanged = newActions.isEnabled != actions.isEnabled || newActions.refusal != actions.refusal
        let changes = WidgetRowChanges(from: content, to: newContent)
        content = newContent
        actions = newActions
        if columnsChanged {
            configureColumns()
            hasSizedColumns = false
            reloadKeepingSelection()
        } else {
            apply(changes)
        }
        if gateChanged {
            refreshVisibleActions()
        }
        sizeColumnsOnce()
    }

    private static let columnSpacing: CGFloat = 8
    private static let actionsColumn = NSUserInterfaceItemIdentifier("actions")
    private static let itemColumn = NSUserInterfaceItemIdentifier("item")

    private func configureColumns() {
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
        guard let columns = content.columns else {
            let column = NSTableColumn(identifier: Self.itemColumn)
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
            tableView.headerView = nil
            return
        }
        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column.\(index)"))
            tableColumn.title = column.name
            tableColumn.headerCell.alignment = column.alignment.textAlignment
            tableColumn.minWidth = WidgetTextCell.width(ofCharacters: WidgetRowsMetrics.minimumColumnCharacters)
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableView.addTableColumn(tableColumn)
        }
        if !actions.buttons.isEmpty {
            let actionsColumn = NSTableColumn(identifier: Self.actionsColumn)
            actionsColumn.title = ""
            actionsColumn.width = WidgetRowActionsView.width(of: actions.buttons)
            actionsColumn.minWidth = actionsColumn.width
            actionsColumn.maxWidth = actionsColumn.width
            actionsColumn.resizingMask = []
            tableView.addTableColumn(actionsColumn)
        }
        let header = NSTableHeaderView()
        header.frame.size.height = InstrumentLayout.Metrics.page.tableHeaderHeight
        tableView.headerView = header
    }

    @objc private func viewportChanged() {
        sizeColumnsOnce()
    }

    private func sizeColumnsOnce() {
        guard !hasSizedColumns, case .table(let columns, let rows) = content, !rows.isEmpty,
            let viewport = tableView.enclosingScrollView?.contentSize.width, viewport > 0
        else { return }
        hasSizedColumns = true
        let sample = rows.prefix(WidgetRowsMetrics.sampledRowsForColumnWidths)
        let fixed = tableView.tableColumns.dropFirst(columns.count).reduce(0) { $0 + $1.width }
        let available = viewport - fixed - tableView.intercellSpacing.width * CGFloat(tableView.numberOfColumns)
        let widths = Self.fitted(columns.map { contentWidth(of: $0, in: sample) }, into: available)
        for (index, width) in widths.enumerated() {
            tableView.tableColumns[index].width = width
        }
    }

    private static func fitted(_ natural: [CGFloat], into available: CGFloat) -> [CGFloat] {
        let total = natural.reduce(0, +)
        guard total > available else {
            var widths = natural
            widths[0] += available - total
            return widths
        }
        var cap = available / CGFloat(natural.count)
        var kept: CGFloat = 0
        for (index, width) in natural.sorted().enumerated() {
            let share = (available - kept) / CGFloat(natural.count - index)
            guard width <= share else {
                cap = share
                break
            }
            kept += width
        }
        let floor = WidgetTextCell.width(ofCharacters: WidgetRowsMetrics.minimumColumnCharacters)
        return natural.map { min($0, max(cap, floor)) }
    }

    private func contentWidth(of column: InstrumentWidget.Column, in rows: some Sequence<WidgetTableRow>) -> CGFloat {
        let longest = rows.reduce(0) { max($0, ($1.cells[column.id] ?? "").count) }
        return max(WidgetTextCell.width(ofCharacters: longest), WidgetTextCell.headerWidth(of: column.name))
    }

    private func apply(_ changes: WidgetRowChanges) {
        switch changes.kind {
        case .none:
            break
        case .wholesale:
            reloadKeepingSelection()
        case .incremental(let removals, let insertions, let reloads):
            isRestoringSelection = true
            defer { isRestoringSelection = false }
            if !removals.isEmpty || !insertions.isEmpty {
                tableView.beginUpdates()
                tableView.removeRows(at: removals, withAnimation: [])
                tableView.insertRows(at: insertions, withAnimation: [])
                tableView.endUpdates()
            }
            if !reloads.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: reloads)
                tableView.reloadData(forRowIndexes: reloads, columnIndexes: IndexSet(tableView.tableColumns.indices))
            }
        }
    }

    private func reloadKeepingSelection() {
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        tableView.reloadData()
        if let selectedID, let index = content.index(of: selectedID) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        revealedSelectedRow = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        hoveredRow = tableView.hoveredRow
    }

    private func refreshVisibleActions() {
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.lowerBound..<visible.upperBound {
            actionsView(at: row)?.update(isEnabled: actions.isEnabled, refusal: actions.refusal)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        content.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        switch content {
        case .list(let items):
            let cell = reused(WidgetListItemCell.self, as: WidgetListItemCell.identifier) { WidgetListItemCell() }
            cell.show(items[row])
            configure(cell.actionsView, row: row)
            return cell
        case .table(let columns, let rows):
            if tableColumn.identifier == Self.actionsColumn {
                let cell = reused(WidgetRowActionsView.self, as: WidgetRowActionsView.identifier) { WidgetRowActionsView() }
                configure(cell, row: row)
                return cell
            }
            let column = columns[tableView.column(withIdentifier: tableColumn.identifier)]
            let cell = reused(WidgetTextCell.self, as: WidgetTextCell.identifier) { WidgetTextCell() }
            cell.show(rows[row].cells[column.id] ?? "", alignment: column.alignment.textAlignment)
            return cell
        }
    }

    private func reused<Cell: NSView>(_ type: Cell.Type, as identifier: NSUserInterfaceItemIdentifier, make: () -> Cell) -> Cell {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell {
            return cell
        }
        let cell = make()
        cell.identifier = identifier
        return cell
    }

    private func configure(_ actionsView: WidgetRowActionsView, row: Int) {
        let item = content.id(at: row)
        actionsView.show(actions.buttons, isEnabled: actions.isEnabled, refusal: actions.refusal) { [weak self] action in
            self?.actions.invoke(action, item)
        }
        actionsView.isHidden = !isRevealed(row)
    }

    private func isRevealed(_ row: Int) -> Bool {
        row == hoveredRow || row == tableView.selectedRow
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        content.isTwoLine(at: row) ? InstrumentLayout.Metrics.page.twoLineRowHeight : InstrumentLayout.Metrics.page.rowHeight
    }

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn index: Int) -> CGFloat {
        guard case .table(let columns, let rows) = content, columns.indices.contains(index) else {
            return tableView.tableColumns[index].width
        }
        return contentWidth(of: columns[index], in: rows)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        content.typeSelectText(at: row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        let previous = revealedSelectedRow
        revealedSelectedRow = row
        refreshReveal(of: [previous, row])
        guard !isRestoringSelection else { return }
        selectedID = row.map(content.id(at:))
        runSelectionActionOnceSettled()
    }

    private func runSelectionActionOnceSettled() {
        pendingSelectionAction?.cancel()
        guard let selection = actions.selection, actions.isEnabled, let selectedID else { return }
        pendingSelectionAction = Task { [weak self] in
            do {
                try await Task.sleep(for: WidgetRowsMetrics.selectionSettleDelay)
            } catch {
                return
            }
            self?.actions.invoke(selection.id, selectedID)
        }
    }

    private func hover(_ row: Int?) {
        let previous = hoveredRow
        hoveredRow = row
        refreshReveal(of: [previous, row])
    }

    private func refreshReveal(of rows: [Int?]) {
        for row in rows.compactMap({ $0 }) where row < content.count {
            actionsView(at: row)?.isHidden = !isRevealed(row)
        }
    }

    private func actionsView(at row: Int) -> WidgetRowActionsView? {
        switch content {
        case .list:
            return (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WidgetListItemCell)?.actionsView
        case .table:
            let column = tableView.column(withIdentifier: Self.actionsColumn)
            guard column >= 0 else { return nil }
            return tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? WidgetRowActionsView
        }
    }

    @objc private func activateClickedRow() {
        guard tableView.clickedRow >= 0 else { return }
        activate(row: tableView.clickedRow)
    }

    private func activateSelectedRow() {
        guard tableView.selectedRow >= 0 else { return }
        activate(row: tableView.selectedRow)
    }

    private func activate(row: Int) {
        guard let activation = actions.activation, actions.isEnabled else { return }
        actions.invoke(activation.id, content.id(at: row))
    }

    private func copySelectedRow() {
        guard tableView.selectedRow >= 0 else { return }
        Platform.copyToClipboard(content.copiedText(at: tableView.selectedRow))
    }

    private func focusRows() {
        tableView.window?.makeFirstResponder(tableView)
        guard tableView.selectedRow < 0, content.count > 0 else { return }
        tableView.selectRowIndexes([0], byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        let item = content.id(at: row)
        for action in actions.menuActions {
            let menuItem = NSMenuItem(title: action.name, action: #selector(invokeMenuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = WidgetRowInvocation(action: action.id, item: item)
            menuItem.isEnabled = actions.isEnabled
            menu.addItem(menuItem)
        }
        if !actions.menuActions.isEmpty {
            menu.addItem(.separator())
        }
        let copy = NSMenuItem(title: "Copy Row", action: #selector(copyClickedRow(_:)), keyEquivalent: "")
        copy.target = self
        copy.tag = row
        menu.addItem(copy)
    }

    @objc private func invokeMenuAction(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? WidgetRowInvocation else { return }
        actions.invoke(invocation.action, invocation.item)
    }

    @objc private func copyClickedRow(_ sender: NSMenuItem) {
        Platform.copyToClipboard(content.copiedText(at: sender.tag))
    }
}

private final class WidgetRowInvocation: NSObject {
    let action: String
    let item: String

    init(action: String, item: String) {
        self.action = action
        self.item = item
    }
}

final class WidgetRowsTableView: NSTableView {
    var onHoverRow: (Int?) -> Void = { _ in }
    var onActivateSelection: () -> Void = {}
    var onCopy: () -> Void = {}
    private(set) var hoveredRow: Int?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        noteHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard let window else { return }
        noteHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func noteHover(at point: NSPoint) {
        let row = visibleRect.contains(point) ? row(at: point) : -1
        setHoveredRow(row >= 0 ? row : nil)
    }

    private func setHoveredRow(_ row: Int?) {
        guard row != hoveredRow else { return }
        hoveredRow = row
        onHoverRow(row)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Self.returnKey, Self.enterKey:
            onActivateSelection()
        default:
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        onCopy()
    }

    private static let returnKey: UInt16 = 36
    private static let enterKey: UInt16 = 76
}

final class WidgetTextCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("text")

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(_ text: String, alignment: NSTextAlignment) {
        label.stringValue = text
        label.alignment = alignment
    }

    static func width(ofCharacters count: Int) -> CGFloat {
        (CGFloat(count) * advance).rounded(.up) + 4
    }

    static func headerWidth(of title: String) -> CGFloat {
        NSTableHeaderCell(textCell: title).cellSize.width.rounded(.up)
    }

    private static let font = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)

    private static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
}

final class WidgetListItemCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("item")

    let actionsView = WidgetRowActionsView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")
    private var titleCenter: NSLayoutConstraint!
    private var titleTop: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        let caption = NSFont.preferredFont(forTextStyle: .caption1)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = caption
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        accessory.font = caption
        accessory.textColor = .secondaryLabelColor
        for view in [title, subtitle, accessory, actionsView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleTop = title.topAnchor.constraint(equalTo: topAnchor, constant: 2)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
            subtitle.leadingAnchor.constraint(equalTo: leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
            accessory.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            accessory.trailingAnchor.constraint(equalTo: actionsView.leadingAnchor, constant: -8),
            actionsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionsView.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(_ item: WidgetListItem) {
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle == nil
        accessory.stringValue = item.accessory ?? ""
        titleCenter.isActive = item.subtitle == nil
        titleTop.isActive = item.subtitle != nil
    }
}

final class WidgetRowActionsView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("actions")

    private let stack = NSStackView()
    private var onPress: (String) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(_ actions: [InstrumentWidget.Action], isEnabled: Bool, refusal: String?, onPress: @escaping (String) -> Void) {
        self.onPress = onPress
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        if buttons.map(\.title) != actions.map(\.name) {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for action in actions {
                let button = Self.makeButton(action.name)
                button.identifier = NSUserInterfaceItemIdentifier(action.id)
                button.target = self
                button.action = #selector(press(_:))
                stack.addArrangedSubview(button)
            }
        }
        update(isEnabled: isEnabled, refusal: refusal)
    }

    func update(isEnabled: Bool, refusal: String?) {
        for case let button as NSButton in stack.arrangedSubviews {
            button.isEnabled = isEnabled
            button.toolTip = isEnabled ? nil : refusal
        }
    }

    @objc private func press(_ sender: NSButton) {
        guard let action = sender.identifier?.rawValue else { return }
        onPress(action)
    }

    static func width(of actions: [InstrumentWidget.Action]) -> CGFloat {
        let buttons = actions.map { makeButton($0.name).fittingSize.width }
        return buttons.reduce(0, +) + spacing * CGFloat(max(buttons.count - 1, 0))
    }

    private static let spacing: CGFloat = 4

    private static func makeButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        return button
    }
}

#else

struct WidgetRowsView: UIViewRepresentable {
    let content: WidgetRowContent
    let actions: WidgetRowActions
    let focus: WidgetRowsFocus

    func makeCoordinator() -> WidgetRowsController {
        WidgetRowsController(content: content, actions: actions)
    }

    func makeUIView(context: Context) -> UITableView {
        context.coordinator.makeTableView(focus: focus)
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.update(content: content, actions: actions)
    }
}

@MainActor
final class WidgetRowsController: NSObject, UITableViewDataSource, UITableViewDelegate {
    private var content: WidgetRowContent
    private var actions: WidgetRowActions
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var selectedID: String?
    private var pendingSelectionAction: Task<Void, Never>?
    private var columnShares: [CGFloat] = []

    init(content: WidgetRowContent, actions: WidgetRowActions) {
        self.content = content
        self.actions = actions
    }

    func makeTableView(focus: WidgetRowsFocus) -> UITableView {
        tableView.backgroundColor = .clear
        tableView.rowHeight = InstrumentLayout.Metrics.page.rowHeight
        tableView.sectionHeaderHeight = InstrumentLayout.Metrics.page.tableHeaderHeight
        tableView.sectionHeaderTopPadding = 0
        tableView.allowsSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(WidgetTableRowCell.self, forCellReuseIdentifier: WidgetTableRowCell.identifier)
        tableView.register(WidgetListItemCell.self, forCellReuseIdentifier: WidgetListItemCell.identifier)
        focus.focusRows = { [weak self] in _ = self?.tableView.becomeFirstResponder() }
        sizeColumns()
        return tableView
    }

    func update(content newContent: WidgetRowContent, actions newActions: WidgetRowActions) {
        let columnsChanged = newContent.columns != content.columns
        let changes = WidgetRowChanges(from: content, to: newContent)
        content = newContent
        actions = newActions
        if columnsChanged || columnShares.isEmpty {
            sizeColumns()
            reloadKeepingSelection()
            return
        }
        switch changes.kind {
        case .none:
            break
        case .wholesale:
            reloadKeepingSelection()
        case .incremental(let removals, let insertions, let reloads):
            tableView.performBatchUpdates {
                tableView.deleteRows(at: Self.paths(removals), with: .none)
                tableView.insertRows(at: Self.paths(insertions), with: .none)
            }
            tableView.reconfigureRows(at: Self.paths(reloads))
        }
    }

    private static func paths(_ rows: IndexSet) -> [IndexPath] {
        rows.map { IndexPath(row: $0, section: 0) }
    }

    private func sizeColumns() {
        guard case .table(let columns, let rows) = content, !rows.isEmpty else {
            columnShares = []
            return
        }
        let sample = rows.prefix(WidgetRowsMetrics.sampledRowsForColumnWidths)
        columnShares = columns.map { column in
            CGFloat(max(WidgetRowsMetrics.minimumColumnCharacters, sample.reduce(column.name.count) { max($0, ($1.cells[column.id] ?? "").count) }))
        }
    }

    private func reloadKeepingSelection() {
        tableView.reloadData()
        guard let selectedID, let index = content.index(of: selectedID) else { return }
        tableView.selectRow(at: IndexPath(row: index, section: 0), animated: false, scrollPosition: .none)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        content.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch content {
        case .list(let items):
            let cell = tableView.dequeueReusableCell(withIdentifier: WidgetListItemCell.identifier, for: indexPath) as! WidgetListItemCell
            cell.show(items[indexPath.row])
            return cell
        case .table(let columns, let rows):
            let cell = tableView.dequeueReusableCell(withIdentifier: WidgetTableRowCell.identifier, for: indexPath) as! WidgetTableRowCell
            cell.columns.show(columns.map { (rows[indexPath.row].cells[$0.id] ?? "", $0.alignment.textAlignment) }, shares: columnShares, color: .label)
            return cell
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        content.isTwoLine(at: indexPath.row) ? InstrumentLayout.Metrics.page.twoLineRowHeight : InstrumentLayout.Metrics.page.rowHeight
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let columns = content.columns else { return nil }
        let header = WidgetColumnsView()
        header.backgroundColor = .systemBackground
        header.show(columns.map { ($0.name, $0.alignment.textAlignment) }, shares: columnShares, color: .secondaryLabel)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        content.columns == nil ? 0 : InstrumentLayout.Metrics.page.tableHeaderHeight
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedID = content.id(at: indexPath.row)
        guard actions.selection != nil else {
            activate(row: indexPath.row)
            return
        }
        runSelectionActionOnceSettled()
    }

    private func runSelectionActionOnceSettled() {
        pendingSelectionAction?.cancel()
        guard let selection = actions.selection, actions.isEnabled, let selectedID else { return }
        pendingSelectionAction = Task { [weak self] in
            do {
                try await Task.sleep(for: WidgetRowsMetrics.selectionSettleDelay)
            } catch {
                return
            }
            self?.actions.invoke(selection.id, selectedID)
        }
    }

    private func activate(row: Int) {
        guard let activation = actions.activation, actions.isEnabled else { return }
        actions.invoke(activation.id, content.id(at: row))
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard actions.isEnabled, !actions.buttons.isEmpty else { return nil }
        let item = content.id(at: indexPath.row)
        let swipes = actions.buttons.reversed().map { action in
            let swipe = UIContextualAction(style: .normal, title: action.name) { [weak self] _, _, done in
                self?.actions.invoke(action.id, item)
                done(true)
            }
            swipe.backgroundColor = .tintColor
            return swipe
        }
        let configuration = UISwipeActionsConfiguration(actions: swipes)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let row = indexPath.row
        let item = content.id(at: row)
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            let invocations = self.actions.menuActions.map { action in
                UIAction(title: action.name, attributes: self.actions.isEnabled ? [] : .disabled) { [weak self] _ in
                    self?.actions.invoke(action.id, item)
                }
            }
            let copy = UIAction(title: "Copy Row", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                guard let self else { return }
                Platform.copyToClipboard(self.content.copiedText(at: row))
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: invocations), copy])
        })
    }
}

final class WidgetTableRowCell: UITableViewCell {
    static let identifier = "row"

    let columns = WidgetColumnsView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        columns.frame = contentView.bounds
        columns.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(columns)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }
}

final class WidgetColumnsView: UIView {
    private var labels: [UILabel] = []
    private var shares: [CGFloat] = []

    func show(_ cells: [(text: String, alignment: NSTextAlignment)], shares: [CGFloat], color: UIColor) {
        self.shares = shares
        while labels.count < cells.count {
            let label = UILabel()
            label.font = Self.font
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            labels.append(label)
        }
        for (label, cell) in zip(labels, cells) {
            label.text = cell.text
            label.textAlignment = cell.alignment
            label.textColor = color
        }
        for label in labels.dropFirst(cells.count) {
            label.text = nil
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.insetBy(dx: Self.inset, dy: 0)
        let gaps = Self.spacing * CGFloat(max(shares.count - 1, 0))
        let total = shares.reduce(0, +)
        var x = area.minX
        for (label, share) in zip(labels, shares) {
            let width = total > 0 ? (area.width - gaps) * share / total : 0
            label.frame = CGRect(x: x, y: area.minY, width: width, height: area.height)
            x += width + Self.spacing
        }
    }

    private static let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
    private static let inset: CGFloat = 16
    private static let spacing: CGFloat = 8
}

final class WidgetListItemCell: UITableViewCell {
    static let identifier = "item"

    private let accessory = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessory.font = .preferredFont(forTextStyle: .caption1)
        accessory.textColor = .secondaryLabel
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(_ item: WidgetListItem) {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = item.title
        configuration.secondaryText = item.subtitle
        configuration.secondaryTextProperties.color = .secondaryLabel
        contentConfiguration = configuration
        accessory.text = item.accessory
        accessory.sizeToFit()
        accessoryView = item.accessory == nil ? nil : accessory
    }
}

#endif
