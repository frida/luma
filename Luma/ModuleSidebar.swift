import LumaCore
import SwiftUI

struct ModuleSidebarChildren: View {
    let sessionID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var expanded: Set<ProcessModule.ID> = []

    var body: some View {
        let modules = engine.session(id: sessionID)?.lastKnownModules ?? []
        let highlights = modules.sidebarHighlights(mainModule: mainModule, selectedID: selectedModuleID)
        ForEach(highlights) { module in
            let isExpanded = expanded.contains(module.id)
            ModuleSidebarRow(
                sessionID: sessionID,
                module: module,
                engine: engine,
                selection: $selection,
                isExpanded: isExpanded,
                onToggleExpansion: { toggle(module.id) }
            )
            .sidebarItemTag(SidebarItemID.module(sessionID, module.id))
            if isExpanded {
                ModuleContentsSidebarRows(sessionID: sessionID, module: module, engine: engine, selection: $selection)
            }
        }
        .onChange(of: selection, initial: true) {
            if let id = selection?.moduleLocation?.moduleID {
                expanded.insert(id)
            }
        }
        if modules.count > highlights.count {
            SidebarBrowseAllRow(count: modules.count) { dismiss in
                ModuleBrowserPopover(
                    sessionID: sessionID,
                    modules: modules,
                    selection: $selection,
                    onDismiss: dismiss
                )
            }
        }
    }

    private var mainModule: ProcessModule? {
        engine.session(id: sessionID)?.lastKnownMainModule
    }

    private var selectedModuleID: ProcessModule.ID? {
        if let location = selection?.moduleLocation, location.sessionID == sessionID { return location.moduleID }
        return engine.lastSelectedModuleID(for: sessionID)
    }

    private func toggle(_ moduleID: ProcessModule.ID) {
        if expanded.contains(moduleID) {
            expanded.remove(moduleID)
        } else {
            expanded.insert(moduleID)
        }
    }
}

private struct ModuleSidebarRow: View {
    let sessionID: UUID
    let module: ProcessModule
    let engine: Engine
    @Binding var selection: SidebarItemID?
    let isExpanded: Bool
    let onToggleExpansion: () -> Void

    var body: some View {
        SidebarFeatureRowLabel(
            icon: { Image(systemName: "shippingbox").font(.system(size: 11)) },
            title: module.name,
            help: module.path,
            accessory: { ModuleAnalysisStatusIndicator(status: status) }
        )
        .overlay(alignment: .leading) {
            SidebarDisclosure(isExpanded: isExpanded, indent: sidebarGrandchildIndent, onToggle: onToggleExpansion)
        }
        .contextMenu {
            if status == .notAnalyzed {
                Button {
                    engine.analyzeModule(sessionID: sessionID, module: module)
                } label: {
                    Label("Analyze Module", systemImage: "wand.and.rays")
                }
            } else {
                Button {} label: {
                    Label(status == .analyzing ? "Analyzing\u{2026}" : "Analyzed", systemImage: status == .analyzing ? "hourglass" : "checkmark.circle")
                }
                .disabled(true)
            }

            Divider()

            Button {
                copyBaseAddress()
            } label: {
                Label("Copy Base Address", systemImage: "doc.on.doc")
            }
        }
    }

    private var status: ModuleAnalysisStatus {
        engine.moduleAnalysisStatus(sessionID: sessionID, modulePath: module.path)
    }

    private func copyBaseAddress() {
        Platform.copyToClipboard(String(format: "0x%llx", module.base))
    }
}

private struct ModuleContentsSidebarRows: View {
    let sessionID: UUID
    let module: ProcessModule
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var outline: ModuleOutline?
    @State private var areSwiftTypesExpanded = false

    var body: some View {
        categoryRow(.exports)
            .task(id: outlineKey) {
                await loadOutline()
            }
            .onChange(of: selection, initial: true) {
                if case .swiftType(sessionID, module.id, _) = selection {
                    areSwiftTypesExpanded = true
                }
            }
        categoryRow(.imports)
        categoryRow(.symbols)
        switch outline?.swiftTypes {
        case .needsBridge:
            swiftTypesRow(count: nil, canExpand: false)
        case .available(let types):
            swiftTypesRow(count: types.count, canExpand: !types.isEmpty)
            if areSwiftTypesExpanded {
                SwiftTypeSidebarChildren(sessionID: sessionID, module: module, types: types, selection: $selection)
            }
        case .absent, nil:
            EmptyView()
        }
    }

