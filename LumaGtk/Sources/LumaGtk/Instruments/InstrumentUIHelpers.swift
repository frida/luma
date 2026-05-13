import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
enum InstrumentUIHelpers {
    static func dimLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "dim-label")
        label.halign = .start
        return label
    }

    static func errorLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "error")
        label.halign = .start
        return label
    }

    static func makeBanner(_ text: String) -> Adw.Banner {
        let banner = Adw.Banner(title: text)
        banner.revealed = true
        return banner
    }

    static func appendWidgets(
        into outer: Box,
        widgets: [InstrumentWidget],
        engine: Engine,
        instance: LumaCore.InstrumentInstance
    ) -> InstrumentWidgetsRenderer? {
        guard !widgets.isEmpty else { return nil }
        let renderer = InstrumentWidgetsRenderer(engine: engine, instance: instance, widgets: widgets)
        outer.append(child: renderer.widget)
        return renderer
    }
}
