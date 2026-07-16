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
    private var featureEditors: [FeatureValueEditor] = []
    private var widgetRenderer: InstrumentWidgetsRenderer?

    init(engine: Engine, instrument: LumaCore.InstrumentInstance) {
        self.engine = engine
        self.instrument = instrument

        let outer = Box(orientation: .vertical, spacing: 8)
        outer.hexpand = true
        outer.marginStart = 24
        outer.marginEnd = 24
        outer.marginTop = 8
        outer.marginBottom = 12
        self.outer = outer

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroll.set(child: outer)
        widget = scroll

        rebuild()
    }

    func update(_ instrument: LumaCore.InstrumentInstance) {
        guard instrument.configJSON != self.instrument.configJSON else { return }
        self.instrument = instrument
        rebuild()
        applySessionState()
    }

    func applySessionState() {
        guard let engine else { return }
        widgetRenderer?.setLive(isLive(engine: engine))
    }

    private func isLive(engine: Engine) -> Bool {
        let sessionID = instrument.sessionID
        return engine.isHostingNode(sessionID) || engine.isHostedRemotelyLive(sessionID)
    }

    private func rebuild() {
        while let child = outer.firstChild {
            outer.remove(child: child)
        }
        widgetRenderer = nil
        featureEditors.removeAll()

        guard let engine,
            let config = try? CustomInstrumentConfig.decode(from: instrument.configJSON),
            let def = engine.customInstruments.def(withId: config.defID)
        else {
            outer.append(child: InstrumentUIHelpers.errorLabel("Custom instrument not found"))
            return
        }

        let title = Label(str: def.name)
        title.add(cssClass: "title-3")
        title.halign = .start
        outer.append(child: title)

        let editButton = Button(label: "Edit Source\u{2026}")
        editButton.halign = .start
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
        outer.append(child: editButton)

        let header = Label(str: "Features")
        header.halign = .start
        header.add(cssClass: "heading")
        outer.append(child: header)

        if def.features.isEmpty {
            outer.append(child: InstrumentUIHelpers.dimLabel("This custom instrument does not declare any features."))
        } else {
            for feature in def.features {
                outer.append(child: makeFeatureRow(feature: feature, config: config))
            }
        }

        widgetRenderer = InstrumentUIHelpers.appendWidgets(
            into: outer,
            widgets: def.widgets,
            engine: engine,
            instance: instrument
        )
        widgetRenderer?.setLive(isLive(engine: engine))
    }

    private func makeFeatureRow(feature: CustomInstrumentDef.Feature, config: CustomInstrumentConfig) -> Box {
        let row = Box(orientation: .vertical, spacing: 4)
        row.hexpand = true

        let initialEnabled = config.features[feature.id]?.enabled ?? feature.enabledByDefault
        let initialValue = config.features[feature.id]?.value ?? feature.schema.defaultValue
        let fid = feature.id

        if feature.optional {
            let check = CheckButton(label: feature.name)
            check.active = initialEnabled
            check.onToggled { [weak self] ref in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let enabled = ref.active
                    self.mutate { cfg in
                        let existingValue = cfg.features[fid]?.value ?? feature.schema.defaultValue
                        cfg.features[fid] = FeatureState(enabled: enabled, value: existingValue)
                    }
                }
            }
            row.append(child: check)

            if case .boolean = feature.schema {
                return row
            }

            let editor = FeatureValueEditor(schema: feature.schema, value: initialValue) { [weak self] newValue in
                self?.mutate { cfg in
                    let existingEnabled = cfg.features[fid]?.enabled ?? feature.enabledByDefault
                    cfg.features[fid] = FeatureState(enabled: existingEnabled, value: newValue)
                }
            }
            featureEditors.append(editor)
            editor.widget.marginStart = 24
            row.append(child: editor.widget)
            return row
        }

        if case .boolean = feature.schema {
            let check = CheckButton(label: feature.name)
            if case .boolean(let b) = initialValue { check.active = b }
            check.onToggled { [weak self] ref in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let newValue: FeatureValue = .boolean(ref.active)
                    self.mutate { cfg in
                        let existingEnabled = cfg.features[fid]?.enabled ?? feature.enabledByDefault
                        cfg.features[fid] = FeatureState(enabled: existingEnabled, value: newValue)
                    }
                }
            }
            row.append(child: check)
            return row
        }

        let nameLabel = Label(str: feature.name)
        nameLabel.halign = .start
        row.append(child: nameLabel)
        let editor = FeatureValueEditor(schema: feature.schema, value: initialValue) { [weak self] newValue in
            self?.mutate { cfg in
                let existingEnabled = cfg.features[fid]?.enabled ?? feature.enabledByDefault
                cfg.features[fid] = FeatureState(enabled: existingEnabled, value: newValue)
            }
        }
        featureEditors.append(editor)
        row.append(child: editor.widget)
        return row
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
