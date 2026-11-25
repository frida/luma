import Adw
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
final class PharoDisassemblyPage {
    let widget: Box

    private var detail: InsightDetailView?

    init(engine: Engine, reference text: String, runtime: PharoRuntime, onDrill: @escaping (PharoObject) -> Void) {
        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        guard let reference = PharoDisassemblyReference(text) else {
            show("This instruction could not be read")
            return
        }
        guard let session = engine.sessions.first(where: { $0.id == reference.sessionID }) else {
            show("Not in This Project", "The session this instruction is in is not in this project.")
            return
        }
        Task { @MainActor in
            await load(engine: engine, session: session, address: reference.address, runtime: runtime, onDrill: onDrill)
        }
    }

    private func load(
        engine: Engine, session: LumaCore.ProcessSession, address: UInt64, runtime: PharoRuntime, onDrill: @escaping (PharoObject) -> Void
    ) async {
        if let reason = await engine.disassemblyUnavailableReason(sessionID: session.id, address: address) {
            show("Memory Not Readable", reason)
            return
        }
        let start = await engine.disassembler(forSessionID: session.id)?.findFunctionStart(containing: address) ?? address
        let insight = AddressInsight(sessionID: session.id, kind: .disassembly, anchor: .absolute(start))
        let detail = InsightDetailView(engine: engine, session: session, insight: insight, isStored: false)
        detail.openColumn = onDrill
        detail.onActivateLine = { [sessionID = session.id] line in
            Task { @MainActor in
                do {
                    onDrill(try await engine.instruction(at: line, in: sessionID, runtime: runtime))
                } catch {
                    AddressActionMenu.errorReporter?(error.localizedDescription)
                }
            }
        }
        detail.reveal(address)
        self.detail = detail
        widget.append(child: detail.widget)
    }

    private func show(_ title: String, _ description: String? = nil) {
        let page = Adw.StatusPage()
        page.iconName = "action-unavailable-symbolic"
        page.title = title
        page.description = description
        page.vexpand = true
        widget.append(child: page)
    }
}
