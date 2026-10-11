import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
enum ModuleSidebar {
    static func makeModuleRow(
        module: LumaCore.ProcessModule,
        status: ModuleAnalysisStatus,
        disclosure: SidebarFeatureRow.Disclosure
    ) -> (row: ListBoxRow, anchor: Box) {
        SidebarFeatureRow.make(
            icon: makeModuleIcon(),
            title: module.name,
            tooltip: module.path,
            accessory: makeStatusIndicator(status: status),
            disclosure: disclosure
        )
    }

    static func makeCategoryRow(_ category: ModuleSymbolCategory, count: Int?) -> ListBoxRow {
        SidebarFeatureRow.make(
            icon: makeSymbolicIcon(category.iconName),
            title: category.title,
            accessory: count.map(SidebarFeatureRow.makeCount),
            depth: 1
        ).row
    }

    static func makeSwiftTypesRow(count: Int?, disclosure: SidebarFeatureRow.Disclosure?) -> ListBoxRow {
        SidebarFeatureRow.make(
            icon: makeSymbolicIcon("applications-engineering-symbolic"),
            title: "Swift Types",
            accessory: count.map(SidebarFeatureRow.makeCount),
            depth: 1,
            disclosure: disclosure
        ).row
    }

    static func makeSwiftTypeRow(_ type: SwiftTypeSummary, module: LumaCore.ProcessModule) -> ListBoxRow {
        SidebarFeatureRow.make(
            icon: makeKindBadge(type.kind),
            title: type.displayName(inModule: module.name),
            tooltip: "\(type.kind.title) \(type.name)",
            depth: 2
        ).row
    }

    static func presentSwiftTypeBrowser(
        types: [SwiftTypeSummary],
        module: LumaCore.ProcessModule,
        anchor: WidgetProtocol,
        onChoose: @escaping @MainActor (SwiftTypeSummary) -> Void
    ) {
        let browser = SidebarBrowserPopover(
            items: types,
            placeholder: "Filter types",
            emptyMessage: "No matching types",
            groupName: { $0.kind.pluralTitle },
            title: { $0.displayName(inModule: module.name) },
            tooltip: { $0.name },
            matches: { type, query in type.name.localizedCaseInsensitiveContains(query) },
            onChoose: onChoose
        )
        browser.presentAnchored(to: anchor)
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
        anchor.add(controller: gesture)
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

    private static func makeSymbolicIcon(_ name: String) -> Widget {
        let icon = Gtk.Image(iconName: name)
        icon.pixelSize = 12
        icon.hexpand = true
        icon.halign = .center
        icon.add(cssClass: "dim-label")
        return icon
    }

    static func makeKindBadge(_ kind: SwiftTypeKind) -> Label {
        let badge = Label(str: kind.badgeLetter)
        badge.hexpand = true
        badge.halign = .center
        badge.add(cssClass: "dim-label")
        badge.add(cssClass: "caption-heading")
        badge.add(cssClass: "monospace")
        return badge
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

extension ModuleSymbolCategory {
    var iconName: String {
        switch self {
        case .exports: return "go-up-symbolic"
        case .imports: return "go-down-symbolic"
        case .symbols: return "format-justify-left-symbolic"
        }
    }
}

extension SwiftTypeKind {
    var badgeLetter: String {
        String(title.prefix(1))
    }
}
