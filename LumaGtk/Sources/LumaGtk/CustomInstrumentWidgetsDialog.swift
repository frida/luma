import Adw
import CGtk
import Foundation
import GLibObject
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentWidgetsDialog {
    private let engine: Engine
    private var def: CustomInstrumentDef
    private var draftWidgets: [InstrumentWidget]
    private let dialog: Adw.Dialog
    private let listBox: Box
    private let addRowBox: Box
    private let toggleAddButton: Button
    private let idEntry: Entry
    private let nameEntry: Entry
    private var draftKind: WidgetKindChoice = .graph
    private var nameAutoFilled: Bool = true
    private var suppressIDChange: Bool = false
    private var suppressNameChange: Bool = false
    private var expandedID: String? = nil
    private var widgetBodies: [String: (body: Box, chevron: Button)] = [:]

    init(engine: Engine, def: CustomInstrumentDef) {
        self.engine = engine
        self.def = def
        self.draftWidgets = def.widgets

        dialog = Adw.Dialog()
        dialog.set(title: "Widgets")
        dialog.set(followsContentSize: true)

        listBox = Box(orientation: .vertical, spacing: 4)
        addRowBox = Box(orientation: .horizontal, spacing: 8)
        addRowBox.visible = false
        toggleAddButton = Button(label: "+ Add Widget")
        toggleAddButton.halign = .start

        idEntry = Entry()
        idEntry.placeholderText = "id"
        idEntry.setSizeRequest(width: 140, height: -1)

        nameEntry = Entry()
        nameEntry.placeholderText = "Name"
        nameEntry.hexpand = true

        layout()
        rebuildList()
    }

    func present(parent: Gtk.Window) {
        Self.retain(self, dialog: dialog)
        MonacoEditor.suspendOverlays()
        dialog.onClosed { _ in
            MainActor.assumeIsolated {
                MonacoEditor.resumeOverlays()
            }
        }
        dialog.present(parent: parent)
    }

    private func layout() {
        let scrollContent = Box(orientation: .vertical, spacing: 12)
        scrollContent.marginStart = 16
        scrollContent.marginEnd = 16
        scrollContent.marginTop = 16
        scrollContent.marginBottom = 16
        scrollContent.setSizeRequest(width: 560, height: -1)

        let intro = Label(str: "Live UI elements rendered alongside the feature controls. Graphs receive points your agent code pushes via `ctx.widget(id).push(...)`. Lists hold items the agent maintains; per-item action buttons post events back to your `onAction` handler.")
        intro.add(cssClass: "dim-label")
        intro.wrap = true
        intro.xalign = 0
        intro.maxWidthChars = 60
        scrollContent.append(child: intro)

        scrollContent.append(child: listBox)
        populateAddRow()
        scrollContent.append(child: addRowBox)
        toggleAddButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleAdding() }
        }
        scrollContent.append(child: toggleAddButton)

        let scroll = ScrolledWindow()
        scroll.set(child: scrollContent)
        scroll.propagateNaturalHeight = true
        scroll.propagateNaturalWidth = true
        scroll.maxContentHeight = 600
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)

        let header = Adw.HeaderBar()
        let saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
        header.packEnd(child: saveButton)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: scroll)

        dialog.set(child: toolbarView)
    }

    private func populateAddRow() {
        addRowBox.append(child: idEntry)
        addRowBox.append(child: nameEntry)
        let kindDropdown = makeWidgetKindDropdown(initial: draftKind) { [weak self] kind in
            self?.draftKind = kind
        }
        addRowBox.append(child: kindDropdown)
        let addButton = Button(label: "Add")
        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.appendWidget() }
        }
        idEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.appendWidget() }
        }
        nameEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.appendWidget() }
        }
        idEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleIDChanged() }
        }
        nameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleNameChanged() }
        }
        addRowBox.append(child: addButton)
    }

    private func handleIDChanged() {
        guard !suppressIDChange else { return }
        let raw = idEntry.text ?? ""
        let lowered = CamelCase.sanitized(raw)
        if lowered != raw {
            suppressIDChange = true
            idEntry.text = lowered
            suppressIDChange = false
            return
        }
        if nameAutoFilled {
            suppressNameChange = true
            nameEntry.text = CamelCase.humanized(lowered)
            suppressNameChange = false
        }
    }

    private func handleNameChanged() {
        guard !suppressNameChange else { return }
        if (nameEntry.text ?? "") != CamelCase.humanized(idEntry.text ?? "") {
            nameAutoFilled = false
        }
    }

    private func toggleAdding() {
        let nowVisible = !addRowBox.visible
        if !nowVisible {
            appendWidget()
        }
        addRowBox.visible = nowVisible
        toggleAddButton.label = nowVisible ? "Done Adding" : "+ Add Widget"
        if nowVisible {
            applyExpansion(to: nil)
            _ = idEntry.grabFocus()
        } else {
            resetDraft()
        }
    }

    private func appendWidget() {
        let id = (idEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        let name = (nameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !draftWidgets.contains(where: { $0.id == id }) else { return }
        draftWidgets.append(InstrumentWidget(id: id, name: name, kind: draftKind.defaultKind()))
        expandedID = id
        resetDraft()
        rebuildList()
        addRowBox.visible = false
        toggleAddButton.label = "+ Add Widget"
    }

    private func resetDraft() {
        suppressIDChange = true
        idEntry.text = ""
        suppressIDChange = false
        suppressNameChange = true
        nameEntry.text = ""
        suppressNameChange = false
        nameAutoFilled = true
    }

    private func commit() {
        if addRowBox.visible {
            appendWidget()
        }
        var updated = def
        updated.widgets = draftWidgets
        let engine = self.engine
        let dialog = self.dialog
        Task { @MainActor in
            await engine.updateCustomInstrument(updated)
            _ = dialog.close()
        }
    }

    private func rebuildList() {
        var child = listBox.firstChild
        while let current = child {
            child = current.nextSibling
            listBox.remove(child: current)
        }
        widgetBodies.removeAll()
        if draftWidgets.isEmpty {
            let empty = Label(str: "No widgets defined.")
            empty.add(cssClass: "dim-label")
            empty.halign = .start
            listBox.append(child: empty)
            return
        }
        for (index, widget) in draftWidgets.enumerated() {
            listBox.append(child: widgetRow(widget: widget, index: index))
        }
    }

    private func widgetRow(widget: InstrumentWidget, index: Int) -> Box {
        let card = Box(orientation: .vertical, spacing: 0)
        card.add(cssClass: "card")

        let column = Box(orientation: .vertical, spacing: 6)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12
        card.append(child: column)

        let isExpanded = expandedID == widget.id
        let widgetID = widget.id

        let chevronButton = Button()
        chevronButton.add(cssClass: "flat")
        chevronButton.set(iconName: isExpanded ? "pan-down-symbolic" : "pan-end-symbolic")
        chevronButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let newID: String? = (self.expandedID == widgetID) ? nil : widgetID
                self.applyExpansion(to: newID)
            }
        }

        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: chevronButton)

        let idLabel = Label(str: widget.id)
        idLabel.halign = .start
        header.append(child: idLabel)

        let dash = Label(str: "—")
        dash.add(cssClass: "dim-label")
        header.append(child: dash)

        let nameLabel = Label(str: widget.name)
        nameLabel.halign = .start
        nameLabel.hexpand = true
        header.append(child: nameLabel)

        let kindDropdown = makeWidgetKindDropdown(initial: WidgetKindChoice(from: widget.kind)) { [weak self] kind in
            guard let self, index < self.draftWidgets.count else { return }
            self.draftWidgets[index].kind = kind.defaultKind()
            self.expandedID = self.draftWidgets[index].id
            self.rebuildList()
        }
        header.append(child: kindDropdown)

        let removeButton = Button(label: "Remove")
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index < self.draftWidgets.count else { return }
                let removedID = self.draftWidgets[index].id
                self.draftWidgets.remove(at: index)
                if self.expandedID == removedID { self.expandedID = nil }
                self.rebuildList()
            }
        }
        header.append(child: removeButton)
        column.append(child: header)

        let body = Box(orientation: .vertical, spacing: 6)
        body.visible = isExpanded
        body.append(child: persistenceRow(widget: widget, index: index))
        switch widget.kind {
        case .graph(let cfg):
            body.append(child: graphSeriesEditor(initial: cfg.series, index: index))
        case .list(let cfg):
            body.append(child: listActionsEditor(initial: cfg.actions, index: index))
        }
        column.append(child: body)

        widgetBodies[widgetID] = (body, chevronButton)
        return card
    }

    private func persistenceRow(widget: InstrumentWidget, index: Int) -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        let label = Label(str: "Persistence")
        label.halign = .start
        label.setSizeRequest(width: 96, height: -1)
        row.append(child: label)
        let dropdown = makePersistenceDropdown(initial: widget.persistence) { [weak self] value in
            guard let self, index < self.draftWidgets.count else { return }
            self.draftWidgets[index].persistence = value
        }
        row.append(child: dropdown)
        return row
    }

    private func graphSeriesEditor(initial: [InstrumentWidget.Series], index: Int) -> Box {
        let outer = Box(orientation: .vertical, spacing: 4)
        let header = Label(str: "Series")
        header.halign = .start
        header.add(cssClass: "caption")
        outer.append(child: header)

        let listBox = Box(orientation: .vertical, spacing: 4)
        outer.append(child: listBox)
        rebuildSeriesRows(into: listBox, items: initial, widgetIndex: index)

        outer.append(child: seriesAddRow(into: listBox, widgetIndex: index))
        return outer
    }

    private func rebuildSeriesRows(into list: Box, items: [InstrumentWidget.Series], widgetIndex: Int) {
        var child = list.firstChild
        while let current = child {
            child = current.nextSibling
            list.remove(child: current)
        }
        for (i, item) in items.enumerated() {
            list.append(child: seriesRow(item: item, widgetIndex: widgetIndex, itemIndex: i, list: list))
        }
    }

    private func seriesRow(item: InstrumentWidget.Series, widgetIndex: Int, itemIndex: Int, list: Box) -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let idEntry = Entry()
        idEntry.text = item.id
        idEntry.placeholderText = "id"
        idEntry.setSizeRequest(width: 140, height: -1)
        idEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, widgetIndex < self.draftWidgets.count else { return }
                self.updateSeries(at: widgetIndex, itemIndex: itemIndex) { $0.id = idEntry.text ?? "" }
            }
        }
        row.append(child: idEntry)
        let nameEntry = Entry()
        nameEntry.text = item.name
        nameEntry.placeholderText = "Name"
        nameEntry.hexpand = true
        nameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, widgetIndex < self.draftWidgets.count else { return }
                self.updateSeries(at: widgetIndex, itemIndex: itemIndex) { $0.name = nameEntry.text ?? "" }
            }
        }
        row.append(child: nameEntry)
        let removeButton = Button(label: "−")
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeSeries(at: widgetIndex, itemIndex: itemIndex, list: list)
            }
        }
        row.append(child: removeButton)
        return row
    }

    private func seriesAddRow(into list: Box, widgetIndex: Int) -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let idEntry = Entry()
        idEntry.placeholderText = "id"
        idEntry.setSizeRequest(width: 140, height: -1)
        let nameEntry = Entry()
        nameEntry.placeholderText = "Name"
        nameEntry.hexpand = true
        let appendAction: () -> Void = { [weak self] in
            guard let self else { return }
            let id = (idEntry.text ?? "").trimmingCharacters(in: .whitespaces)
            let name = (nameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !name.isEmpty, widgetIndex < self.draftWidgets.count,
                case .graph(var cfg) = self.draftWidgets[widgetIndex].kind,
                !cfg.series.contains(where: { $0.id == id })
            else { return }
            cfg.series.append(InstrumentWidget.Series(id: id, name: name))
            self.draftWidgets[widgetIndex].kind = .graph(cfg)
            idEntry.text = ""
            nameEntry.text = ""
            self.rebuildSeriesRows(into: list, items: cfg.series, widgetIndex: widgetIndex)
            _ = idEntry.grabFocus()
        }
        idEntry.onActivate { _ in MainActor.assumeIsolated { appendAction() } }
        nameEntry.onActivate { _ in MainActor.assumeIsolated { appendAction() } }
        row.append(child: idEntry)
        row.append(child: nameEntry)
        let addButton = Button(label: "+")
        addButton.onClicked { _ in MainActor.assumeIsolated { appendAction() } }
        row.append(child: addButton)
        return row
    }

    private func updateSeries(at widgetIndex: Int, itemIndex: Int, mutate: (inout InstrumentWidget.Series) -> Void) {
        guard widgetIndex < draftWidgets.count,
            case .graph(var cfg) = draftWidgets[widgetIndex].kind,
            itemIndex < cfg.series.count
        else { return }
        var item = cfg.series[itemIndex]
        mutate(&item)
        cfg.series[itemIndex] = item
        draftWidgets[widgetIndex].kind = .graph(cfg)
    }

    private func removeSeries(at widgetIndex: Int, itemIndex: Int, list: Box) {
        guard widgetIndex < draftWidgets.count,
            case .graph(var cfg) = draftWidgets[widgetIndex].kind,
            itemIndex < cfg.series.count
        else { return }
        cfg.series.remove(at: itemIndex)
        draftWidgets[widgetIndex].kind = .graph(cfg)
        rebuildSeriesRows(into: list, items: cfg.series, widgetIndex: widgetIndex)
    }

    private func listActionsEditor(initial: [InstrumentWidget.Action], index: Int) -> Box {
        let outer = Box(orientation: .vertical, spacing: 4)
        let header = Label(str: "Actions")
        header.halign = .start
        header.add(cssClass: "caption")
        outer.append(child: header)

        let listBox = Box(orientation: .vertical, spacing: 4)
        outer.append(child: listBox)
        rebuildActionRows(into: listBox, items: initial, widgetIndex: index)

        outer.append(child: actionsAddRow(into: listBox, widgetIndex: index))
        return outer
    }

    private func rebuildActionRows(into list: Box, items: [InstrumentWidget.Action], widgetIndex: Int) {
        var child = list.firstChild
        while let current = child {
            child = current.nextSibling
            list.remove(child: current)
        }
        for (i, item) in items.enumerated() {
            list.append(child: actionRow(item: item, widgetIndex: widgetIndex, itemIndex: i, list: list))
        }
    }

    private func actionRow(item: InstrumentWidget.Action, widgetIndex: Int, itemIndex: Int, list: Box) -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let idEntry = Entry()
        idEntry.text = item.id
        idEntry.placeholderText = "id"
        idEntry.setSizeRequest(width: 140, height: -1)
        idEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, widgetIndex < self.draftWidgets.count else { return }
                self.updateAction(at: widgetIndex, itemIndex: itemIndex) { $0.id = idEntry.text ?? "" }
            }
        }
        row.append(child: idEntry)
        let nameEntry = Entry()
        nameEntry.text = item.name
        nameEntry.placeholderText = "Name"
        nameEntry.hexpand = true
        nameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, widgetIndex < self.draftWidgets.count else { return }
                self.updateAction(at: widgetIndex, itemIndex: itemIndex) { $0.name = nameEntry.text ?? "" }
            }
        }
        row.append(child: nameEntry)
        let removeButton = Button(label: "−")
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeAction(at: widgetIndex, itemIndex: itemIndex, list: list)
            }
        }
        row.append(child: removeButton)
        return row
    }

    private func actionsAddRow(into list: Box, widgetIndex: Int) -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let idEntry = Entry()
        idEntry.placeholderText = "id"
        idEntry.setSizeRequest(width: 140, height: -1)
        let nameEntry = Entry()
        nameEntry.placeholderText = "Name"
        nameEntry.hexpand = true
        let appendAction: () -> Void = { [weak self] in
            guard let self else { return }
            let id = (idEntry.text ?? "").trimmingCharacters(in: .whitespaces)
            let name = (nameEntry.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !name.isEmpty, widgetIndex < self.draftWidgets.count,
                case .list(var cfg) = self.draftWidgets[widgetIndex].kind,
                !cfg.actions.contains(where: { $0.id == id })
            else { return }
            cfg.actions.append(InstrumentWidget.Action(id: id, name: name))
            self.draftWidgets[widgetIndex].kind = .list(cfg)
            idEntry.text = ""
            nameEntry.text = ""
            self.rebuildActionRows(into: list, items: cfg.actions, widgetIndex: widgetIndex)
            _ = idEntry.grabFocus()
        }
        idEntry.onActivate { _ in MainActor.assumeIsolated { appendAction() } }
        nameEntry.onActivate { _ in MainActor.assumeIsolated { appendAction() } }
        row.append(child: idEntry)
        row.append(child: nameEntry)
        let addButton = Button(label: "+")
        addButton.onClicked { _ in MainActor.assumeIsolated { appendAction() } }
        row.append(child: addButton)
        return row
    }

    private func updateAction(at widgetIndex: Int, itemIndex: Int, mutate: (inout InstrumentWidget.Action) -> Void) {
        guard widgetIndex < draftWidgets.count,
            case .list(var cfg) = draftWidgets[widgetIndex].kind,
            itemIndex < cfg.actions.count
        else { return }
        var item = cfg.actions[itemIndex]
        mutate(&item)
        cfg.actions[itemIndex] = item
        draftWidgets[widgetIndex].kind = .list(cfg)
    }

    private func removeAction(at widgetIndex: Int, itemIndex: Int, list: Box) {
        guard widgetIndex < draftWidgets.count,
            case .list(var cfg) = draftWidgets[widgetIndex].kind,
            itemIndex < cfg.actions.count
        else { return }
        cfg.actions.remove(at: itemIndex)
        draftWidgets[widgetIndex].kind = .list(cfg)
        rebuildActionRows(into: list, items: cfg.actions, widgetIndex: widgetIndex)
    }

    private func applyExpansion(to newID: String?) {
        expandedID = newID
        for (rowID, entry) in widgetBodies {
            let shouldExpand = newID == rowID
            entry.body.visible = shouldExpand
            entry.chevron.set(iconName: shouldExpand ? "pan-down-symbolic" : "pan-end-symbolic")
        }
    }

    private static func retain(_ owner: CustomInstrumentWidgetsDialog, dialog: Adw.Dialog) {
        let key = ObjectIdentifier(dialog)
        retained[key] = owner
        dialog.onClosed { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
        }
    }

    private static var retained: [ObjectIdentifier: CustomInstrumentWidgetsDialog] = [:]
}

