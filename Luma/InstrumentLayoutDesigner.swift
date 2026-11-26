import LumaCore
import SwiftUI

struct InstrumentLayoutDesigner: View {
    let widgets: [InstrumentWidget]
    @Binding var layout: InstrumentLayout?
    var sample: InstrumentChildTemplate? = nil

    @State private var page: PreviewPage = .laptop
    @State private var pageHeight: Int = PreviewPage.laptop.height
    @State private var selection: [LayoutNodeID] = []
    @State private var chosenUnplaced: String?
    @FocusState private var isPreviewFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if let sample {
                    SampleChildRow(template: sample)
                }
                controls
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LayoutPreview(
                    widgets: widgets,
                    layout: current,
                    arrangement: arrangement,
                    pageHeight: CGFloat(pageHeight),
                    selected: Set(selection.compactMap(path(of:))),
                    onSelect: select,
                    onDrop: drop,
                    menu: { path in commandItems(on: [nodeID(at: path)]) }
                )
                .focusable()
                .focused($isPreviewFocused)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    step(press.key == .downArrow ? 1 : -1)
                    return .handled
                }
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    removeSelectionFromLayout() ? .handled : .ignored
                }
                #if os(macOS)
                    .onDeleteCommand { _ = removeSelectionFromLayout() }
                #endif
            }
            inspector
                .frame(width: 270)
        }
        .background { shortcutButtons }
    }

    private func removeSelectionFromLayout() -> Bool {
        guard let outcome = outcome(of: .removeFromLayout, on: selection) else { return false }
        apply(outcome)
        return true
    }

    private var current: InstrumentLayout {
        layout ?? .stack(of: widgets)
    }

    private var arrangement: InstrumentLayout.Arrangement {
        current.arranged(
            widgets: widgets, width: Double(page.width), height: Double(pageHeight), rowCounts: fullRowCounts, metrics: .page)
    }

    private var fullRowCounts: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: current.placedWidgetIDs.compactMap { id in
                guard widget(id).kind.showsRows else { return nil }
                return (id, current[current.path(of: id)!].maxRows ?? InstrumentLayout.defaultRowCap)
            })
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Width", selection: pageBinding) {
                ForEach(PreviewPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Preview width")
            HStack(spacing: 4) {
                Text("Height")
                TextField("Height", value: $pageHeight, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .labelsHidden()
                    .accessibilityLabel("Preview height")
                Text("pt")
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            Spacer()
            Menu("Arrange") {
                commandItems(on: selection)
            }
            .fixedSize()
            .accessibilityIdentifier("layoutDesigner.commands")
        }
    }

    private var pageBinding: Binding<PreviewPage> {
        Binding(
            get: { page },
            set: { newPage in
                page = newPage
                pageHeight = newPage.height
            })
    }

    private var status: String {
        let size = "\(page.width) × \(pageHeight)"
        let fit = arrangement.scrolls ? "scrolls, \(Int(arrangement.height)) tall" : "fills the page"
        let folded = arrangement.foldedRows.count
        let folds = folded == 0 ? "" : folded == 1 ? " · 1 row folded" : " · \(folded) rows folded"
        return "\(size) · \(fit)\(folds)"
    }

    @ViewBuilder
    private func commandItems(on targets: [LayoutNodeID]) -> some View {
        commandButton(.wrapInRow, on: targets)
        commandButton(.wrapInColumn, on: targets)
        commandButton(.unwrap, on: targets)
        Divider()
        commandButton(.moveUp, on: targets)
        commandButton(.moveDown, on: targets)
        commandButton(.moveLeft, on: targets)
        commandButton(.moveRight, on: targets)
        Divider()
        commandButton(.placeBelow, on: targets)
        commandButton(.placeBeside, on: targets)
        commandButton(.removeFromLayout, on: targets)
        Divider()
        commandButton(.resetToStack, on: targets)
    }

    private func commandButton(_ command: LayoutCommand, on targets: @autoclosure @escaping () -> [LayoutNodeID]) -> some View {
        Button(command.title) { perform(command, on: targets()) }
            .keyboardShortcut(command.shortcut)
            .disabled(outcome(of: command, on: targets()) == nil)
    }

    private func perform(_ command: LayoutCommand, on targets: [LayoutNodeID]) {
        guard let outcome = outcome(of: command, on: targets) else { return }
        apply(outcome)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Selection")
                    .font(.subheadline)
                GroupBox {
                    properties
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Unplaced")
                    .font(.subheadline)
                GroupBox {
                    unplacedList
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var properties: some View {
        if selection.count == 1, let path = path(of: selection[0]) {
            NodeProperties(
                title: title(at: path),
                node: current[path],
                kind: current[path].widgetID.map { widget($0).kind },
                isRoot: path.isEmpty,
                shareDefault: shareDefault(at: path),
                set: { key, value throws(InstrumentWidget.Problem) in
                    layout = try current.setting(key, to: value, at: path, widgets: widgets)
                }
            )
            .id(path)
        } else if selection.count > 1 {
            Text("\(selection.count) selected. Wrap them in a row or a column.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Select a widget or a container in the preview to set its size.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var unplacedList: some View {
        let unplaced = current.unplaced(in: widgets)
        if unplaced.isEmpty {
            Text("Every widget has a place.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Place each one below or beside the selection, or drag it onto the preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(unplaced, id: \.self) { id in
                    unplacedRow(id)
                }
            }
        }
    }

    private func unplacedRow(_ id: String) -> some View {
        let below = placed(id, .below, on: selection)
        let beside = placed(id, .trailing, on: selection)
        let isChosen = id == chosenUnplaced
        return HStack(spacing: 6) {
            Button {
                chosenUnplaced = isChosen ? nil : id
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(widget(id).designerTitle)
                    Text(widget(id).kind.designerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(widget(id).designerTitle), \(widget(id).kind.designerName)")
            .accessibilityAddTraits(isChosen ? .isSelected : [])
            Button("Below") { apply(below!) }
                .disabled(below == nil)
                .accessibilityLabel("Place \(widget(id).designerTitle) below")
            Button("Beside") { apply(beside!) }
                .disabled(beside == nil)
                .accessibilityLabel("Place \(widget(id).designerTitle) beside")
        }
        .controlSize(.small)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 5).fill(isChosen ? Color.accentColor.opacity(0.18) : .clear))
        .draggable(id)
    }

    private var shortcutButtons: some View {
        ZStack {
            ForEach(LayoutCommand.allCases) { command in
                commandButton(command, on: selection)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func select(_ path: InstrumentLayout.Path, extending: Bool) {
        let node = nodeID(at: path)
        isPreviewFocused = true
        guard extending else {
            selection = [node]
            return
        }
        if let index = selection.firstIndex(of: node) {
            selection.remove(at: index)
        } else {
            selection.append(node)
        }
    }

    private func drop(_ id: String, _ side: InstrumentLayout.Side, onto target: InstrumentLayout.Path) -> Bool {
        guard widgets.contains(where: { $0.id == id }), let outcome = placed(id, side, on: [nodeID(at: target)]) else { return false }
        apply(outcome)
        return true
    }

    private func step(_ delta: Int) {
        let paths = current.root.preorderPaths(at: [])
        let index = selection.first.flatMap(path(of:)).flatMap(paths.firstIndex(of:)) ?? (delta > 0 ? -1 : paths.count)
        let next = index + delta
        guard paths.indices.contains(next) else { return }
        selection = [nodeID(at: paths[next])]
    }

    private func outcome(of command: LayoutCommand, on targets: [LayoutNodeID]) -> LayoutOutcome? {
        switch command {
        case .wrapInRow: return wrapped(targets, as: .horizontal)
        case .wrapInColumn: return wrapped(targets, as: .vertical)
        case .unwrap: return unwrapped(targets)
        case .moveUp: return moved(targets, .up)
        case .moveDown: return moved(targets, .down)
        case .moveLeft: return moved(targets, .left)
        case .moveRight: return moved(targets, .right)
        case .placeBelow: return placingChosen(.below, on: targets)
        case .placeBeside: return placingChosen(.trailing, on: targets)
        case .removeFromLayout: return removed(targets)
        case .resetToStack: return layout == nil ? nil : LayoutOutcome(layout: nil, selection: [])
        }
    }

    private func wrapped(_ targets: [LayoutNodeID], as axis: InstrumentLayout.Axis) -> LayoutOutcome? {
        let paths = targets.compactMap(path(of:))
        guard !paths.isEmpty, paths.count == targets.count, paths.allSatisfy({ !$0.isEmpty }) else { return nil }
        let parent = Array(paths[0].dropLast())
        guard paths.allSatisfy({ $0.dropLast().elementsEqual(parent) }) else { return nil }
        let indices = paths.map { $0.last! }
        let range = indices.count == 1 ? indices[0]...(indices[0] + 1) : indices.min()!...indices.max()!
        guard range.upperBound < current[parent].entries.count,
            let result = try? current.wrapping(range, in: parent, as: axis)
        else { return nil }
        let wrapped = range.reduce(into: LayoutNodeID()) { ids, index in ids.formUnion(nodeID(at: parent + [index])) }
        return LayoutOutcome(layout: result, selection: [wrapped])
    }

    private func unwrapped(_ targets: [LayoutNodeID]) -> LayoutOutcome? {
        guard targets.count == 1, let path = path(of: targets[0]), current[path].axis != nil,
            let result = try? current.unwrapping(path)
        else { return nil }
        return LayoutOutcome(layout: result, selection: [nodeID(at: path + [0])])
    }

    private func moved(_ targets: [LayoutNodeID], _ direction: InstrumentLayout.Direction) -> LayoutOutcome? {
        guard targets.count == 1, let path = path(of: targets[0]), let result = try? current.moving(path, direction) else { return nil }
        return LayoutOutcome(layout: result, selection: targets)
    }

    private func placingChosen(_ side: InstrumentLayout.Side, on targets: [LayoutNodeID]) -> LayoutOutcome? {
        let unplaced = current.unplaced(in: widgets)
        let id = chosenUnplaced.flatMap { unplaced.contains($0) ? $0 : nil } ?? unplaced.first
        return id.flatMap { placed($0, side, on: targets) }
    }

    private func removed(_ targets: [LayoutNodeID]) -> LayoutOutcome? {
        guard targets.count == 1, let path = path(of: targets[0]), let id = current[path].widgetID else { return nil }
        return LayoutOutcome(layout: current.removing(id), selection: [])
    }

    private func placed(_ id: String, _ side: InstrumentLayout.Side, on targets: [LayoutNodeID]) -> LayoutOutcome? {
        guard targets.count <= 1 else { return nil }
        let target = targets.first.flatMap(path(of:)) ?? []
        guard let result = try? current.placing(id, side, of: target) else { return nil }
        return LayoutOutcome(layout: result, selection: [[id]])
    }

    private func apply(_ outcome: LayoutOutcome) {
        layout = outcome.layout
        selection = outcome.selection
    }

    private func nodeID(at path: InstrumentLayout.Path) -> LayoutNodeID {
        Set(current.placedWidgetIDs.filter { current.path(of: $0)!.starts(with: path) })
    }

    private func path(of node: LayoutNodeID) -> InstrumentLayout.Path? {
        let paths = node.compactMap(current.path(of:))
        guard !paths.isEmpty, paths.count == node.count else { return nil }
        return paths.dropFirst().reduce(paths[0]) { prefix, path in
            Array(zip(prefix, path).prefix { $0 == $1 }.map(\.0))
        }
    }

    private func title(at path: InstrumentLayout.Path) -> String {
        let node = current[path]
        if let id = node.widgetID {
            return "\(widget(id).designerTitle) · \(widget(id).kind.designerName)"
        }
        let name = path.isEmpty ? "The page" : node.axis == .horizontal ? "Row" : "Column"
        let folded = arrangement.foldedRows.contains(path) ? ", folded at this width" : ""
        return "\(name) · \(node.entries.count) entries\(folded)"
    }

    private func shareDefault(at path: InstrumentLayout.Path) -> String {
        guard !path.isEmpty else { return "" }
        return current[Array(path.dropLast())].axis == .horizontal ? "1, an equal width" : "natural height"
    }

    private func widget(_ id: String) -> InstrumentWidget {
        widgets.first { $0.id == id }!
    }
}

typealias LayoutNodeID = Set<String>

private struct SampleChildRow: View {
    let template: InstrumentChildTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sidebar row, with sample text:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ChildTemplateIcon(template: template)
                    .foregroundStyle(.secondary)
                ChildRowText(title: "Sample \(template.id)", subtitle: "subtitle", badge: ("active", .active))
            }
            .font(.callout)
            .padding(6)
            .frame(width: 240)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            .accessibilityElement(children: .combine)
        }
    }
}

private struct LayoutOutcome {
    let layout: InstrumentLayout?
    let selection: [LayoutNodeID]
}

private enum LayoutCommand: CaseIterable, Identifiable {
    case wrapInRow
    case wrapInColumn
    case unwrap
    case moveUp
    case moveDown
    case moveLeft
    case moveRight
    case placeBelow
    case placeBeside
    case removeFromLayout
    case resetToStack

    var id: Self { self }

    var title: String {
        switch self {
        case .wrapInRow: return "Wrap in Row"
        case .wrapInColumn: return "Wrap in Column"
        case .unwrap: return "Unwrap"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .placeBelow: return "Place Below"
        case .placeBeside: return "Place Beside"
        case .removeFromLayout: return "Remove from Layout"
        case .resetToStack: return "Reset to Stack"
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .wrapInRow: return KeyboardShortcut("r", modifiers: [.option, .command])
        case .wrapInColumn: return KeyboardShortcut("c", modifiers: [.option, .command])
        case .unwrap: return KeyboardShortcut("u", modifiers: [.option, .command])
        case .moveUp: return KeyboardShortcut(.upArrow, modifiers: [.option, .command])
        case .moveDown: return KeyboardShortcut(.downArrow, modifiers: [.option, .command])
        case .moveLeft: return KeyboardShortcut(.leftArrow, modifiers: [.option, .command])
        case .moveRight: return KeyboardShortcut(.rightArrow, modifiers: [.option, .command])
        case .placeBelow: return KeyboardShortcut("p", modifiers: [.option, .command])
        case .placeBeside: return KeyboardShortcut("b", modifiers: [.option, .command])
        case .removeFromLayout: return nil
        case .resetToStack: return KeyboardShortcut("0", modifiers: [.option, .command])
        }
    }
}

private enum PreviewPage: CaseIterable, Identifiable {
    case wide
    case laptop
    case phone

    var id: Self { self }

    var title: String {
        switch self {
        case .wide: return "Wide 1400"
        case .laptop: return "Laptop 800"
        case .phone: return "Phone 390"
        }
    }

    var width: Int {
        switch self {
        case .wide: return 1400
        case .laptop: return 800
        case .phone: return 390
        }
    }

    var height: Int {
        switch self {
        case .wide: return 900
        case .laptop: return 700
        case .phone: return 760
        }
    }
}

private struct NodeProperties: View {
    let title: String
    let node: InstrumentLayout.Node
    let kind: InstrumentWidget.Kind?
    let isRoot: Bool
    let shareDefault: String
    let set: (InstrumentLayout.SizeKey, Int?) throws(InstrumentWidget.Problem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if isRoot {
                Text("The page has no size of its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SizeField(title: "Share", value: node.share, defaultText: shareDefault) { value throws(InstrumentWidget.Problem) in
                    try set(.share, value)
                }
            }
            if kind?.showsRows == true {
                SizeField(title: "Max rows", value: node.maxRows, defaultText: "\(InstrumentLayout.defaultRowCap) rows") {
                    value throws(InstrumentWidget.Problem) in
                    try set(.maxRows, value)
                }
            }
            if node.axis == .horizontal {
                SizeField(title: "Fold below", value: node.foldBelow, defaultText: "folds below \(defaultFoldWidth) pt") {
                    value throws(InstrumentWidget.Problem) in
                    try set(.foldBelow, value)
                }
            }
        }
    }

    private var defaultFoldWidth: Int {
        Int(Double(node.entries.count) * InstrumentLayout.foldWidthPerEntry)
    }
}

private struct SizeField: View {
    let title: String
    let value: Int?
    let defaultText: String
    let apply: (Int?) throws(InstrumentWidget.Problem) -> Void

    @State private var text = ""
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .frame(width: 72, alignment: .leading)
                TextField(title, text: $text, prompt: Text("Default"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 64)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .accessibilityLabel(title)
                    .accessibilityHint("Empty means the default: \(defaultText)")
                Text(defaultText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: value, initial: true) { _, value in
            text = value.map(String.init) ?? ""
            problem = nil
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                commit()
            }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || Int(trimmed) != nil else {
            problem = "has to be a whole number"
            return
        }
        let entered = Int(trimmed)
        guard entered != value else { return }
        do {
            try apply(entered)
            problem = nil
        } catch {
            problem = error.text
        }
    }
}

private struct LayoutPreview<NodeMenu: View>: View {
    let widgets: [InstrumentWidget]
    let layout: InstrumentLayout
    let arrangement: InstrumentLayout.Arrangement
    let pageHeight: CGFloat
    let selected: Set<InstrumentLayout.Path>
    let onSelect: (InstrumentLayout.Path, Bool) -> Void
    let onDrop: (String, InstrumentLayout.Side, InstrumentLayout.Path) -> Bool
    @ViewBuilder let menu: (InstrumentLayout.Path) -> NodeMenu

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                canvas(scale: min(1, proxy.size.width / max(arrangement.width, 1)))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout preview")
    }

    private func canvas(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            pageArea(scale: scale)
            ForEach(containerPaths, id: \.self) { path in
                container(at: path, scale: scale)
            }
            ForEach(layout.placedWidgetIDs, id: \.self) { id in
                box(for: id, scale: scale)
            }
            ForEach(containerPaths, id: \.self) { path in
                containerTag(at: path, scale: scale)
            }
        }
        .frame(
            width: arrangement.width * scale,
            height: max(arrangement.height, pageHeight) * scale,
            alignment: .topLeading)
    }

    private var containerPaths: [InstrumentLayout.Path] {
        arrangement.containerFrames.keys.filter { !$0.isEmpty }.sorted { $0.count < $1.count }
    }

    private func pageArea(scale: CGFloat) -> some View {
        Button {
            onSelect([], isExtendingSelection)
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    selected.contains([]) ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: selected.contains([]) ? 2 : 1, dash: [6, 4])
                )
                .background(Color.secondary.opacity(0.05))
                .contentShape(Rectangle())
                .frame(width: arrangement.width * scale, height: pageHeight * scale)
        }
        .buttonStyle(.plain)
        .contextMenu { menu([]) }
        .accessibilityLabel("The page, \(Int(arrangement.width)) by \(Int(pageHeight)) points")
        .accessibilityAddTraits(selected.contains([]) ? .isSelected : [])
    }

    private func container(at path: InstrumentLayout.Path, scale: CGFloat) -> some View {
        let frame = arrangement.containerFrames[path]!
        let isSelected = selected.contains(path)
        let node = layout[path]
        return Button {
            onSelect(path, isExtendingSelection)
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.accentColor : outlineColor(path),
                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [4, 3])
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: frame.width * scale + 2 * Self.outset, height: frame.height * scale + 2 * Self.outset)
        .offset(x: frame.x * scale - Self.outset, y: frame.y * scale - Self.outset)
        .contextMenu { menu(path) }
        .dropDestination(for: String.self) { items, location in
            drop(items, at: location, size: CGSize(width: frame.width * scale, height: frame.height * scale), onto: path)
        }
        .accessibilityLabel(containerLabel(node, at: path))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func box(for id: String, scale: CGFloat) -> some View {
        let frame = arrangement.frames[id]!
        let path = layout.path(of: id)!
        let isSelected = selected.contains(path)
        let widget = widgets.first { $0.id == id }!
        return Button {
            onSelect(path, isExtendingSelection)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(widget.designerTitle)
                    .font(.caption.weight(.semibold))
                Text(widget.kind.designerName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(isSelected ? 0.28 : 0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(isSelected ? 1 : 0.4), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: frame.width * scale, height: frame.height * scale)
        .offset(x: frame.x * scale, y: frame.y * scale)
        .contextMenu { menu(path) }
        .draggable(id)
        .dropDestination(for: String.self) { items, location in
            drop(items, at: location, size: CGSize(width: frame.width * scale, height: frame.height * scale), onto: path)
        }
        .accessibilityLabel("\(widget.designerTitle), \(widget.kind.designerName)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func containerTag(at path: InstrumentLayout.Path, scale: CGFloat) -> some View {
        let frame = arrangement.containerFrames[path]!
        let isFolded = arrangement.foldedRows.contains(path)
        let name = layout[path].axis == .horizontal ? (isFolded ? "Row · folded" : "Row") : "Column"
        return Text(name)
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(Capsule().fill(outlineColor(path).opacity(0.2)))
            .background(Capsule().fill(.background))
            .foregroundStyle(isFolded ? Color.orange : Color.secondary)
            .frame(width: frame.width * scale, alignment: .trailing)
            .offset(x: frame.x * scale - Self.outset - 2, y: frame.y * scale - Self.outset - 7)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static var outset: CGFloat { 3 }

    private func outlineColor(_ path: InstrumentLayout.Path) -> Color {
        arrangement.foldedRows.contains(path) ? .orange : .secondary
    }

    private func containerLabel(_ node: InstrumentLayout.Node, at path: InstrumentLayout.Path) -> String {
        let name = node.axis == .horizontal ? "Row" : "Column"
        let folded = arrangement.foldedRows.contains(path) ? ", folded" : ""
        return "\(name), \(node.entries.count) entries\(folded)"
    }

    private func drop(_ items: [String], at location: CGPoint, size: CGSize, onto path: InstrumentLayout.Path) -> Bool {
        guard let id = items.first else { return false }
        let distances: [(InstrumentLayout.Side, CGFloat)] = [
            (.leading, location.x / size.width),
            (.trailing, 1 - location.x / size.width),
            (.above, location.y / size.height),
            (.below, 1 - location.y / size.height),
        ]
        return onDrop(id, distances.min { $0.1 < $1.1 }!.0, path)
    }

    private var isExtendingSelection: Bool {
        #if os(macOS)
        !NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty
        #else
        false
        #endif
    }
}

extension InstrumentLayout.Node {
    fileprivate func preorderPaths(at path: InstrumentLayout.Path) -> [InstrumentLayout.Path] {
        [path] + entries.indices.flatMap { entries[$0].preorderPaths(at: path + [$0]) }
    }
}

extension InstrumentWidget {
    fileprivate var designerTitle: String {
        title ?? id
    }
}

extension InstrumentWidget.Kind {
    var showsRows: Bool {
        switch self {
        case .list, .table: return true
        default: return false
        }
    }

    fileprivate var designerName: String {
        WidgetKindChoice(from: self).label
    }
}
