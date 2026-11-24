import Foundation
import Gtk
import LumaCore

extension Notification.Name {
    static let lumaSelectCustomInstrumentDef = Notification.Name("LumaGtk.SelectCustomInstrumentDef")
}

@MainActor
final class CustomUIKind: InstrumentUIKind {
    func makeDetailUI(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> InstrumentDetailUI {
        CustomDetailUI(engine: engine, instrument: instrument)
    }
}

@MainActor
private final class CustomDetailUI: InstrumentDetailUI {
    let widget: Widget

    private weak var engine: Engine?
    private var instrument: LumaCore.InstrumentInstance
    private let outer: Box
    private var settingRows: [InstrumentSettingRow] = []
    private var widgetRenderer: InstrumentWidgetsRenderer?
    private let updateBanner: StoreUpdateBanner?

    init(engine: Engine, instrument: LumaCore.InstrumentInstance) {
        self.engine = engine
        self.instrument = instrument

        let outer = Box(orientation: .vertical, spacing: 12)
        outer.hexpand = true
        outer.marginStart = 8
        outer.marginEnd = 8
        outer.marginTop = 8
        outer.marginBottom = 8
        self.outer = outer

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroll.set(naturallyTallChild: outer)

        let column = Box(orientation: .vertical, spacing: 0)
        updateBanner = UUID(uuidString: instrument.sourceIdentifier).map { StoreUpdateBanner(storefront: engine.storefront, defID: $0) }
        if let updateBanner {
            column.append(child: updateBanner.widget)
        }
        column.append(child: scroll)
        widget = column

        rebuild()
    }

    func update(_ instrument: LumaCore.InstrumentInstance) {
        guard instrument.configJSON != self.instrument.configJSON else { return }
        self.instrument = instrument
        rebuild()
        applySessionState()
    }

    func applySessionState() {
        widgetRenderer?.refreshAgentState()
    }

    private func rebuild() {
        while let child = outer.firstChild {
            outer.remove(child: child)
        }
        widgetRenderer = nil
        settingRows.removeAll()

        guard let engine,
            let config = try? CustomInstrumentConfig.decode(from: instrument.configJSON),
            let def = engine.customInstruments.def(withId: config.defID)
        else {
            outer.append(child: InstrumentUIHelpers.errorLabel("Custom instrument not found"))
            return
        }

        outer.append(child: makeHeader(def: def))

        if !def.features.isEmpty {
            outer.append(child: InstrumentSettingRow.makeGroup(features: def.features, config: config, keeping: &settingRows) { [weak self] id, state in
                self?.mutate { $0.features[id] = state }
            })
        }

        widgetRenderer = InstrumentUIHelpers.appendWidgets(
            into: outer,
            widgets: def.widgets,
            engine: engine,
            instance: instrument
        )
        widgetRenderer?.refreshAgentState()
    }

    private func makeHeader(def: CustomInstrumentDef) -> Box {
        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: InstrumentIconView.makeImage(for: def.icon, pixelSize: 16))
        let title = Label(str: def.name)
        title.add(cssClass: "heading")
        title.halign = .start
        title.hexpand = true
        header.append(child: title)
        let editButton = Button(label: "Edit Source\u{2026}")
        let defID = def.id
        editButton.onClicked { _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(
                    name: .lumaSelectCustomInstrumentDef,
                    object: nil,
                    userInfo: ["defID": defID.uuidString]
                )
            }
        }
        header.append(child: editButton)
        return header
    }

    private func mutate(_ body: (inout CustomInstrumentConfig) -> Void) {
        guard var cfg = try? CustomInstrumentConfig.decode(from: instrument.configJSON) else { return }
        body(&cfg)
        apply(configJSON: cfg.encode())
    }

    private func apply(configJSON: Data) {
        instrument.configJSON = configJSON
        guard let engine else { return }
        let snapshot = instrument
        Task { @MainActor in
            await engine.applyInstrumentConfig(snapshot, configJSON: configJSON)
        }
    }
}
