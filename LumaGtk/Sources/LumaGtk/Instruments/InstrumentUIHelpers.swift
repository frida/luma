import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
enum InstrumentUIHelpers {
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
        layout: InstrumentLayout,
        engine: Engine,
        instance: LumaCore.InstrumentInstance?
    ) -> InstrumentWidgetsRenderer? {
        guard !widgets.isEmpty else { return nil }
        let renderer = InstrumentWidgetsRenderer(engine: engine, instance: instance, child: nil, widgets: widgets, layout: layout, above: [], margin: 0)
        outer.append(child: renderer.widget)
        return renderer
    }
}
