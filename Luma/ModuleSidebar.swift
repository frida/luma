import LumaCore
import SwiftUI

struct ModuleSidebarChildren: View {
    let sessionID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    var body: some View {
        let modules = engine.session(id: sessionID)?.lastKnownModules ?? []
        let highlights = modules.sidebarHighlights(mainModule: mainModule, selectedID: selectedModuleID)
        ForEach(highlights) { module in
            ModuleSidebarRow(sessionID: sessionID, module: module, engine: engine, selection: $selection)
                .sidebarItemTag(SidebarItemID.module(sessionID, module.id))
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
        if case .module(let sid, let mid) = selection, sid == sessionID { return mid }
        return engine.lastSelectedModuleID(for: sessionID)
    }
}

private struct ModuleSidebarRow: View {
    let sessionID: UUID
    let module: ProcessModule
    let engine: Engine
    @Binding var selection: SidebarItemID?

    var body: some View {
        SidebarFeatureRowLabel(
            icon: { Image(systemName: "shippingbox").font(.system(size: 11)) },
            title: module.name,
            help: module.path,
            accessory: { ModuleAnalysisStatusIndicator(status: status) }
        )
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
