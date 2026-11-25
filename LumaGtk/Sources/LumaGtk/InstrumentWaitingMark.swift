import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class InstrumentWaitingMark {
    let widget = Label(str: "")

    private weak var engine: Engine?
    private let instance: LumaCore.InstrumentInstance

    init(engine: Engine, instance: LumaCore.InstrumentInstance) {
        self.engine = engine
        self.instance = instance
        let color = MissionPalette.color(for: MissionStatus.awaitingApproval)
        widget.useMarkup = true
        widget.setMarkup(str: "<span foreground=\"\(color.hex)\">\u{25CF}</span>")
        widget.valign = .center
        observe()
    }

    static func sentence(engine: Engine, instance: LumaCore.InstrumentInstance) -> String? {
        if engine.instrumentViews.approvalWanted(byInstance: instance.id) != nil {
            return "Waiting for you to allow"
        }
        return engine.approvalAwaitedFromHost(of: instance).map { "Waiting for \($0.name) to allow" }
    }

    private func observe() {
        guard let engine else { return }
        let instance = instance
        let sentence = withObservationTracking {
            Self.sentence(engine: engine, instance: instance)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        widget.visible = sentence != nil
        widget.tooltipText = sentence
        widget.setAccessibleLabel(sentence ?? "")
    }
}
