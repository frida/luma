import Adw
import CGtk
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class ThreadDetailPane {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let thread: LumaCore.ProcessThread

    private let titleLabel: Label
    private let stateLabel: Label
    private let entryLabel: Label
    private let refreshButton: Button
    private let actionsButton: MenuButton
    private let registerList: FlowBox
    private let messageLabel: Label

    private var loadTask: Task<Void, Never>?

    init(engine: Engine, sessionID: UUID, thread: LumaCore.ProcessThread) {
        self.engine = engine
        self.sessionID = sessionID
        self.thread = thread

        widget = Box(orientation: .vertical, spacing: 6)
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12

        let headerRow = Box(orientation: .horizontal, spacing: 8)

        titleLabel = Label(str: thread.name ?? "tid \(thread.id)")
        titleLabel.halign = .start
        titleLabel.add(cssClass: "heading")
        titleLabel.hexpand = true
        titleLabel.xalign = 0

        stateLabel = Label(str: "")
        stateLabel.add(cssClass: "dim-label")
        stateLabel.add(cssClass: "caption")

        refreshButton = Button()
        refreshButton.set(iconName: "view-refresh-symbolic")
        refreshButton.tooltipText = "Refresh registers"

        actionsButton = MenuButton()
        actionsButton.set(iconName: "view-more-symbolic")
        actionsButton.tooltipText = "Thread actions"
        actionsButton.visible = false

        headerRow.append(child: titleLabel)
        headerRow.append(child: stateLabel)
        headerRow.append(child: refreshButton)
        headerRow.append(child: actionsButton)

        entryLabel = Label(str: "")
        entryLabel.halign = .start
        entryLabel.add(cssClass: "dim-label")
        entryLabel.add(cssClass: "monospace")
        entryLabel.visible = false

        registerList = FlowBox()
        registerList.selectionMode = .none
        registerList.homogeneous = true
        registerList.minChildrenPerLine = 1
        registerList.maxChildrenPerLine = 8
        registerList.columnSpacing = 16
        registerList.rowSpacing = 2
        registerList.hexpand = true
        registerList.valign = .start

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: registerList)

        messageLabel = Label(str: "Loading…")
        messageLabel.halign = .start
        messageLabel.add(cssClass: "dim-label")

        widget.append(child: headerRow)
        widget.append(child: entryLabel)
        widget.append(child: messageLabel)
        widget.append(child: scroll)

        if let entry = thread.entrypoint {
            entryLabel.setText(str: String(format: "Entry: 0x%llx", entry.routine))
            entryLabel.visible = true
        }

        configureActionsMenu()

        refreshButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }

        reload()
    }

    deinit {
        loadTask?.cancel()
    }

    private func configureActionsMenu() {
        guard let engine else { return }
        let actions = engine.threadActions(sessionID: sessionID, thread: thread)
        guard !actions.isEmpty else { return }

        let popoverBox = Box(orientation: .vertical, spacing: 0)
        let popover = Popover()
        popover.set(child: popoverBox)

        for action in actions {
            let button = Button(label: action.title)
            button.add(cssClass: "flat")
            button.halign = .start
            button.onClicked { [popover] _ in
                MainActor.assumeIsolated {
                    Task { @MainActor in
                        if let target = await action.perform() {
                            AddressActionMenu.navigateToTarget?(target)
                        }
                    }
                    popover.popdown()
                }
            }
            popoverBox.append(child: button)
        }

        actionsButton.set(popover: popover)
        actionsButton.visible = true
    }

    private func reload() {
        loadTask?.cancel()
        guard let engine, let node = engine.node(forSessionID: sessionID) else {
            messageLabel.setText(str: "Process is detached.")
            messageLabel.visible = true
            return
        }

        messageLabel.setText(str: "Loading…")
        messageLabel.visible = true

        let tid = thread.id
        loadTask = Task { @MainActor [weak self] in
            do {
                let snapshot = try await node.fetchThreadSnapshot(id: tid)
                guard let self else { return }
                if let snapshot {
                    self.render(snapshot)
                } else {
                    self.messageLabel.setText(str: "Thread no longer exists.")
                }
            } catch {
                guard let self else { return }
                self.messageLabel.setText(str: error.localizedDescription)
            }
        }
    }

    private func render(_ snapshot: LumaCore.ThreadSnapshot) {
        messageLabel.visible = false
        stateLabel.setText(str: snapshot.state)
        clear(registerList)

        for reg in snapshot.registers {
            registerList.append(child: makeRegisterRow(reg))
        }
    }

    private func makeRegisterRow(_ reg: LumaCore.ThreadSnapshot.Register) -> Box {
        let row = Box(orientation: .horizontal, spacing: 12)
        row.marginStart = 4
        row.marginEnd = 4

        let nameLabel = Label(str: reg.name)
        nameLabel.add(cssClass: "monospace")
        nameLabel.add(cssClass: "dim-label")
        nameLabel.setSizeRequest(width: 64, height: -1)
        nameLabel.xalign = 1
        nameLabel.halign = .end

        let valueLabel = Label(str: reg.rawValue)
        valueLabel.add(cssClass: "monospace")
        valueLabel.selectable = reg.pointerValue == nil
        valueLabel.halign = .start
        valueLabel.xalign = 0
        valueLabel.hexpand = true

        row.append(child: nameLabel)
        row.append(child: valueLabel)

        if let address = reg.pointerValue, let engine {
            AddressActionMenu.attach(
                to: valueLabel,
                engine: engine,
                sessionID: sessionID,
                address: address,
                value: reg.rawValue,
                context: AddressContext(kind: registerKind(reg))
            )
        }

        return row
    }

    private func registerKind(_ reg: LumaCore.ThreadSnapshot.Register) -> AddressContext.Kind {
        switch reg.name {
        case "pc", "rip", "eip": return .code
        default: return .unspecified
        }
    }

    private func clear(_ box: FlowBox) {
        while let child = box.firstChild {
            box.remove(widget: child)
        }
    }
}
