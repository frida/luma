import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
enum ModuleSidebar {
    static func makeModuleRow(
        module: LumaCore.ProcessModule,
        status: ModuleAnalysisStatus
    ) -> (row: ListBoxRow, anchor: Box) {
        SidebarFeatureRow.make(
            icon: makeModuleIcon(),
            title: module.name,
            tooltip: module.path,
            accessory: makeStatusIndicator(status: status)
        )
    }

    static func attachContextMenu(
        to anchor: Widget,
        module: LumaCore.ProcessModule,
        engine: Engine,
        sessionID: UUID
    ) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.propagationPhase = .capture
        gesture.onPressed { [anchor, weak engine] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let engine else { return }
                _ = gesture.set(state: .claimed)
                AddressActionMenu.present(
                    at: anchor, x: x, y: y, engine: engine, sessionID: sessionID,
                    address: module.base, value: String(format: "0x%llx", module.base),
                    extraSections: [analyzeSection(module: module, engine: engine, sessionID: sessionID)]
                )
            }
        }
        anchor.install(controller: gesture)
    }

    static func presentBrowser(
        modules: [LumaCore.ProcessModule],
        anchor: WidgetProtocol,
        onChoose: @escaping @MainActor (LumaCore.ProcessModule) -> Void
    ) {
        let browser = SidebarBrowserPopover(
            items: modules.sortedByOrigin(),
            placeholder: "Filter modules",
            emptyMessage: "No matching modules",
            groupName: { $0.isSystemModule ? "System" : "App" },
            title: { $0.name },
            tooltip: { $0.path },
            matches: { module, query in
                module.name.localizedCaseInsensitiveContains(query)
                    || module.path.localizedCaseInsensitiveContains(query)
            },
            onChoose: onChoose
        )
        browser.presentAnchored(to: anchor)
    }

    private static func analyzeSection(
        module: LumaCore.ProcessModule,
        engine: Engine,
        sessionID: UUID
    ) -> [ContextMenu.Item] {
        switch engine.moduleAnalysisStatus(sessionID: sessionID, modulePath: module.path) {
        case .notAnalyzed:
            return [ContextMenu.Item("Analyze") { engine.analyzeModule(sessionID: sessionID, module: module) }]
        case .analyzing:
            return [ContextMenu.Item("Analyzing\u{2026}", enabled: false) {}]
        case .analyzed:
            return [ContextMenu.Item("Analyzed", enabled: false) {}]
        }
    }

    private static func makeModuleIcon() -> Widget {
        let icon = Gtk.Image(iconName: "package-x-generic-symbolic")
        icon.pixelSize = 14
        icon.hexpand = true
        icon.halign = .center
        icon.add(cssClass: "dim-label")
        return icon
    }

    private static func makeStatusIndicator(status: ModuleAnalysisStatus) -> Widget? {
        switch status {
        case .notAnalyzed:
            return nil
        case .analyzing:
            let spinner = makeSpinner()
            spinner.tooltipText = "Analyzing\u{2026}"
            return spinner
        case .analyzed:
            let icon = Gtk.Image(iconName: "emblem-ok-symbolic")
            icon.pixelSize = 12
            icon.tooltipText = "Analyzed"
            icon.add(cssClass: "success")
            return icon
        }
    }
}