    private func categoryRow(_ category: ModuleSymbolCategory) -> some View {
        SidebarFeatureRowLabel(
            icon: { Image(systemName: category.symbolName).font(.system(size: 11)) },
            title: category.title,
            indent: sidebarGreatGrandchildIndent,
            accessory: { SidebarCount(value: outline?.counts[category]) }
        )
        .sidebarItemTag(SidebarItemID.moduleSymbols(sessionID, module.id, category))
    }

    private func swiftTypesRow(count: Int?, canExpand: Bool) -> some View {
        SidebarFeatureRowLabel(
            icon: { Image(systemName: "swift").font(.system(size: 11)) },
            title: "Swift Types",
            indent: sidebarGreatGrandchildIndent,
            accessory: { SidebarCount(value: count) }
        )
        .overlay(alignment: .leading) {
            SidebarDisclosure(
                isExpanded: areSwiftTypesExpanded,
                canToggle: canExpand,
                indent: sidebarGreatGrandchildIndent,
                onToggle: { areSwiftTypesExpanded.toggle() }
            )
        }
        .sidebarItemTag(SidebarItemID.swiftTypes(sessionID, module.id))
    }

    private var outlineKey: String {
        "\(module.id)\u{0}\(isSwiftBridgeLoaded)"
    }

    private var isSwiftBridgeLoaded: Bool {
        engine.node(forSessionID: sessionID)?.loadedPackageNames.contains(SwiftTypesOutline.bridgePackageName) ?? false
    }

    private func loadOutline() async {
        guard let node = engine.node(forSessionID: sessionID) else { return }
        outline = try? await node.outlineModule(name: module.name)
    }
}

private struct SwiftTypeSidebarChildren: View {
    let sessionID: UUID
    let module: ProcessModule
    let types: [SwiftTypeSummary]
    @Binding var selection: SidebarItemID?

    var body: some View {
        let highlights = types.sidebarHighlights(selectedID: selectedTypeName)
        ForEach(highlights) { type in
            SidebarFeatureRowLabel(
                icon: { Image(systemName: type.kind.symbolName).font(.system(size: 11)) },
                title: type.displayName(inModule: module.name),
                help: "\(type.kind.title) \(type.name)",
                indent: sidebarGreatGreatGrandchildIndent
            )
            .sidebarItemTag(SidebarItemID.swiftType(sessionID, module.id, type))
        }
        if types.count > highlights.count {
            SidebarBrowseAllRow(count: types.count, indent: sidebarGreatGreatGrandchildIndent) { dismiss in
                SidebarBrowserPopover(
                    placeholder: "Filter types",
                    emptyMessage: "No matching types",
                    items: types,
                    groupName: { $0.kind.pluralTitle },
                    title: { $0.displayName(inModule: module.name) },
                    help: { $0.name },
                    isDimmed: { _ in false },
                    matches: { type, query in type.name.localizedCaseInsensitiveContains(query) },
                    onChoose: { type in
                        selection = .swiftType(sessionID, module.id, type)
                        dismiss()
                    }
                )
            }
        }
    }

    private var selectedTypeName: String? {
        if case .swiftType(sessionID, module.id, let type) = selection { return type.name }
        return nil
    }
}

private struct SidebarCount: View {
    let value: Int?

    var body: some View {
        if let value {
            Text("\(value)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ModuleBrowserPopover: View {
    let sessionID: UUID
    let modules: [ProcessModule]
    @Binding var selection: SidebarItemID?
    let onDismiss: () -> Void

    var body: some View {
        SidebarBrowserPopover(
            placeholder: "Filter modules",
            emptyMessage: "No matching modules",
            items: modules.sortedByOrigin(),
            groupName: { $0.isSystemModule ? "System" : "App" },
            title: { $0.name },
            help: { $0.path },
            isDimmed: { _ in false },
            matches: { module, query in
                module.name.localizedCaseInsensitiveContains(query)
                    || module.path.localizedCaseInsensitiveContains(query)
            },
            onChoose: { module in
                selection = .module(sessionID, module.id)
                onDismiss()
            }
        )
    }
}

extension ModuleSymbolCategory {
    var symbolName: String {
        switch self {
        case .exports: return "arrow.up.right.square"
        case .imports: return "arrow.down.left.square"
        case .symbols: return "number.square"
        }
    }
}

extension SwiftTypeKind {
    var symbolName: String {
        switch self {
        case .class: return "c.square"
        case .struct: return "s.square"
        case .enum: return "e.square"
        case .protocol: return "p.square"
        }
    }
}
