import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
enum ThreadSidebar {
    static func makeThreadRow(thread: LumaCore.ProcessThread) -> (row: ListBoxRow, anchor: Box) {
        SidebarFeatureRow.make(
            icon: makeThreadIcon(),
            title: thread.name ?? "tid \(thread.id)",
            tooltip: "tid \(thread.id)"
        )
    }

    static func attachContextMenu(
        to anchor: Widget,
        thread: LumaCore.ProcessThread,
        engine: Engine,
        sessionID: UUID
    ) {
        let actions = engine.threadActions(sessionID: sessionID, thread: thread)
        guard !actions.isEmpty else { return }

        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.propagationPhase = .capture
        gesture.onPressed { [anchor] _, _, x, y in
            MainActor.assumeIsolated {
                let items: [ContextMenu.Item] = actions.map { action in
                    ContextMenu.Item(action.title, destructive: action.role == .destructive) {
                        Task { @MainActor in
                            if let target = await action.perform() {
                                AddressActionMenu.navigateToTarget?(target)
                            }
                        }
                    }
                }
                ContextMenu.present([items], at: anchor, x: x, y: y)
            }
        }
        anchor.install(controller: gesture)
    }

    static func presentBrowser(
        threads: [LumaCore.ProcessThread],
        anchor: WidgetProtocol,
        onChoose: @escaping @MainActor (LumaCore.ProcessThread) -> Void
    ) {
        let browser = SidebarBrowserPopover(
            items: threads,
            placeholder: "Filter threads",
            emptyMessage: "No matching threads",
            groupName: { $0.name == nil ? "Unnamed" : "Named" },
            title: { $0.name ?? "tid \($0.id)" },
            tooltip: { "tid \($0.id)" },
            matches: { thread, query in
                (thread.name?.localizedCaseInsensitiveContains(query) ?? false)
                    || String(thread.id).localizedCaseInsensitiveContains(query)
            },
            onChoose: onChoose
        )
        browser.presentAnchored(to: anchor)
    }

    private static func makeThreadIcon() -> Widget {
        let icon = Gtk.Image(iconName: "cpu-symbolic")
        icon.pixelSize = 14
        icon.hexpand = true
        icon.halign = .center
        icon.add(cssClass: "dim-label")
        return icon
    }
}
