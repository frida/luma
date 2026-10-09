import Foundation
import Gtk
import LumaCore

@MainActor
final class InstrumentDetailPane {
    let widget: Box
    let instrumentID: UUID

    private let editor: InstrumentConfigEditor

    init(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost,
        onComponentAdded: @escaping (UUID) -> Void
    ) {
        self.instrumentID = instrument.id

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        editor = InstrumentConfigEditor(engine: engine, instrument: instrument, host: host)
        widget.append(child: editor.widget)

        editor.setOnComponentAdded(onComponentAdded)

        applySessionState()
    }

    func applySessionState() {
        editor.applySessionState()
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
