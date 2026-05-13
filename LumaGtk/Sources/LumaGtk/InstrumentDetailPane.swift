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
    private var lastBannerPhase: LumaCore.ProcessSession.Phase?
    private var lastBannerError: String?
    private var lastBannerArmed: Bool?
    private var lastBannerGatingActive: Bool?
    private let editor: InstrumentConfigEditor

    init(
        engine: Engine,
        session: LumaCore.ProcessSession,
        instrument: LumaCore.InstrumentInstance,
        owner: MainWindow,
        host: InstrumentUIHost,
        onComponentAdded: @escaping (UUID) -> Void
    ) {
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

        editor = InstrumentConfigEditor(engine: engine, instrument: instrument, host: host)
        widget.append(child: editor.widget)

        editor.setOnComponentAdded(onComponentAdded)

        applySessionState()
    }

    func applySessionState() {
        editor.applySessionState()
        guard let engine else { return }
        let session = engine.sessions.first(where: { $0.id == sessionID })

        let wantsBanner = session.map { SessionDetachedBanner.shouldShow(for: $0) } ?? false
        let phase = session?.phase
        let error = session?.lastError
        let armed: Bool? = session.map {
            if case .armed = $0.armingState { return true }
            return false
        }
        let gatingActive: Bool? = session.map { engine.isGatingActive(forDeviceID: $0.deviceID) }
        let bannerDirty = wantsBanner != (currentBanner != nil)
            || phase != lastBannerPhase
            || error != lastBannerError
            || armed != lastBannerArmed
            || gatingActive != lastBannerGatingActive
        lastBannerPhase = phase
        lastBannerError = error
        lastBannerArmed = armed
        lastBannerGatingActive = gatingActive

        guard bannerDirty else { return }

        if let existing = currentBanner {
            bannerSlot.remove(child: existing)
            currentBanner = nil
        }
        guard let session, wantsBanner else { return }
        let banner = SessionDetachedBanner.make(
            for: session,
            gatingActive: engine.isGatingActive(forDeviceID: session.deviceID),
            onReattach: { [weak self] in self?.owner?.reestablishSession(id: session.id) },
            onDisarm: { [weak engine] in
                Task { @MainActor in await engine?.disarmSession(id: session.id) }
            },
            onArm: { [weak self] in self?.owner?.presentArmDialog(session: session) },
            onResumeGating: { [weak engine] in
                Task { @MainActor in await engine?.resumeGating(forSessionID: session.id) }
            }
        )
        bannerSlot.append(child: banner)
        currentBanner = banner
    }

    func selectComponent(id: UUID) {
        editor.selectComponent(id: id)
    }

    func showConfigurationView() {
        editor.showConfigurationView()
    }

    func update(_ instrument: LumaCore.InstrumentInstance) {
        editor.update(instrument)
    }
}
