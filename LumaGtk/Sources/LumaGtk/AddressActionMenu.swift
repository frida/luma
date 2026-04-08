import CGtk
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
enum AddressActionMenu {
    static var navigator: ((UUID, UUID) -> Void)?
    static var errorReporter: ((String) -> Void)?

    static func attach(to anchor: Widget, engine: Engine, sessionID: UUID, address: UInt64) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.propagationPhase = GTK_PHASE_CAPTURE
        gesture.onPressed { [anchor] _, _, x, y in
            MainActor.assumeIsolated {
                present(at: anchor, x: x, y: y, engine: engine, sessionID: sessionID, address: address)
            }
        }
        anchor.install(controller: gesture)
    }

    private static func present(at anchor: Widget, x: Double, y: Double, engine: Engine, sessionID: UUID, address: UInt64) {
        let popover = Popover()
        popover.autohide = true

        let box = Box(orientation: .vertical, spacing: 2)
        box.add(cssClass: "luma-menu")
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let openMemoryButton = Button(label: "Open Memory")
        openMemoryButton.add(cssClass: "luma-menu-item")
        openMemoryButton.onClicked { [popover] _ in
            MainActor.assumeIsolated {
                popover.popdown()
                openInsight(engine: engine, sessionID: sessionID, address: address, kind: .memory, failureLabel: "Can\u{2019}t open memory")
            }
        }
        box.append(child: openMemoryButton)

        let openDisassemblyButton = Button(label: "Open Disassembly")
        openDisassemblyButton.add(cssClass: "luma-menu-item")
        openDisassemblyButton.onClicked { [popover] _ in
            MainActor.assumeIsolated {
                popover.popdown()
                openInsight(engine: engine, sessionID: sessionID, address: address, kind: .disassembly, failureLabel: "Can\u{2019}t open disassembly")
            }
        }
        box.append(child: openDisassemblyButton)

        popover.set(child: WidgetRef(box.widget_ptr))
        popover.set(parent: anchor)
        popover.presentPointing(at: x, y: y)
    }

    private static func openInsight(
        engine: Engine,
        sessionID: UUID,
        address: UInt64,
        kind: AddressInsight.Kind,
        failureLabel: String
    ) {
        do {
            let insight = try engine.getOrCreateInsight(sessionID: sessionID, pointer: address, kind: kind)
            navigator?(sessionID, insight.id)
        } catch {
            errorReporter?("\(failureLabel): \(error.localizedDescription)")
        }
    }
}
