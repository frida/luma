import Adw
import CGtk
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class ModuleSymbolsPane {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let module: LumaCore.ProcessModule

    private let toggleBar: Box
    private let exportsButton: ToggleButton
    private let importsButton: ToggleButton
    private let symbolsButton: ToggleButton
    private let listContainer: Box
    private let symbolScroll: ScrolledWindow
    private let symbolModel: StringList
    private let symbolSelection: NoSelection
    private let symbolFactory: SignalListItemFactory
    private let symbolList: ListView
    private let statusLabel: Label
    private let filterEntry: SearchEntry
    private let countLabel: Label
    private let prevButton: Button
    private let nextButton: Button

    private var page: LumaCore.ModuleSymbolPage?
    private var counts: LumaCore.ModuleSymbolPage.Counts?
    private var queryTask: Task<Void, Never>?
    private var tab: Tab = .exports
    private var filterText: String = ""
    private var pageIndex = 0
    private var rows: [RowData] = []
    private var rowViews: [UnsafeMutableRawPointer: RowView] = [:]

    private struct RowData {
        let title: String
        let typeLabel: String
        let address: UInt64?
        let context: AddressContext
    }

    @MainActor
    private final class RowView {
        let box: Box
        let nameLabel: Label
        let typeChip: Label
        let addrLabel: Label
        var data: RowData?

        init() {
            box = Box(orientation: .horizontal, spacing: 12)
            box.marginStart = 12
            box.marginEnd = 12
            box.marginTop = 6
            box.marginBottom = 6

            nameLabel = Label(str: "")
            nameLabel.halign = .start
            nameLabel.hexpand = true
            nameLabel.xalign = 0
            nameLabel.ellipsize = .end

            typeChip = Label(str: "")
            typeChip.halign = .end
            typeChip.add(cssClass: "dim-label")
            typeChip.add(cssClass: "caption")

            addrLabel = Label(str: "")
            addrLabel.halign = .end
            addrLabel.add(cssClass: "monospace")

            box.append(child: nameLabel)
            box.append(child: typeChip)
            box.append(child: addrLabel)
        }
    }

    enum Tab {
        case exports
        case imports
        case symbols

        var category: LumaCore.ModuleSymbolCategory {
            switch self {
            case .exports: return .exports
            case .imports: return .imports
            case .symbols: return .symbols
            }
        }
    }

    init(engine: Engine, sessionID: UUID, module: LumaCore.ProcessModule) {
        self.engine = engine
        self.sessionID = sessionID
        self.module = module

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        exportsButton = ToggleButton()
        exportsButton.label = "Exports"
        exportsButton.active = true

        importsButton = ToggleButton()
        importsButton.label = "Imports"
        importsButton.set(group: exportsButton)

        symbolsButton = ToggleButton()
        symbolsButton.label = "Symbols"
        symbolsButton.set(group: exportsButton)

        toggleBar = Box(orientation: .horizontal, spacing: 0)
        toggleBar.add(cssClass: "linked")
        toggleBar.append(child: exportsButton)
        toggleBar.append(child: importsButton)
        toggleBar.append(child: symbolsButton)

        statusLabel = Label(str: "Loading\u{2026}")
        statusLabel.halign = .start
        statusLabel.add(cssClass: "dim-label")

        listContainer = Box(orientation: .vertical, spacing: 0)
        listContainer.hexpand = true
        listContainer.vexpand = true

        symbolModel = StringList(strings: nil)
        symbolSelection = NoSelection(model: symbolModel)
        symbolFactory = SignalListItemFactory()
        symbolList = ListView(model: symbolSelection, factory: symbolFactory)

        // gtk_no_selection_new / gtk_list_view_new take the model (transfer
        // full) without the binding adding a ref, so balance the ref we keep.
        _ = g_object_ref(symbolModel.ptr)
        _ = g_object_ref(symbolSelection.ptr)
        symbolList.add(cssClass: "boxed-list")

        symbolScroll = ScrolledWindow()
        symbolScroll.hexpand = true
        symbolScroll.vexpand = true
        symbolScroll.setSizeRequest(width: -1, height: 280)
        symbolScroll.set(child: symbolList)
        listContainer.append(child: symbolScroll)

        let contentBox = Box(orientation: .vertical, spacing: 8)
        contentBox.hexpand = true
        contentBox.vexpand = true
        contentBox.marginStart = 12
        contentBox.marginTop = 8
        contentBox.append(child: toggleBar)
        contentBox.append(child: statusLabel)
        contentBox.append(child: listContainer)

        filterEntry = SearchEntry()
        filterEntry.placeholderText = "Filter"
        filterEntry.hexpand = true

        countLabel = Label(str: "")
        countLabel.add(cssClass: "dim-label")
        countLabel.add(cssClass: "caption")

        prevButton = Button()
        prevButton.iconName = "go-previous-symbolic"
        prevButton.add(cssClass: "flat")
        prevButton.sensitive = false

        nextButton = Button()
        nextButton.iconName = "go-next-symbolic"
        nextButton.add(cssClass: "flat")
        nextButton.sensitive = false

        let filterBar = Box(orientation: .horizontal, spacing: 6)
        filterBar.marginStart = 10
        filterBar.marginEnd = 10
        filterBar.marginTop = 5
        filterBar.marginBottom = 5
        filterBar.append(child: filterEntry)
        filterBar.append(child: countLabel)
        filterBar.append(child: prevButton)
        filterBar.append(child: nextButton)

        widget.append(child: contentBox)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: filterBar)

        exportsButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.exportsButton.active else { return }
                self.switchTab(.exports)
            }
        }
        importsButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.importsButton.active else { return }
                self.switchTab(.imports)
            }
        }
        symbolsButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.symbolsButton.active else { return }
                self.switchTab(.symbols)
            }
        }

        filterEntry.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.filterText = entry.text
                self.pageIndex = 0
                self.scheduleQuery()
            }
        }

        prevButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pageIndex > 0 else { return }
                self.pageIndex -= 1
                self.runQuery()
            }
        }
        nextButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let page = self.page, self.pageIndex < self.lastPageIndex(page) else { return }
                self.pageIndex += 1
                self.runQuery()
            }
        }

        configureFactory()
        installFilterShortcut()
        runQuery()
    }

    private func configureFactory() {
        symbolFactory.onSetup { [weak self] _, object in
            MainActor.assumeIsolated {
                guard let self else { return }
                let item = ListItemRef(raw: object.ptr)
                let rowView = self.makeRowView()
                self.rowViews[rowView.box.ptr] = rowView
                item.set(child: rowView.box)
            }
        }
        symbolFactory.onBind { [weak self] _, object in
            MainActor.assumeIsolated {
                guard let self else { return }
                let item = ListItemRef(raw: object.ptr)
                guard let child = item.child, let rowView = self.rowViews[child.ptr] else { return }
                let position = item.position
                rowView.data = (position >= 0 && position < self.rows.count) ? self.rows[position] : nil
                self.apply(rowView)
            }
        }
        symbolFactory.onTeardown { [weak self] _, object in
            MainActor.assumeIsolated {
                guard let self else { return }
                let item = ListItemRef(raw: object.ptr)
                if let child = item.child {
                    self.rowViews.removeValue(forKey: child.ptr)
                }
            }
        }
    }

    private func switchTab(_ tab: Tab) {
        self.tab = tab
        pageIndex = 0
        runQuery()
    }

    private func installFilterShortcut() {
        let key = EventControllerKey()
        key.propagationPhase = .capture
        key.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self, state.contains(.controlMask), keyval == 0x66 || keyval == 0x46 else { return false }
                _ = self.filterEntry.grabFocus()
                return true
            }
        }
        widget.install(controller: key)
    }

    deinit {
        queryTask?.cancel()
    }

    private func scheduleQuery() {
        queryTask?.cancel()
        queryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled else { return }
            self.runQuery()
        }
    }

    private func runQuery() {
        queryTask?.cancel()
        guard let engine, let node = engine.node(forSessionID: sessionID) else {
            statusLabel.setText(str: "Process detached")
            statusLabel.visible = true
            return
        }

        let moduleName = module.name
        let category = tab.category
        let query = filterText
        let offset = pageIndex * LumaCore.ModuleSymbolPage.pageSize
        queryTask = Task { @MainActor [weak self] in
            do {
                let result = try await node.queryModuleSymbols(name: moduleName, category: category, query: query, offset: offset)
                guard let self, !Task.isCancelled else { return }
                self.page = result
                self.counts = result.counts
                self.updateTabLabels()
                self.statusLabel.visible = false
                self.renderCurrent()
            } catch {
                guard let self else { return }
                self.statusLabel.setText(str: error.localizedDescription)
                self.statusLabel.visible = true
            }
        }
    }

    private func updateTabLabels() {
        guard let counts else { return }
        exportsButton.label = "Exports (\(counts.exports))"
        importsButton.label = "Imports (\(counts.imports))"
        symbolsButton.label = "Symbols (\(counts.symbols))"
    }

    private func renderCurrent() {
        guard let page else { return }
        rows = rowData(for: page.rows)

        let previousCount = symbolModel.nItems
        if previousCount > 0 {
            symbolModel.splice(position: 0, nRemovals: previousCount)
        }
        for _ in rows.indices {
            symbolModel.append(string: "")
        }

        symbolScroll.vadjustment?.value = 0
        setFilterCount(page)
    }

    private func rowData(for rows: LumaCore.ModuleSymbolPage.Rows) -> [RowData] {
        switch rows {
        case .exports(let exports):
            return exports.map {
                RowData(title: $0.name, typeLabel: $0.kind.rawValue, address: $0.address, context: exportContext($0))
            }
        case .imports(let imports):
            return imports.map { imp in
                let typeLabel = [imp.kind?.rawValue, imp.module].compactMap { $0 }.joined(separator: " · ")
                let target = importTarget(imp)
                return RowData(title: imp.name, typeLabel: typeLabel.isEmpty ? "import" : typeLabel, address: target.address, context: target.context)
            }
        case .symbols(let symbols):
            return symbols.map { sym in
                let typeLabel = [sym.type, sym.sectionID].compactMap { $0 }.joined(separator: " · ")
                return RowData(title: sym.name, typeLabel: typeLabel, address: sym.address, context: symbolContext(sym))
            }
        }
    }

    private func lastPageIndex(_ page: LumaCore.ModuleSymbolPage) -> Int {
        guard page.matched > 0 else { return 0 }
        return (page.matched - 1) / LumaCore.ModuleSymbolPage.pageSize
    }

    private func setFilterCount(_ page: LumaCore.ModuleSymbolPage) {
        if page.matched == 0 {
            countLabel.setText(str: "No matches")
        } else {
            countLabel.setText(str: "\(page.offset + 1)\u{2013}\(page.offset + page.count) of \(page.matched)")
        }
        prevButton.sensitive = page.hasPrevious
        nextButton.sensitive = page.hasNext
    }


    private func apply(_ rowView: RowView) {
        guard let data = rowView.data else { return }
        rowView.nameLabel.setText(str: data.title)
        rowView.typeChip.setText(str: data.typeLabel)
        rowView.addrLabel.setText(str: data.address.map { String(format: "0x%llx", $0) } ?? "—")
    }

    private func makeRowView() -> RowView {
        let rowView = RowView()

        let click = GestureClick()
        click.set(button: 1)
        click.onPressed { [weak self, weak rowView] _, nPress, _, _ in
            MainActor.assumeIsolated {
                guard Int(nPress) == 2, let self, let engine = self.engine,
                    let data = rowView?.data, let address = data.address
                else { return }
                AddressActionMenu.openInsight(
                    engine: engine,
                    sessionID: self.sessionID,
                    address: address,
                    kind: data.context.kind == .data ? .memory : .disassembly,
                    failureLabel: "Can\u{2019}t open"
                )
            }
        }
        rowView.box.install(controller: click)

        let menu = GestureClick()
        menu.set(button: 3)
        menu.propagationPhase = .capture
        menu.onPressed { [weak self, weak rowView] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine,
                    let data = rowView?.data, let address = data.address, let box = rowView?.box
                else { return }
                _ = gesture.set(state: .claimed)
                AddressActionMenu.present(
                    at: box, x: x, y: y, engine: engine, sessionID: self.sessionID,
                    address: address, value: String(format: "0x%llx", address),
                    copyLabel: "Copy Address", context: data.context)
            }
        }
        rowView.box.install(controller: menu)

        return rowView
    }

}

