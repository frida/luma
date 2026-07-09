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
    private let statusLabel: Label
    private let filterEntry: SearchEntry
    private let countLabel: Label

    private var bundle: LumaCore.ModuleSymbolBundle?
    private var loadTask: Task<Void, Never>?
    private var tab: Tab = .exports
    private var filterText: String = ""

    enum Tab {
        case exports
        case imports
        case symbols
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

        let filterBar = Box(orientation: .horizontal, spacing: 6)
        filterBar.marginStart = 10
        filterBar.marginEnd = 10
        filterBar.marginTop = 5
        filterBar.marginBottom = 5
        filterBar.append(child: filterEntry)
        filterBar.append(child: countLabel)

        widget.append(child: contentBox)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: filterBar)

        exportsButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.exportsButton.active else { return }
                self.tab = .exports
                self.renderCurrent()
            }
        }
        importsButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.importsButton.active else { return }
                self.tab = .imports
                self.renderCurrent()
            }
        }
        symbolsButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.symbolsButton.active else { return }
                self.tab = .symbols
                self.renderCurrent()
            }
        }

        filterEntry.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.filterText = entry.text
                self.renderCurrent()
            }
        }

        load()
    }

    deinit {
        loadTask?.cancel()
    }

    private func load() {
        loadTask?.cancel()
        guard let engine, let node = engine.node(forSessionID: sessionID) else {
            statusLabel.setText(str: "Process detached")
            statusLabel.visible = true
            return
        }

        let moduleName = module.name
        loadTask = Task { @MainActor [weak self] in
            do {
                let result = try await node.enumerateModuleSymbols(name: moduleName)
                guard let self else { return }
                self.bundle = result
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
        guard let bundle else { return }
        exportsButton.label = "Exports (\(bundle.exports.count))"
        importsButton.label = "Imports (\(bundle.imports.count))"
        symbolsButton.label = "Symbols (\(bundle.symbols.count))"
    }

    private func renderCurrent() {
        clear(listContainer)
        guard let bundle else { return }

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setSizeRequest(width: -1, height: 280)

        let list = ListBox()
        list.selectionMode = .single
        list.add(cssClass: "boxed-list")
        scroll.set(child: list)

        switch tab {
        case .exports:
            let rows = filtered(bundle.exports) { [$0.name, $0.kind.rawValue, hex($0.address)] }
            for export in rows {
                list.append(child: makeRow(
                    title: export.name,
                    typeLabel: export.kind.rawValue,
                    address: export.address,
                    context: exportContext(export)
                ))
            }
            setFilterCount(shown: rows.count, total: bundle.exports.count)
        case .imports:
            let rows = filtered(bundle.imports) { [$0.name, $0.module, $0.kind?.rawValue, $0.address.map(hex)] }
            for imp in rows {
                let typeLabel = [imp.kind?.rawValue, imp.module].compactMap { $0 }.joined(separator: " · ")
                let target = importTarget(imp)
                list.append(child: makeRow(
                    title: imp.name,
                    typeLabel: typeLabel.isEmpty ? "import" : typeLabel,
                    address: target.address,
                    context: target.context
                ))
            }
            setFilterCount(shown: rows.count, total: bundle.imports.count)
        case .symbols:
            let rows = filtered(bundle.symbols) { [$0.name, $0.type, $0.sectionID, $0.size.map { String(format: "0x%x", $0) }, hex($0.address)] }
            for sym in rows {
                let typeLabel = [sym.type, sym.sectionID].compactMap { $0 }.joined(separator: " · ")
                list.append(child: makeRow(
                    title: sym.name,
                    typeLabel: typeLabel,
                    address: sym.address,
                    context: symbolContext(sym)
                ))
            }
            setFilterCount(shown: rows.count, total: bundle.symbols.count)
        }

        listContainer.append(child: scroll)
    }

    private func filtered<T>(_ rows: [T], keys: (T) -> [String?]) -> [T] {
        guard !filterText.isEmpty else { return rows }
        let needle = filterText.lowercased()
        return rows.filter { row in
            keys(row).contains { $0?.lowercased().contains(needle) ?? false }
        }
    }

    private func setFilterCount(shown: Int, total: Int) {
        countLabel.setText(str: filterText.isEmpty ? "" : "Showing \(shown) of \(total)")
    }

    private func hex(_ address: UInt64) -> String {
        String(format: "0x%llx", address)
    }

    private func makeRow(title: String, typeLabel: String, address: UInt64?, context: AddressContext) -> ListBoxRow {
        let row = ListBoxRow()

        let body = Box(orientation: .horizontal, spacing: 12)
        body.marginStart = 12
        body.marginEnd = 12
        body.marginTop = 6
        body.marginBottom = 6

        let nameLabel = Label(str: title)
        nameLabel.halign = .start
        nameLabel.hexpand = true
        nameLabel.xalign = 0
        nameLabel.ellipsize = .end

        let typeChip = Label(str: typeLabel)
        typeChip.halign = .end
        typeChip.add(cssClass: "dim-label")
        typeChip.add(cssClass: "caption")

        let addrLabel = Label(str: address.map { String(format: "0x%llx", $0) } ?? "—")
        addrLabel.halign = .end
        addrLabel.add(cssClass: "monospace")

        body.append(child: nameLabel)
        body.append(child: typeChip)
        body.append(child: addrLabel)
        row.set(child: body)

        guard let address, let engine else { return row }

        let click = GestureClick()
        click.set(button: 1)
        click.onPressed { [weak self] _, nPress, _, _ in
            MainActor.assumeIsolated {
                guard Int(nPress) == 2, let self else { return }
                AddressActionMenu.openInsight(
                    engine: engine,
                    sessionID: self.sessionID,
                    address: address,
                    kind: context.kind == .data ? .memory : .disassembly,
                    failureLabel: "Can\u{2019}t open"
                )
            }
        }
        row.install(controller: click)

        AddressActionMenu.attach(to: row, engine: engine, sessionID: sessionID, address: address, value: String(format: "0x%llx", address), copyLabel: "Copy Address", context: context)

        return row
    }

    private func clear(_ box: Box) {
        var child = box.firstChild
        while let current = child {
            child = current.nextSibling
            box.remove(child: current)
        }
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
