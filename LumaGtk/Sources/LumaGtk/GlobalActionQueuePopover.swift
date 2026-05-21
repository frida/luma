import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class GlobalActionQueuePopover {
    let button: MenuButton

    private weak var engine: Engine?
    private let parentWindow: Gtk.Window
    private let popover: Popover
    private let popoverContent: Box
    private let badgeLabel: Label
    private let icon: Gtk.Image

    private var queue: MissionActionQueueView?
    private var observation: StoreObservation?
    private var hadPending = false

    init(parentWindow: Gtk.Window) {
        self.parentWindow = parentWindow

        popoverContent = Box(orientation: .vertical, spacing: 0)
        popoverContent.setSizeRequest(width: 520, height: 480)

        popover = Popover()
        popover.autohide = true
        popover.set(child: popoverContent)

        button = MenuButton()
        button.tooltipText = "Action Queue"
        button.add(cssClass: "flat")
        button.set(popover: popover)

        let buttonContent = Box(orientation: .horizontal, spacing: 4)
        icon = Gtk.Image(iconName: "mail-unread-symbolic")
        icon.pixelSize = 16
        buttonContent.append(child: icon)

        badgeLabel = Label(str: "")
        badgeLabel.add(cssClass: "caption")
        badgeLabel.add(cssClass: "error")
        badgeLabel.visible = false
        buttonContent.append(child: badgeLabel)

        button.set(child: buttonContent)
    }

    func attach(engine: Engine) {
        self.engine = engine
        let queue = MissionActionQueueView(engine: engine, parentWindow: parentWindow)
        self.queue = queue
        popoverContent.append(child: queue.widget)

        apply(actions: (try? engine.store.fetchAllPendingMissionActions()) ?? [])
        observation = engine.store.observeAllPendingMissionActions { [weak self] rows in
            Task { @MainActor in self?.apply(actions: rows) }
        }
    }

    private func apply(actions: [MissionAction]) {
        queue?.update(actions: actions)
        let hasPending = !actions.isEmpty
        if hasPending {
            icon.set(name: "mail-mark-important-symbolic")
            icon.add(cssClass: "warning")
            badgeLabel.label = "\(actions.count)"
            badgeLabel.visible = true
            if !hadPending, !popover.visible {
                popover.popup()
            }
        } else {
            icon.set(name: "mail-unread-symbolic")
            icon.remove(cssClass: "warning")
            badgeLabel.label = ""
            badgeLabel.visible = false
        }
        hadPending = hasPending
    }
}
