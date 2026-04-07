import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
enum AddressActionMenu {
    static func attach(to anchor: Widget, engine: Engine, sessionID: UUID, address: UInt64) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.onPressed { [weak anchor] _, _, _, _ in
            MainActor.assumeIsolated {
                guard let anchor else { return }
                present(at: anchor, engine: engine, sessionID: sessionID, address: address)
            }
        }
        anchor.add(controller: gesture)
    }

    private static func present(at anchor: Widget, engine: Engine, sessionID: UUID, address: UInt64) {
        let popover = Popover()
        popover.autohide = true

        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let hexString = String(format: "0x%llx", address)

        let copyButton = Button(label: "Copy address (\(hexString))")
        copyButton.add(cssClass: "flat")
        copyButton.onClicked { [weak popover] _ in
            MainActor.assumeIsolated {
                if let display = Display.getDefault() {
                    display.clipboard.set(text: hexString)
                }
                popover?.popdown()
            }
        }
        box.append(child: copyButton)

        let detailsButton = Button(label: "Show details\u{2026}")
        detailsButton.add(cssClass: "flat")
        detailsButton.onClicked { [weak popover, weak anchor] _ in
            MainActor.assumeIsolated {
                popover?.popdown()
                guard let anchor else { return }
                AddressDetailsPanel.present(
                    from: anchor,
                    engine: engine,
                    sessionID: sessionID,
                    address: address
                )
            }
        }
        box.append(child: detailsButton)

        let memoryButton = Button(label: "Show memory\u{2026}")
        memoryButton.add(cssClass: "flat")
        memoryButton.onClicked { [weak popover, weak anchor] _ in
            MainActor.assumeIsolated {
                popover?.popdown()
                guard let anchor else { return }
                MemoryViewerWindow.present(
                    from: anchor,
                    engine: engine,
                    sessionID: sessionID,
                    address: address
                )
            }
        }
        box.append(child: memoryButton)

        if engine.node(forSessionID: sessionID) != nil {
            let actions = engine.addressActions(sessionID: sessionID, address: address)
            if !actions.isEmpty {
                box.append(child: Separator(orientation: .horizontal))
            }
            for action in actions {
                let button = Button(label: action.title)
                button.add(cssClass: "flat")
                if action.role == .destructive {
                    button.add(cssClass: "destructive-action")
                }
                let perform = action.perform
                button.onClicked { [weak popover] _ in
                    MainActor.assumeIsolated {
                        popover?.popdown()
                        Task { @MainActor in
                            _ = await perform()
                        }
                    }
                }
                box.append(child: button)
            }
        }

        popover.set(child: WidgetRef(box.widget_ptr))
        popover.set(parent: anchor)
        popover.popup()
    }
}
