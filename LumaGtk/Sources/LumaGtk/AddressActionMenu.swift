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
        ContextMenu.present([
            [
                .init("Open Memory") {
                    openInsight(engine: engine, sessionID: sessionID, address: address, kind: .memory, failureLabel: "Can\u{2019}t open memory")
                },
                .init("Open Disassembly") {
                    openInsight(engine: engine, sessionID: sessionID, address: address, kind: .disassembly, failureLabel: "Can\u{2019}t open disassembly")
                },
            ],
        ], at: anchor, x: x, y: y)
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
