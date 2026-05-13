import Foundation
import Gtk
import LumaCore

@MainActor
final class InstrumentConfigEditor {
    let widget: Box

    private let ui: InstrumentDetailUI

    init(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) {
        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        ui = InstrumentUIRegistry.shared
            .ui(for: instrument.kind)
            .makeDetailUI(engine: engine, instrument: instrument, host: host)
        widget.append(child: ui.widget)
    }

    func update(_ instrument: LumaCore.InstrumentInstance) {
        ui.update(instrument)
    }

    func selectComponent(id: UUID) {
        ui.selectComponent(id: id)
    }

    func showConfigurationView() {
        ui.showConfigurationView()
    }

    func setOnComponentAdded(_ handler: ((UUID) -> Void)?) {
        ui.setOnComponentAdded(handler)
    }

    func applySessionState() {
        ui.applySessionState()
    }
}