enum WidgetKindChoice: CaseIterable {
    case graph, list

    var label: String {
        switch self {
        case .graph: return "Graph"
        case .list: return "List"
        }
    }

    var index: Int {
        Self.allCases.firstIndex(of: self)!
    }

    init(from kind: InstrumentWidget.Kind) {
        switch kind {
        case .graph: self = .graph
        case .list: self = .list
        }
    }

    func defaultKind() -> InstrumentWidget.Kind {
        switch self {
        case .graph: return .graph(InstrumentWidget.GraphConfig())
        case .list: return .list(InstrumentWidget.ListConfig())
        }
    }
}

@MainActor
func makeWidgetKindDropdown(initial: WidgetKindChoice, onChanged: @escaping (WidgetKindChoice) -> Void) -> DropDown {
    let labels = WidgetKindChoice.allCases.map(\.label)
    let cStrings = labels.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }
    var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
    ptrs.append(nil)
    let widgetPtr = ptrs.withUnsafeBufferPointer { buf in
        gtk_drop_down_new_from_strings(buf.baseAddress)
    }!
    g_object_ref_sink(UnsafeMutableRawPointer(widgetPtr))
    let dropdown = DropDown(raw: UnsafeMutableRawPointer(widgetPtr))
    dropdown.selected = initial.index
    dropdown.onNotifySelected { dd, _ in
        MainActor.assumeIsolated {
            let kinds = WidgetKindChoice.allCases
            let index = Int(dd.selected)
            guard index >= 0, index < kinds.count else { return }
            onChanged(kinds[index])
        }
    }
    return dropdown
}

@MainActor
func makePersistenceDropdown(
    initial: InstrumentWidget.Persistence,
    onChanged: @escaping (InstrumentWidget.Persistence) -> Void
) -> DropDown {
    let cases = InstrumentWidget.Persistence.allCases
    let labels = cases.map(\.label)
    let cStrings = labels.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }
    var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
    ptrs.append(nil)
    let widgetPtr = ptrs.withUnsafeBufferPointer { buf in
        gtk_drop_down_new_from_strings(buf.baseAddress)
    }!
    g_object_ref_sink(UnsafeMutableRawPointer(widgetPtr))
    let dropdown = DropDown(raw: UnsafeMutableRawPointer(widgetPtr))
    dropdown.selected = cases.firstIndex(of: initial) ?? 0
    dropdown.onNotifySelected { dd, _ in
        MainActor.assumeIsolated {
            let index = Int(dd.selected)
            guard index >= 0, index < cases.count else { return }
            onChanged(cases[index])
        }
    }
    return dropdown
}
