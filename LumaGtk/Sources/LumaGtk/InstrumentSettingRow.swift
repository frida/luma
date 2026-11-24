import Gtk
import LumaCore

@MainActor
final class InstrumentSettingRow {
    let widget = Box(orientation: .vertical, spacing: 4)
    private var valueEditor: FeatureValueEditor?

    static func makeGroup(
        features: [CustomInstrumentDef.Feature],
        config: CustomInstrumentConfig,
        keeping rows: inout [InstrumentSettingRow],
        onChange: @escaping (_ id: String, _ state: FeatureState) -> Void
    ) -> Box {
        let group = Box(orientation: .vertical, spacing: 4)
        let heading = Label(str: "Settings")
        heading.halign = .start
        heading.add(cssClass: "luma-widget-title")
        group.append(child: heading)
        let card = Box(orientation: .vertical, spacing: 0)
        card.add(cssClass: "luma-widget-box")
        let column = Box(orientation: .vertical, spacing: 12)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12
        card.append(child: column)
        for feature in features {
            let state = config.features[feature.id] ?? FeatureState(enabled: feature.enabledByDefault, value: feature.schema.defaultValue)
            let row = InstrumentSettingRow(feature: feature, state: state) { onChange(feature.id, $0) }
            rows.append(row)
            column.append(child: row.widget)
        }
        group.append(child: card)
        return group
    }

    init(feature: CustomInstrumentDef.Feature, state: FeatureState, onChange: @escaping (FeatureState) -> Void) {
        var current = state
        let isBoolean = if case .boolean = feature.schema { true } else { false }
        widget.hexpand = true

        if feature.optional || isBoolean {
            let check = CheckButton(label: feature.name)
            check.active = feature.optional ? state.enabled : state.value == .boolean(true)
            widget.append(child: check)
            check.onToggled { [weak self] ref in
                MainActor.assumeIsolated {
                    if feature.optional {
                        current.enabled = ref.active
                        self?.valueEditor?.widget.sensitive = ref.active
                    } else {
                        current.value = .boolean(ref.active)
                    }
                    onChange(current)
                }
            }
            if isBoolean { return }
        } else {
            let nameLabel = Label(str: feature.name)
            nameLabel.halign = .start
            widget.append(child: nameLabel)
        }

        let editor = FeatureValueEditor(schema: feature.schema, value: state.value) { newValue in
            current.value = newValue
            onChange(current)
        }
        editor.widget.marginStart = 20
        editor.widget.sensitive = !feature.optional || state.enabled
        widget.append(child: editor.widget)
        valueEditor = editor
    }
}
