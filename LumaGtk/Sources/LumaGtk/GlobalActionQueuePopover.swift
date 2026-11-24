import Adw
import Foundation
import Gtk
import LumaCore
import Observation

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
    private var actions: [MissionAction] = []
    private var chatCalls: [ObjectChatToolCall] = []
    private var hadForeground = false
    private var hadWaiting = false

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
        queue.onOpenChat = { [weak self] chatID in self?.openChat(chatID) }
        self.queue = queue
        popoverContent.append(child: queue.widget)

        apply(actions: (try? engine.store.fetchAllPendingMissionActions()) ?? [])
        observation = engine.store.observeAllPendingMissionActions { [weak self] rows in
            Task { @MainActor in self?.apply(actions: rows) }
        }
        followChatCalls()
    }

    private func apply(actions allActions: [MissionAction]) {
        actions = allActions.filter { engine?.isAmbientMission($0.missionID) != true }
        refresh()
        let hasForeground = actions.contains(where: asksMe)
        if hasForeground, !hadForeground, !popover.visible {
            popover.popup()
        }
        hadForeground = hasForeground
    }

    private func refresh() {
        queue?.update(actions: actions, chatCalls: chatCalls)
        let waitingCount = actions.filter(asksMe).count + chatCalls.count
        if waitingCount > 0 {
            icon.setFrom(iconName: "mail-mark-important-symbolic")
            icon.add(cssClass: "warning")
            badgeLabel.label = "\(waitingCount)"
            badgeLabel.visible = true
        } else {
            icon.setFrom(iconName: "mail-unread-symbolic")
            icon.remove(cssClass: "warning")
            badgeLabel.label = ""
            badgeLabel.visible = false
            if hadWaiting, popover.visible {
                popover.popdown()
            }
        }
        hadWaiting = waitingCount > 0
    }

    private func asksMe(_ action: MissionAction) -> Bool {
        engine.map { MissionActionDecision.asksMe(action, engine: $0) } == true
    }

    private func followChatCalls() {
        guard let chats = engine?.objectChats else { return }
        chatCalls = withObservationTracking {
            chats.callsWaitingForMe
        } onChange: { [weak self] in
            Task { @MainActor in self?.followChatCalls() }
        }
        refresh()
    }

    private func openChat(_ chatID: UUID) {
        guard let engine else { return }
        popover.popdown()
        PharoInspectorDialog.present(engine: engine, parent: parentWindow) {
            try await engine.objectChats.column(of: chatID)
        }
    }
}
