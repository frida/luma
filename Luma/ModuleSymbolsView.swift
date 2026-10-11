import LumaCore
import SwiftUI

struct ModuleSymbolsView: View {
    let sessionID: UUID
    let module: LumaCore.ProcessModule
    let category: LumaCore.ModuleSymbolCategory
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var page: LumaCore.ModuleSymbolPage?
    @State private var loadError: String?
    @State private var selectedRowID: Int?
    @State private var facts: [UInt64: AddressFacts] = [:]
    @State private var filterText: String = ""
    @State private var pageIndex = 0
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .detailPaneInset(.leading)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            filterBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: filterText) { pageIndex = 0 }
        .task(id: queryKey) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await runQuery()
        }
    }

    private var queryKey: String {
        "\(module.id)\u{0}\(filterText)\u{0}\(pageIndex)"
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            Text(loadError)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch page?.rows {
            case .exports(let rows): exportsTable(rows)
            case .imports(let rows): importsTable(rows)
            case .symbols(let rows): symbolsTable(rows)
            case nil: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filterBar: some View {
        DetailFilterBar(text: $filterText, isFocused: $filterFocused) {
            if let page {
                DetailFilterStatus(text: rangeStatus(page))
                Button { pageIndex = max(0, pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .disabled(!page.hasPrevious)
                Button { pageIndex = min(lastPageIndex(page), pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .disabled(!page.hasNext)
            }
        }
    }

    private func lastPageIndex(_ page: LumaCore.ModuleSymbolPage) -> Int {
        guard page.matched > 0 else { return 0 }
        return (page.matched - 1) / LumaCore.ModuleSymbolPage.pageSize
    }

    private func rangeStatus(_ page: LumaCore.ModuleSymbolPage) -> String {
        guard page.matched > 0 else { return "No matches" }
        let first = page.offset + 1
        let last = page.offset + page.count
        return "\(first)–\(last) of \(page.matched)"
    }

    // Symbols routinely share name+address (aliases, mapping symbols, empty
    // names), so the models' data-derived ids collide; position gives the
    // Table a collision-free identity so row selection stays stable.
    private struct IndexedRow<T>: Identifiable {
        let id: Int
        let value: T
    }

    private func indexed<T>(_ rows: [T]) -> [IndexedRow<T>] {
        rows.enumerated().map { IndexedRow(id: $0.offset, value: $0.element) }
    }

    private func exportsTable(_ rows: [LumaCore.ModuleSymbolBundle.Export]) -> some View {
        Table(indexed(rows), selection: $selectedRowID) {
            TableColumn("Name") { r in rowCell(Text(r.value.name), address: r.value.address, context: addressContext(for: r.value)) }
            TableColumn("Type") { r in rowCell(Text(r.value.kind.rawValue), address: r.value.address, context: addressContext(for: r.value)) }
            TableColumn("Address") { r in rowCell(addressText(r.value.address), address: r.value.address, context: addressContext(for: r.value)) }
        }
        .frame(minHeight: 240, idealHeight: 360)
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, rows.indices.contains(id) {
                let e = rows[id]
                addressMenu(address: e.address, context: addressContext(for: e))
            }
        }
    }

    private func importsTable(_ rows: [LumaCore.ModuleSymbolBundle.Import]) -> some View {
        Table(indexed(rows), selection: $selectedRowID) {
            TableColumn("Name") { r in importCell(Text(r.value.name), r.value) }
            TableColumn("Module") { r in importCell(Text(r.value.module ?? "—"), r.value) }
            TableColumn("Type") { r in importCell(Text(r.value.kind?.rawValue ?? "—"), r.value) }
            TableColumn("Address") { r in
                if let addr = r.value.address {
                    rowCell(addressText(addr), address: addr, context: addressContext(for: r.value))
                } else {
                    Text("—")
                }
            }
        }
        .frame(minHeight: 240, idealHeight: 360)
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, rows.indices.contains(id), let addr = rows[id].address {
                addressMenu(address: addr, context: addressContext(for: rows[id]))
            }
        }
    }

    private func symbolsTable(_ rows: [LumaCore.ModuleSymbolBundle.Symbol]) -> some View {
        Table(indexed(rows), selection: $selectedRowID) {
            TableColumn("Name") { r in rowCell(Text(r.value.name), address: r.value.address, context: addressContext(for: r.value)) }
            TableColumn("Type") { r in rowCell(Text(r.value.type), address: r.value.address, context: addressContext(for: r.value)) }
            TableColumn("Section") { r in rowCell(Text(r.value.sectionID ?? "—"), address: r.value.address, context: addressContext(for: r.value)) }
            TableColumn("Size") { r in
                rowCell(
                    Text(r.value.size.map { String(format: "0x%x", $0) } ?? "—").font(.system(.body, design: .monospaced)),
                    address: r.value.address,
                    context: addressContext(for: r.value)
                )
            }
            TableColumn("Address") { r in rowCell(addressText(r.value.address), address: r.value.address, context: addressContext(for: r.value)) }
        }
        .frame(minHeight: 240, idealHeight: 360)
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, rows.indices.contains(id) {
                let s = rows[id]
                addressMenu(address: s.address, context: addressContext(for: s))
            }
        }
    }

    private func addressText(_ address: UInt64) -> some View {
        Text(String(format: "0x%llx", address))
            .font(.system(.body, design: .monospaced))
    }

    @ViewBuilder
    private func importCell<V: View>(_ content: V, _ imp: LumaCore.ModuleSymbolBundle.Import) -> some View {
        if let addr = imp.address {
            rowCell(content, address: addr, context: addressContext(for: imp))
        } else {
            content
        }
    }

    private func rowCell<V: View>(_ content: V, address: UInt64, context: AddressContext) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering in
                guard hovering, facts[address] == nil else { return }
                Task { facts[address] = await engine.addressFacts(sessionID: sessionID, address: address, context: context) }
            }
    }

    @ViewBuilder
    private func addressMenu(address: UInt64, context: AddressContext) -> some View {
        AddressMenuItems(
            engine: engine,
            sessionID: sessionID,
            value: String(format: "0x%llx", address),
            address: address,
            context: context,
            copyTitle: "Copy Address",
            facts: facts[address],
            selection: $selection
        ) {
            EmptyView()
        }
    }

    private func runQuery() async {
        guard let node = engine.node(forSessionID: sessionID) else {
            loadError = "Process is detached."
            return
        }
        do {
            let result = try await node.queryModuleSymbols(
                name: module.name,
                category: category,
                query: filterText,
                offset: pageIndex * LumaCore.ModuleSymbolPage.pageSize
            )
            guard !Task.isCancelled else { return }
            page = result
            selectedRowID = nil
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

extension ModuleSymbolsView {
    fileprivate func addressContext(for export: LumaCore.ModuleSymbolBundle.Export) -> AddressContext {
        AddressContext(
            kind: export.kind == .function ? .function : .data,
            typeHint: export.kind.rawValue,
            anchorHint: .moduleExport(name: module.name, export: export.name)
        )
    }

    fileprivate func addressContext(for imp: LumaCore.ModuleSymbolBundle.Import) -> AddressContext {
        let kind: AddressContext.Kind
        switch imp.kind {
        case .function: kind = .function
        case .variable: kind = .data
        case nil: kind = .unspecified
        }
        let anchorHint: AddressAnchor? = imp.module.map { .moduleExport(name: $0, export: imp.name) }
        return AddressContext(kind: kind, typeHint: imp.kind?.rawValue, anchorHint: anchorHint)
    }

    fileprivate func addressContext(for symbol: LumaCore.ModuleSymbolBundle.Symbol) -> AddressContext {
        let kind: AddressContext.Kind = symbol.isCode
            ? .function
            : (symbol.isData ? .data : .unspecified)
        return AddressContext(kind: kind, typeHint: symbol.type)
    }
}
