import CGtk
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class InstrumentLayoutDesigner {
    typealias Path = InstrumentLayout.Path

    let widget: Box
    var onChange: () -> Void = {}

    private let read: () -> (widgets: [InstrumentWidget], layout: InstrumentLayout?)
    private let write: (InstrumentLayout?) -> Void
    private var preset = Preset.laptop
    private var pageHeight = 700
    private var selection: [Path] = []
    private var chosenUnplaced: String?
    private var extendsSelection = false
    private var draggedID: String?
    private var isRebuildingUnplaced = false
    private var boxes: [Path: Button] = [:]

    private let presetButtons: [ToggleButton]
    private let heightSpin = SpinButton(range: 200, max: 3000, step: 10)
    private let commandsButton = Button(label: "Arrange")
    private let summary = Label(str: "")
    private let canvas = Fixed()
    private let properties = Box(orientation: .vertical, spacing: 8)
    private let unplacedList = ListBox()
    private let unplacedEmpty = Label(str: "Every widget has a place.")
    private let problemNote = Label(str: "")
    private let sample = Box(orientation: .horizontal, spacing: 6)
    private let sampleLine = InstrumentChildLine(titleStyle: nil)
    private let sampleIcon = Box(orientation: .horizontal, spacing: 0)

    private static let canvasWidth = 720.0
    private static let sideWidth = 260

    init(read: @escaping () -> (widgets: [InstrumentWidget], layout: InstrumentLayout?), write: @escaping (InstrumentLayout?) -> Void) {
        self.read = read
        self.write = write
        presetButtons = Preset.allCases.map { ToggleButton(label: $0.title) }
        widget = Box(orientation: .vertical, spacing: 12)
        widget.marginStart = 16
        widget.marginEnd = 16
        widget.marginTop = 16
        widget.marginBottom = 16

        widget.append(child: makeToolbar())
        widget.append(child: makeSample())
        let body = Box(orientation: .horizontal, spacing: 12)
        body.vexpand = true
        body.append(child: makePreview())
        body.append(child: makeSide())
        widget.append(child: body)
        installShortcuts()
        refresh()
    }

    func setSample(_ template: InstrumentChildTemplate?) {
        sample.visible = template != nil
        guard let template else { return }
        while let icon = sampleIcon.firstChild {
            sampleIcon.remove(child: icon)
        }
        sampleIcon.append(child: InstrumentIconView.makeImage(for: .symbolic(template.symbol ?? ""), pixelSize: 14))
        sampleLine.show(title: "Sample \(template.id)", subtitle: "subtitle", badge: ("active", .active))
    }

    func refresh() {
        let draft = read()
        let layout = draft.layout ?? .stack(of: draft.widgets)
        selection = selection.filter { Self.exists($0, in: layout) }
        if let chosen = chosenUnplaced, !layout.unplaced(in: draft.widgets).contains(chosen) {
            chosenUnplaced = nil
        }
        rebuildCanvas(layout: layout, widgets: draft.widgets)
        rebuildProperties(layout: layout, widgets: draft.widgets)
        rebuildUnplaced(layout: layout, widgets: draft.widgets)
        refreshProblem(layout: draft.layout, widgets: draft.widgets)
    }

    private func makeToolbar() -> Box {
        let bar = Box(orientation: .horizontal, spacing: 12)

        let presets = Box(orientation: .horizontal, spacing: 0)
        presets.add(cssClass: "linked")
        for (preset, button) in zip(Preset.allCases, presetButtons) {
            button.tooltipText = "Preview at \(preset.width) points wide"
            button.active = preset == self.preset
            if button !== presetButtons[0] {
                button.set(group: ToggleButtonRef(presetButtons[0].toggle_button_ptr))
            }
            button.onToggled { [weak self] toggle in
                MainActor.assumeIsolated {
                    guard toggle.active, let self else { return }
                    self.preset = preset
                    self.heightSpin.value = Double(preset.height)
                    self.pageHeight = preset.height
                    self.refresh()
                }
            }
            presets.append(child: button)
        }
        bar.append(child: presets)

        let heightLabel = Label(str: "Page height")
        heightLabel.add(cssClass: "dim-label")
        bar.append(child: heightLabel)
        heightSpin.value = Double(pageHeight)
        heightSpin.tooltipText = "The height the page has below its header and settings"
        heightSpin.setAccessibleLabel("Page height")
        heightSpin.onValueChanged { [weak self] spin in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pageHeight = Int(spin.value)
                self.refresh()
            }
        }
        bar.append(child: heightSpin)

        summary.add(cssClass: "dim-label")
        summary.hexpand = true
        summary.xalign = 0
        summary.ellipsize = .end
        bar.append(child: summary)

        commandsButton.tooltipText = "Layout commands"
        commandsButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentCommands(at: self.commandsButton, x: 0, y: Double(self.commandsButton.height))
            }
        }
        bar.append(child: commandsButton)
        return bar
    }

    private func makeSample() -> Box {
        let caption = Label(str: "Sidebar row, with sample text:")
        caption.add(cssClass: "dim-label")
        sample.append(child: caption)
        sample.append(child: sampleIcon)
        sample.append(child: sampleLine.widget)
        sample.visible = false
        return sample
    }

    private func makePreview() -> ScrolledWindow {
        canvas.add(cssClass: "luma-layout-canvas")
        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        scroll.setSizeRequest(width: Int(Self.canvasWidth) + 16, height: 480)
        scroll.set(child: canvas)
        return scroll
    }

    private func makeSide() -> Box {
        let side = Box(orientation: .vertical, spacing: 12)
        side.setSizeRequest(width: Self.sideWidth, height: -1)

        let propertiesHeading = Self.heading("Selection")
        side.append(child: propertiesHeading)
        side.append(child: properties)

        side.append(child: Self.heading("Unplaced"))
        unplacedList.add(cssClass: "boxed-list")
        unplacedList.selectionMode = .single
        unplacedList.setAccessibleLabel("Unplaced widgets")
        unplacedList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, !self.isRebuildingUnplaced else { return }
                self.chosenUnplaced = row.flatMap { self.unplacedID(of: $0) }
            }
        }
        side.append(child: unplacedList)
        unplacedEmpty.add(cssClass: "dim-label")
        unplacedEmpty.halign = .start
        side.append(child: unplacedEmpty)

        problemNote.add(cssClass: "caption")
        problemNote.add(cssClass: "error")
        problemNote.halign = .start
        problemNote.xalign = 0
        problemNote.wrap = true
        side.append(child: problemNote)
        return side
    }

    private func installShortcuts() {
        let keys = EventControllerKey()
        keys.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self, let command = LayoutCommand.matching(keyval: keyval, state: state),
                    !command.needsPreviewFocus || self.previewHasFocus
                else { return false }
                return self.perform(command)
            }
        }
        widget.add(controller: keys)
    }

    private var previewHasFocus: Bool {
        boxes.values.contains { $0.hasFocus() }
    }

    @discardableResult
    private func perform(_ command: LayoutCommand) -> Bool {
        guard let outcome = outcome(of: command) else { return false }
        write(outcome.layout)
        let draft = read()
        let layout = draft.layout ?? .stack(of: draft.widgets)
        selection = outcome.selecting.flatMap { Self.path(holding: $0, in: layout.root) }.map { [$0] } ?? []
        if command.choosesFromUnplaced {
            chosenUnplaced = nil
        }
        refresh()
        onChange()
        focusSelection()
        return true
    }

    private func presentCommands(at anchor: Widget, x: Double, y: Double) {
        let sections = LayoutCommand.sections.map { section in
            section.map { command in
                ContextMenu.Item(command.title, detail: command.shortcutLabel, enabled: outcome(of: command) != nil) { [weak self] in
                    self?.perform(command)
                }
            }
        }
        ContextMenu.present(sections, at: anchor, x: x, y: y)
    }

    private func focusSelection() {
        guard let first = selection.first, let box = boxes[first] else { return }
        _ = box.grabFocus()
    }

    private func outcome(of command: LayoutCommand) -> Outcome? {
        let draft = read()
        let layout = draft.layout ?? .stack(of: draft.widgets)
        switch command {
        case .wrapInRow:
            return wrapped(layout, as: .horizontal)
        case .wrapInColumn:
            return wrapped(layout, as: .vertical)
        case .unwrap:
            guard let path = singleSelection, !path.isEmpty, layout[path].axis != nil,
                let result = try? layout.unwrapping(path)
            else { return nil }
            return Outcome(layout: result, selecting: nil)
        case .moveUp, .moveDown, .moveLeft, .moveRight:
            guard let path = singleSelection, let direction = command.direction, let result = try? layout.moving(path, direction) else {
                return nil
            }
            return Outcome(layout: result, selecting: Set(Self.widgetIDs(in: layout[path])))
        case .placeBelow, .placeBeside:
            guard let id = chosenUnplaced ?? layout.unplaced(in: draft.widgets).first, let side = command.side,
                let result = try? layout.placing(id, side, of: singleSelection ?? [])
            else { return nil }
            return Outcome(layout: result, selecting: [id])
        case .removeFromLayout:
            guard let path = singleSelection, let id = layout[path].widgetID else { return nil }
            return Outcome(layout: layout.removing(id), selecting: nil)
        case .resetToStack:
            guard draft.layout?.savable(for: draft.widgets) != nil else { return nil }
            return Outcome(layout: nil, selecting: nil)
        }
    }

    private var singleSelection: Path? {
        selection.count == 1 ? selection[0] : nil
    }

    private func wrapped(_ layout: InstrumentLayout, as axis: InstrumentLayout.Axis) -> Outcome? {
        guard let first = selection.first, !first.isEmpty else { return nil }
        let parent = Array(first.dropLast())
        let indices = selection.map { $0.last! }.sorted()
        let range: ClosedRange<Int>
        if indices.count == 1 {
            range = indices[0]...(indices[0] + 1)
        } else {
            guard indices.last! - indices.first! == indices.count - 1 else { return nil }
            range = indices.first!...indices.last!
        }
        guard range.upperBound < layout[parent].entries.count, let result = try? layout.wrapping(range, in: parent, as: axis) else {
            return nil
        }
        let ids = range.flatMap { Self.widgetIDs(in: layout[parent + [$0]]) }
        return Outcome(layout: result, selecting: Set(ids))
    }

    private func rebuildCanvas(layout: InstrumentLayout, widgets: [InstrumentWidget]) {
        while let child = canvas.firstChild {
            canvas.remove(widget: child)
        }
        boxes.removeAll()
        let width = Double(preset.width)
        let arrangement = layout.arranged(
            widgets: widgets, width: width, height: Double(pageHeight), rowCounts: Self.fullRowCounts(of: widgets),
            metrics: WidgetCardMetrics.measured)
        let scale = min(1, Self.canvasWidth / width)
        let shownHeight = max(arrangement.height, Double(pageHeight))
        canvas.setSizeRequest(width: Int(width * scale), height: Int(shownHeight * scale))
        summary.label = Self.summary(of: arrangement, width: preset.width, pageHeight: pageHeight)

        let page = Box(orientation: .vertical, spacing: 0)
        page.add(cssClass: "luma-layout-page")
        page.setSizeRequest(width: Int(width * scale), height: Int(Double(pageHeight) * scale))
        canvas.put(widget: page, x: 0, y: 0)

        let containers = arrangement.containerFrames.keys
            .filter { !$0.isEmpty || layout.root.axis == .horizontal }
            .sorted { $0.count < $1.count }
        for path in containers {
            let folded = arrangement.foldedRows.contains(path)
            let box = makeContainerBox(layout[path], at: path, folded: folded)
            place(box, at: arrangement.containerFrames[path]!, scale: scale)
        }
        for widget in widgets {
            guard let path = layout.path(of: widget.id), let frame = arrangement.frames[widget.id] else { continue }
            place(makeWidgetBox(widget, at: path), at: frame, scale: scale)
        }
        if arrangement.scrolls && arrangement.height > Double(pageHeight) {
            let line = Box(orientation: .horizontal, spacing: 0)
            line.add(cssClass: "luma-layout-page-line")
            line.setSizeRequest(width: Int(width * scale), height: 1)
            line.canTarget = false
            canvas.put(widget: line, x: 0, y: Double(pageHeight) * scale)
        }
    }

    private func place(_ box: Button, at frame: InstrumentLayout.Frame, scale: Double) {
        box.setSizeRequest(width: max(1, Int(frame.width * scale)), height: max(1, Int(frame.height * scale)))
        canvas.put(widget: box, x: frame.x * scale, y: frame.y * scale)
    }

    private func makeContainerBox(_ node: InstrumentLayout.Node, at path: Path, folded: Bool) -> Button {
        let kind = node.axis == .horizontal ? "Row" : "Column"
        let tag = Label(str: folded ? "\(kind) \u{00B7} folded" : kind)
        tag.add(cssClass: "luma-layout-tag")
        tag.halign = .start
        tag.valign = .start
        let box = makeSelectableBox(at: path, child: tag)
        box.add(cssClass: "luma-layout-container")
        if folded {
            box.add(cssClass: "luma-layout-folded")
        }
        box.tooltipText = "\(kind) of \(node.entries.count) entries\(folded ? ", folded at this width" : "")"
        return box
    }

    private func makeWidgetBox(_ widget: InstrumentWidget, at path: Path) -> Button {
        let column = Box(orientation: .vertical, spacing: 0)
        column.valign = .center
        let title = Label(str: widget.title ?? widget.id)
        title.ellipsize = .end
        column.append(child: title)
        let kind = Label(str: WidgetKindChoice(from: widget.kind).label)
        kind.add(cssClass: "luma-layout-tag")
        kind.add(cssClass: "dim-label")
        kind.ellipsize = .end
        column.append(child: kind)
        let box = makeSelectableBox(at: path, child: column)
        box.add(cssClass: "luma-layout-box")
        box.tooltipText = "\(widget.title ?? widget.id) (\(WidgetKindChoice(from: widget.kind).label))"
        installDragSource(on: box, id: widget.id)
        installDropTarget(on: box, at: path)
        return box
    }

    private func makeSelectableBox(at path: Path, child: Widget) -> Button {
        let box = Button()
        box.set(child: child)
        gtk_widget_set_overflow(box.widget_ptr, GTK_OVERFLOW_HIDDEN)
        if selection.contains(path) {
            box.add(cssClass: "luma-layout-selected")
        }
        let modifiers = GestureClick()
        modifiers.propagationPhase = .capture
        modifiers.onPressed { [weak self] gesture, _, _, _ in
            MainActor.assumeIsolated {
                self?.extendsSelection = gesture.currentEventState.contains(.controlMask)
            }
        }
        box.add(controller: modifiers)
        box.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.select(path) }
        }
        ContextMenu.attach(to: box, anchor: box) { [weak self, box] x, y in
            guard let self else { return }
            if !self.selection.contains(path) {
                self.select(path)
            }
            self.presentCommands(at: self.boxes[path] ?? box, x: x, y: y)
        }
        boxes[path] = box
        return box
    }

    private func select(_ path: Path) {
        let extending = extendsSelection
        extendsSelection = false
        if extending, let first = selection.first, first.dropLast() == path.dropLast(), !path.isEmpty {
            if let index = selection.firstIndex(of: path) {
                selection.remove(at: index)
            } else {
                selection.append(path)
            }
        } else {
            selection = [path]
        }
        refresh()
        boxes[path]?.grabFocus()
    }

    private func installDragSource(on box: Button, id: String) {
        let source = DragSource()
        source.set(actions: .move)
        source.onPrepare { [weak self] _, _, _ in
            MainActor.assumeIsolated {
                self?.draggedID = id
            }
            return Self.dragContent(id)
        }
        box.add(controller: source)
    }

    private func installDropTarget(on box: Button, at path: Path) {
        let target = DropTarget(type: GType(64), actions: .move)
        target.onDrop { [weak self, box] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self, let id = self.draggedID else { return false }
                self.draggedID = nil
                return self.drop(id, at: Self.side(x: x, y: y, width: Double(box.width), height: Double(box.height)), of: path)
            }
        }
        box.add(controller: target)
    }

    private func drop(_ id: String, at side: InstrumentLayout.Side, of path: Path) -> Bool {
        let draft = read()
        let layout = draft.layout ?? .stack(of: draft.widgets)
        guard let result = try? layout.placing(id, side, of: path) else { return false }
        write(result)
        selection = Self.path(holding: [id], in: result.root).map { [$0] } ?? []
        refresh()
        onChange()
        return true
    }

    private func rebuildProperties(layout: InstrumentLayout, widgets: [InstrumentWidget]) {
        while let child = properties.firstChild {
            properties.remove(child: child)
        }
        guard let path = singleSelection else {
            properties.append(child: Self.note(selection.isEmpty ? "Select a box or a row or column in the preview." : "\(selection.count) entries selected."))
            return
        }
        let node = layout[path]
        let parentAxis = path.isEmpty ? nil : layout[Array(path.dropLast())].axis
        properties.append(child: Self.note(Self.describe(node, widgets: widgets)))
        if !path.isEmpty {
            let shareDefault = parentAxis == .horizontal ? "1" : (node.widgetID == nil && node.axis == .horizontal ? "tallest entry" : "natural height")
            properties.append(child: sizeField("Share", key: .share, value: node.share, default: shareDefault, at: path, widgets: widgets))
        }
        if let id = node.widgetID, let widget = widgets.first(where: { $0.id == id }), Self.takesRowCap(widget.kind) {
            properties.append(
                child: sizeField("Max rows", key: .maxRows, value: node.maxRows, default: "\(InstrumentLayout.defaultRowCap) rows", at: path, widgets: widgets))
        }
        if node.axis == .horizontal {
            let foldWidth = Int(Double(node.entries.count) * InstrumentLayout.foldWidthPerEntry)
            properties.append(
                child: sizeField("Fold below", key: .foldBelow, value: node.foldBelow, default: "folds below \(foldWidth)", at: path, widgets: widgets))
        }
    }

    private func sizeField(
        _ title: String, key: InstrumentLayout.SizeKey, value: Int?, default text: String, at path: Path, widgets: [InstrumentWidget]
    ) -> Box {
        let field = Box(orientation: .vertical, spacing: 2)
        let row = Box(orientation: .horizontal, spacing: 8)
        let label = Label(str: title)
        label.halign = .start
        label.setSizeRequest(width: 72, height: -1)
        row.append(child: label)
        let entry = Entry()
        entry.text = value.map(String.init) ?? ""
        entry.placeholderText = "default"
        entry.widthChars = 6
        entry.inputPurpose = .digits
        entry.setAccessibleLabel("\(title), empty for \(text)")
        row.append(child: entry)
        let fallback = Label(str: text)
        fallback.add(cssClass: "dim-label")
        fallback.add(cssClass: "caption")
        fallback.hexpand = true
        fallback.xalign = 0
        fallback.ellipsize = .end
        row.append(child: fallback)
        field.append(child: row)
        let problem = Label(str: "")
        problem.add(cssClass: "caption")
        problem.add(cssClass: "error")
        problem.xalign = 0
        problem.wrap = true
        problem.visible = false
        field.append(child: problem)
        entry.onChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.setSize(key, text: entry.text ?? "", at: path, problem: problem)
            }
        }
        return field
    }

    private func setSize(_ key: InstrumentLayout.SizeKey, text: String, at path: Path, problem: Label) {
        let draft = read()
        let layout = draft.layout ?? .stack(of: draft.widgets)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || Int(trimmed) != nil else {
            problem.label = "has to be a whole number"
            problem.visible = true
            return
        }
        do {
            let result = try layout.setting(key, to: Int(trimmed), at: path, widgets: draft.widgets)
            problem.visible = false
            write(result)
            rebuildCanvas(layout: result, widgets: draft.widgets)
            onChange()
        } catch {
            problem.label = error.text
            problem.visible = true
        }
    }

    private func rebuildUnplaced(layout: InstrumentLayout, widgets: [InstrumentWidget]) {
        isRebuildingUnplaced = true
        defer { isRebuildingUnplaced = false }
        while let row = unplacedList.firstChild {
            unplacedList.remove(child: row)
        }
        let unplaced = layout.unplaced(in: widgets)
        for id in unplaced {
            let widget = widgets.first { $0.id == id }!
            let row = ListBoxRow()
            let line = Box(orientation: .horizontal, spacing: 4)
            line.marginStart = 8
            line.marginEnd = 4
            line.marginTop = 4
            line.marginBottom = 4
            let label = Label(str: "\(widget.title ?? id) (\(WidgetKindChoice(from: widget.kind).label))")
            label.xalign = 0
            label.hexpand = true
            label.ellipsize = .end
            line.append(child: label)
            line.append(child: placeButton("Below", id: id, command: .placeBelow))
            line.append(child: placeButton("Beside", id: id, command: .placeBeside))
            row.set(child: line)
            row.name = id
            installDragSource(on: row, id: id)
            unplacedList.append(child: row)
            if id == chosenUnplaced {
                unplacedList.select(row: row)
            }
        }
        unplacedList.visible = !unplaced.isEmpty
        unplacedEmpty.visible = unplaced.isEmpty
    }

    private func placeButton(_ title: String, id: String, command: LayoutCommand) -> Button {
        let button = Button(label: title)
        button.add(cssClass: "luma-widget-action")
        button.valign = .center
        button.tooltipText = "\(command.title) (\(command.shortcutLabel))"
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.chosenUnplaced = id
                self.perform(command)
            }
        }
        return button
    }

    private func installDragSource(on row: ListBoxRow, id: String) {
        let source = DragSource()
        source.set(actions: .move)
        source.onPrepare { [weak self] _, _, _ in
            MainActor.assumeIsolated {
                self?.draggedID = id
            }
            return Self.dragContent(id)
        }
        row.add(controller: source)
    }

    private func unplacedID(of row: ListBoxRowRef) -> String? {
        row.name
    }

    private func refreshProblem(layout: InstrumentLayout?, widgets: [InstrumentWidget]) {
        let problem = Self.savingProblem(layout: layout, widgets: widgets)
        problemNote.label = problem ?? ""
        problemNote.visible = problem != nil
    }

    static func savingProblem(layout: InstrumentLayout?, widgets: [InstrumentWidget]) -> String? {
        layout?.problem(placing: widgets, keys: .camelCase, widgetsName: "luma.widgets", layoutName: "luma.layout").map { "layout: \($0.text)" }
    }

    private static func summary(of arrangement: InstrumentLayout.Arrangement, width: Int, pageHeight: Int) -> String {
        let folds = arrangement.foldedRows.count
        let folding = folds == 0 ? "" : folds == 1 ? " \u{00B7} 1 row folded" : " \u{00B7} \(folds) rows folded"
        let fit = arrangement.scrolls ? "scrolls, \(Int(arrangement.height)) tall" : "fills the page"
        return "\(width) \u{00D7} \(pageHeight) \u{00B7} \(fit)\(folding)"
    }

    private static func describe(_ node: InstrumentLayout.Node, widgets: [InstrumentWidget]) -> String {
        switch node.content {
        case .widget(let id):
            let widget = widgets.first { $0.id == id }
            return "\(widget?.title ?? id) (\(widget.map { WidgetKindChoice(from: $0.kind).label } ?? "widget"))"
        case .row(let entries):
            return "Row of \(entries.count) entries"
        case .column(let entries):
            return "Column of \(entries.count) entries"
        }
    }

    private static func fullRowCounts(of widgets: [InstrumentWidget]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: widgets.filter { takesRowCap($0.kind) }.map { widget -> (String, Int) in (widget.id, InstrumentLayout.maxRowsRange.upperBound) })
    }

    private static func takesRowCap(_ kind: InstrumentWidget.Kind) -> Bool {
        switch kind {
        case .list, .table: return true
        default: return false
        }
    }

    private static func exists(_ path: Path, in layout: InstrumentLayout) -> Bool {
        var node = layout.root
        for index in path {
            guard node.entries.indices.contains(index) else { return false }
            node = node.entries[index]
        }
        return true
    }

    private static func widgetIDs(in node: InstrumentLayout.Node) -> [String] {
        if let id = node.widgetID {
            return [id]
        }
        return node.entries.flatMap(widgetIDs)
    }

    private static func path(holding ids: Set<String>, in root: InstrumentLayout.Node) -> Path? {
        var found: Path?
        func visit(_ node: InstrumentLayout.Node, at path: Path) {
            if Set(widgetIDs(in: node)) == ids, path.count >= (found?.count ?? -1) {
                found = path
            }
            for index in node.entries.indices {
                visit(node.entries[index], at: path + [index])
            }
        }
        visit(root, at: [])
        return found
    }

    private static func side(x: Double, y: Double, width: Double, height: Double) -> InstrumentLayout.Side {
        let distances: [(InstrumentLayout.Side, Double)] = [
            (.leading, x / width), (.trailing, (width - x) / width), (.above, y / height), (.below, (height - y) / height),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    private static func dragContent(_ id: String) -> Gdk.ContentProviderRef? {
        let bytes = Array(id.utf8)
        let data = bytes.withUnsafeBufferPointer { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(data) }
        return gdk_content_provider_new_for_bytes("text/plain;charset=utf-8", data).map { Gdk.ContentProviderRef(raw: UnsafeMutableRawPointer($0)) }
    }

    private static func heading(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "heading")
        label.halign = .start
        return label
    }

    private static func note(_ text: String) -> Label {
        let label = Label(str: text)
        label.halign = .start
        label.xalign = 0
        label.wrap = true
        return label
    }

    private struct Outcome {
        let layout: InstrumentLayout?
        let selecting: Set<String>?
    }

    private enum Preset: CaseIterable {
        case wide
        case laptop
        case phone

        var title: String {
            switch self {
            case .wide: return "Wide"
            case .laptop: return "Laptop"
            case .phone: return "Phone"
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
}

enum LayoutCommand: CaseIterable {
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

    static let sections: [[LayoutCommand]] = [
        [.wrapInRow, .wrapInColumn, .unwrap],
        [.moveUp, .moveDown, .moveLeft, .moveRight],
        [.placeBelow, .placeBeside, .removeFromLayout],
        [.resetToStack],
    ]

    static func matching(keyval: UInt, state: Gdk.ModifierType) -> LayoutCommand? {
        let key = Int32(gdk_keyval_to_lower(guint(keyval)))
        let modifiers = state.intersection([.controlMask, .shiftMask, .altMask])
        return allCases.first { $0.keys.contains(key) && $0.modifiers == modifiers }
    }

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

    var shortcutLabel: String {
        switch self {
        case .wrapInRow: return "Ctrl+Shift+R"
        case .wrapInColumn: return "Ctrl+Shift+C"
        case .unwrap: return "Ctrl+Shift+U"
        case .moveUp: return "Alt+Up"
        case .moveDown: return "Alt+Down"
        case .moveLeft: return "Alt+Left"
        case .moveRight: return "Alt+Right"
        case .placeBelow: return "Ctrl+Shift+P"
        case .placeBeside: return "Ctrl+Shift+B"
        case .removeFromLayout: return "Delete"
        case .resetToStack: return "Ctrl+Shift+0"
        }
    }

    var direction: InstrumentLayout.Direction? {
        switch self {
        case .moveUp: return .up
        case .moveDown: return .down
        case .moveLeft: return .left
        case .moveRight: return .right
        default: return nil
        }
    }

    var side: InstrumentLayout.Side? {
        switch self {
        case .placeBelow: return .below
        case .placeBeside: return .trailing
        default: return nil
        }
    }

    var choosesFromUnplaced: Bool {
        side != nil
    }

    var needsPreviewFocus: Bool {
        self == .removeFromLayout
    }

    private var keys: [Int32] {
        switch self {
        case .wrapInRow: return [Gdk.keyr]
        case .wrapInColumn: return [Gdk.keyc]
        case .unwrap: return [Gdk.keyu]
        case .moveUp: return [Gdk.keyUp]
        case .moveDown: return [Gdk.keyDown]
        case .moveLeft: return [Gdk.keyLeft]
        case .moveRight: return [Gdk.keyRight]
        case .placeBelow: return [Gdk.keyp]
        case .placeBeside: return [Gdk.keyb]
        case .removeFromLayout: return [Gdk.keyDelete]
        case .resetToStack: return [Gdk.key0, Gdk.keyparenright]
        }
    }

    private var modifiers: Gdk.ModifierType {
        switch self {
        case .moveUp, .moveDown, .moveLeft, .moveRight: return .altMask
        case .removeFromLayout: return []
        default: return [.controlMask, .shiftMask]
        }
    }
}
