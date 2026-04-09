import CGtk
import GIO
import GLib
import Gtk

@MainActor
enum ContextMenu {
    struct Item {
        let label: String
        let isDestructive: Bool
        let handler: () -> Void

        init(_ label: String, destructive: Bool = false, handler: @escaping () -> Void) {
            self.label = label
            self.isDestructive = destructive
            self.handler = handler
        }
    }

    static func present(
        _ sections: [[Item]],
        at anchor: Widget,
        x: Double,
        y: Double
    ) {
        let menu = GIO.Menu()
        let group = GIO.SimpleActionGroup()
        var destructiveButtons: [(id: String, text: String, actionName: String)] = []
        var idx = 0

        for items in sections where !items.isEmpty {
            let section = GIO.Menu()
            for item in items {
                let name = "a\(idx)"
                idx += 1

                let actionPtr = g_simple_action_new(name, nil)!
                let action = GIO.SimpleActionRef(raw: UnsafeMutableRawPointer(actionPtr))
                let handler = item.handler
                action.onActivate { _, _ in
                    MainActor.assumeIsolated { handler() }
                }
                actionPtr.withMemoryRebound(to: GAction.self, capacity: 1) { ptr in
                    g_action_map_add_action(group.action_map_ptr, ptr)
                }
                g_object_unref(actionPtr)

                if item.isDestructive {
                    let mi = GIO.MenuItem(label: nil, detailedAction: nil)
                    g_menu_item_set_attribute_value(
                        mi.menu_item_ptr,
                        "custom",
                        g_variant_new_string(name)
                    )
                    section.append(item: mi)
                    destructiveButtons.append((id: name, text: item.label, actionName: "menu.\(name)"))
                } else {
                    section.append(label: item.label, detailedAction: "menu.\(name)")
                }
            }
            menu.appendSection(label: nil, section: section)
        }

        anchor.insertActionGroup(name: "menu", group: group)

        let popover = PopoverMenu(model: menu)
        popover.hasArrow = false

        for item in destructiveButtons {
            let button = Button(label: item.text)
            button.add(cssClass: "destructive-action")
            button.set(actionName: item.actionName)
            _ = popover.add(child: button, id: item.id)
        }

        popover.set(parent: anchor)
        popover.onClosed { popover in
            popover.unparent()
        }
        popover.presentPointing(at: x, y: y)
    }
}