extension ModuleSymbolsPane {
    fileprivate func exportContext(_ export: LumaCore.ModuleSymbolBundle.Export) -> AddressContext {
        AddressContext(
            kind: export.kind == .function ? .function : .data,
            typeHint: export.kind.rawValue,
            anchorHint: .moduleExport(name: module.name, export: export.name)
        )
    }

    // Prefer the resolved target (the imported symbol itself, code or data); when
    // the dynamic linker hasn't bound it yet, act on the IAT/GOT slot instead,
    // which is a pointer-sized data location.
    fileprivate func importTarget(_ imp: LumaCore.ModuleSymbolBundle.Import) -> (address: UInt64?, context: AddressContext) {
        if imp.address != nil {
            return (imp.address, importContext(imp))
        }
        return (imp.slot, AddressContext(kind: .data, typeHint: "import slot"))
    }

    fileprivate func importContext(_ imp: LumaCore.ModuleSymbolBundle.Import) -> AddressContext {
        let kind: AddressContext.Kind
        switch imp.kind {
        case .function: kind = .function
        case .variable: kind = .data
        case nil: kind = .unspecified
        }
        let anchorHint: AddressAnchor? = imp.module.map { .moduleExport(name: $0, export: imp.name) }
        return AddressContext(kind: kind, typeHint: imp.kind?.rawValue, anchorHint: anchorHint)
    }

    fileprivate func symbolContext(_ symbol: LumaCore.ModuleSymbolBundle.Symbol) -> AddressContext {
        let kind: AddressContext.Kind = symbol.isCode
            ? .function
            : (symbol.isData ? .data : .unspecified)
        return AddressContext(kind: kind, typeHint: symbol.type)
    }
}
