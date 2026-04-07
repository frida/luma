import Foundation
import Gtk
import LumaCore

@MainActor
final class InstrumentConfigEditor {
    let widget: Box

    private weak var engine: Engine?
    private var instrument: LumaCore.InstrumentInstance

    init(engine: Engine, instrument: LumaCore.InstrumentInstance) {
        self.engine = engine
        self.instrument = instrument

        widget = Box(orientation: .vertical, spacing: 8)
        widget.hexpand = true
        widget.marginStart = 24
        widget.marginEnd = 24
        widget.marginTop = 4
        widget.marginBottom = 12

        rebuild()
    }

    private func rebuild() {
        var child = widget.firstChild
        while let current = child {
            child = current.nextSibling
            widget.remove(child: current)
        }

        switch instrument.kind {
        case .tracer:
            buildTracer()
        case .hookPack:
            buildHookPack()
        case .codeShare:
            buildCodeShare()
        }
    }

    // MARK: - Tracer

    private func buildTracer() {
        guard let config = try? TracerConfig.decode(from: instrument.configJSON) else {
            widget.append(child: errorLabel("Failed to decode tracer config"))
            return
        }

        if config.hooks.isEmpty {
            widget.append(child: dimLabel("No hooks defined."))
            return
        }

        for hook in config.hooks {
            let row = Box(orientation: .horizontal, spacing: 8)
            row.hexpand = true

            let name = Label(str: hook.displayName.isEmpty ? "(unnamed)" : hook.displayName)
            name.halign = .start
            name.hexpand = true
            row.append(child: name)

            let toggle = Switch()
            toggle.active = hook.isEnabled
            toggle.valign = .center
            let hookID = hook.id
            toggle.onStateSet { [weak self] _, state in
                MainActor.assumeIsolated {
                    self?.mutateTracer { cfg in
                        if let idx = cfg.hooks.firstIndex(where: { $0.id == hookID }) {
                            cfg.hooks[idx].isEnabled = state
                        }
                    }
                }
                return false
            }
            row.append(child: toggle)

            let delete = Button(label: "Remove")
            delete.add(cssClass: "destructive-action")
            delete.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.mutateTracer { cfg in
                        cfg.hooks.removeAll { $0.id == hookID }
                    }
                }
            }
            row.append(child: delete)

            widget.append(child: row)
        }

    }

    private func mutateTracer(_ body: (inout TracerConfig) -> Void) {
        guard var config = try? TracerConfig.decode(from: instrument.configJSON) else { return }
        body(&config)
        apply(configJSON: config.encode())
    }

    // MARK: - Hook pack

    private func buildHookPack() {
        guard
            let config = try? JSONDecoder().decode(HookPackConfig.self, from: instrument.configJSON),
            let pack = engine?.hookPacks.pack(withId: instrument.sourceIdentifier)
        else {
            widget.append(child: errorLabel("Failed to load hook pack"))
            return
        }

        if pack.manifest.features.isEmpty {
            widget.append(child: dimLabel("This hook pack has no configurable features."))
            return
        }

        for feature in pack.manifest.features {
            let row = Box(orientation: .horizontal, spacing: 8)
            row.hexpand = true

            let name = Label(str: feature.name)
            name.halign = .start
            name.hexpand = true
            row.append(child: name)

            let toggle = Switch()
            toggle.active = config.features[feature.id] != nil
            toggle.valign = .center
            let featureID = feature.id
            toggle.onStateSet { [weak self] _, state in
                MainActor.assumeIsolated {
                    self?.mutateHookPack { cfg in
                        if state {
                            if cfg.features[featureID] == nil {
                                cfg.features[featureID] = FeatureConfig()
                            }
                        } else {
                            cfg.features.removeValue(forKey: featureID)
                        }
                    }
                }
                return false
            }
            row.append(child: toggle)

            widget.append(child: row)
        }
    }

    private func mutateHookPack(_ body: (inout HookPackConfig) -> Void) {
        guard var config = try? JSONDecoder().decode(HookPackConfig.self, from: instrument.configJSON) else { return }
        body(&config)
        guard let data = try? JSONEncoder().encode(config) else { return }
        apply(configJSON: data)
    }

    // MARK: - CodeShare

    private func buildCodeShare() {
        let text = String(data: instrument.configJSON, encoding: .utf8) ?? "(non-UTF8)"
        let label = Label(str: text)
        label.halign = .start
        label.add(cssClass: "monospace")
        label.wrap = true
        label.selectable = true
        widget.append(child: label)
    }

    // MARK: - Apply

    private func apply(configJSON: Data) {
        guard let engine else { return }
        let snapshot = instrument
        Task { @MainActor in
            await engine.applyInstrumentConfig(snapshot, configJSON: configJSON)
            if let updated = try? engine.store.fetchInstruments(sessionID: snapshot.sessionID)
                .first(where: { $0.id == snapshot.id })
            {
                self.instrument = updated
            } else {
                self.instrument.configJSON = configJSON
            }
            self.rebuild()
        }
    }

    private func dimLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "dim-label")
        label.halign = .start
        return label
    }

    private func errorLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "error")
        label.halign = .start
        return label
    }
}
