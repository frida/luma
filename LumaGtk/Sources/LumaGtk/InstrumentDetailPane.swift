import Foundation
import Gtk
import LumaCore

@MainActor
final class InstrumentDetailPane {
    let widget: Box
    let instrumentID: UUID

    private weak var owner: MainWindow?
    private weak var engine: Engine?
    private var sessionID: UUID
    private let bannerSlot: Box
    private var currentBanner: Widget?
    private let editor: InstrumentConfigEditor

    init(engine: Engine, session: LumaCore.ProcessSession, instrument: LumaCore.InstrumentInstance, owner: MainWindow) {
        self.engine = engine
        self.sessionID = session.id
        self.instrumentID = instrument.id
        self.owner = owner

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        bannerSlot = Box(orientation: .vertical, spacing: 0)
        bannerSlot.hexpand = true
        widget.append(child: bannerSlot)

        editor = InstrumentConfigEditor(engine: engine, instrument: instrument)
        widget.append(child: editor.widget)

        applySessionState()
    }

    func applySessionState() {
        guard let engine else { return }
        guard let session = engine.sessions.first(where: { $0.id == sessionID }) else { return }

        if SessionDetachedBanner.shouldShow(for: session) {
            let banner = SessionDetachedBanner.make(for: session) { [weak self] in
                self?.owner?.reestablishSession(id: session.id)
            }
            if let existing = currentBanner {
                bannerSlot.remove(child: existing)
            }
            bannerSlot.append(child: banner)
            currentBanner = banner
        } else if let existing = currentBanner {
            bannerSlot.remove(child: existing)
            currentBanner = nil
        }
    }

    func selectTracerHook(id: UUID) {
        editor.selectTracerHook(id: id)
    }
}
