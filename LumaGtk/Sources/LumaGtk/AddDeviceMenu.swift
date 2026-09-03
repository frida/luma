import GIO
import GLib
import Gtk

@MainActor
func makeAddDeviceMenuButton(
    bootEnabled: Bool,
    tooltip: String,
    onAddRemote: @escaping () -> Void,
    onBootMachine: @escaping () -> Void
) -> MenuButton {
    let actions = SimpleActionGroup()

    let addRemote = SimpleAction(name: "add-remote", parameterType: VariantTypeRef?.none)
    addRemote.onActivate { _, _ in
        MainActor.assumeIsolated { onAddRemote() }
    }
    actions.add(action: addRemote)

    let bootMachine = SimpleAction(name: "boot-machine", parameterType: VariantTypeRef?.none)
    bootMachine.onActivate { _, _ in
        MainActor.assumeIsolated { onBootMachine() }
    }
    bootMachine.set(enabled: bootEnabled)
    actions.add(action: bootMachine)

    let menu = Menu()
    menu.append(label: "Add Remote Device\u{2026}", detailedAction: "add.add-remote")
    menu.append(label: "Boot Virtual Machine\u{2026}", detailedAction: "add.boot-machine")

    let button = MenuButton()
    button.iconName = "list-add-symbolic"
    button.hasFrame = false
    button.tooltipText = tooltip
    button.set(menuModel: menu)
    button.insertActionGroup(name: "add", group: actions)
    return button
}
