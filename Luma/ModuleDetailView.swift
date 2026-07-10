import LumaCore
import SwiftUI

struct ModuleDetailView: View {
    let sessionID: UUID
    let module: LumaCore.ProcessModule
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var page: LumaCore.ModuleSymbolPage?
    @State private var counts: LumaCore.ModuleSymbolPage.Counts?
    @State private var loadError: String?
    @State private var tab: Tab = .exports
    @State private var selectedRowID: String?
    @State private var facts: [UInt64: AddressFacts] = [:]
    @State private var filterText: String = ""

    enum Tab: String, CaseIterable, Identifiable {
        case exports = "Exports"
        case imports = "Imports"
        case symbols = "Symbols"

        var id: String { rawValue }

        var category: LumaCore.ModuleSymbolCategory {
            switch self {
            case .exports: return .exports
            case .imports: return .imports
            case .symbols: return .symbols
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Text(label(for: t)).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                content
            }
            .padding(.leading, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            filterBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: queryKey) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await runQuery()
        }
    }

    private var queryKey: String {
        "\(module.id)\u{0}\(tab.rawValue)\u{0}\(filterText)"
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            Text(loadError)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch page?.rows {
            case .exports(let rows) where tab == .exports: exportsTable(rows)
            case .imports(let rows) where tab == .imports: importsTable(rows)
            case .symbols(let rows) where tab == .symbols: symbolsTable(rows)
            default: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func label(for tab: Tab) -> String {
        guard let counts else { return tab.rawValue }
        return "\(tab.rawValue) (\(counts[tab.category]))"
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Filter", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if let page {
                Text(filterStatus(page))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
            }
            if !filterText.isEmpty {
                Button(action: { filterText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func filterStatus(_ page: LumaCore.ModuleSymbolPage) -> String {
        let total = page.counts[tab.category]
        if page.capped {
            return "Showing first \(LumaCore.ModuleSymbolPage.queryLimit) of \(page.matched) — refine filter"
        }
        if !filterText.isEmpty {
            return "Showing \(page.matched) of \(total)"
        }
        return ""
    }

    private func exportsTable(_ rows: [LumaCore.ModuleSymbolBundle.Export]) -> some View {
        Table(rows, selection: $selectedRowID) {
            TableColumn("Name") { e in rowCell(Text(e.name), address: e.address, context: addressContext(for: e)) }
            TableColumn("Type") { e in rowCell(Text(e.kind.rawValue), address: e.address, context: addressContext(for: e)) }
            TableColumn("Address") { e in rowCell(addressText(e.address), address: e.address, context: addressContext(for: e)) }
        }
        .frame(minHeight: 240, idealHeight: 360)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let e = rows.first(where: { $0.id == id }) {
                addressMenu(address: e.address, context: addressContext(for: e))
            }
        }
    }

    private func importsTable(_ rows: [LumaCore.ModuleSymbolBundle.Import]) -> some View {
        Table(rows, selection: $selectedRowID) {
            TableColumn("Name") { i in importCell(Text(i.name), i) }
            TableColumn("Module") { i in importCell(Text(i.module ?? "—"), i) }
            TableColumn("Type") { i in importCell(Text(i.kind?.rawValue ?? "—"), i) }
            TableColumn("Address") { i in
                if let addr = i.address {
                    rowCell(addressText(addr), address: addr, context: addressContext(for: i))
                } else {
                    Text("—")
                }
            }
        }
        .frame(minHeight: 240, idealHeight: 360)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let i = rows.first(where: { $0.id == id }), let addr = i.address {
                addressMenu(address: addr, context: addressContext(for: i))
            }
        }
    }

    private func symbolsTable(_ rows: [LumaCore.ModuleSymbolBundle.Symbol]) -> some View {
        Table(rows, selection: $selectedRowID) {
            TableColumn("Name") { s in rowCell(Text(s.name), address: s.address, context: addressContext(for: s)) }
            TableColumn("Type") { s in rowCell(Text(s.type), address: s.address, context: addressContext(for: s)) }
            TableColumn("Section") { s in rowCell(Text(s.sectionID ?? "—"), address: s.address, context: addressContext(for: s)) }
            TableColumn("Size") { s in
                rowCell(
                    Text(s.size.map { String(format: "0x%x", $0) } ?? "—").font(.system(.body, design: .monospaced)),
                    address: s.address,
                    context: addressContext(for: s)
                )
            }
            TableColumn("Address") { s in rowCell(addressText(s.address), address: s.address, context: addressContext(for: s)) }
        }
        .frame(minHeight: 240, idealHeight: 360)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let s = rows.first(where: { $0.id == id }) {
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
                category: tab.category,
                query: filterText
            )
            page = result
            counts = result.counts
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

extension ModuleDetailView {
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
