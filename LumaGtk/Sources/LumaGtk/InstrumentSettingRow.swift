import Gtk
import LumaCore

@MainActor
final class InstrumentSettingRow {
    let widget = Box(orientation: .vertical, spacing: 4)
    private var valueEditor: SettingValueEditor?

    static func makeGroup(
        settings: [CustomInstrumentDef.Setting],
        config: CustomInstrumentConfig,
        keeping rows: inout [InstrumentSettingRow],
        onChange: @escaping (_ id: String, _ state: SettingState) -> Void
    ) -> Box {
        let group = Box(orientation: .vertical, spacing: 4)
        let heading = Label(str: "Settings")
        heading.halign = .start
        heading.add(cssClass: "luma-widget-title")
        group.append(child: heading)
        group.append(child: makeCard(settings: settings, config: config, keeping: &rows, onChange: onChange))
        return group
    }

    static func makeCard(
        settings: [CustomInstrumentDef.Setting],
        config: CustomInstrumentConfig,
        keeping rows: inout [InstrumentSettingRow],
        onChange: @escaping (_ id: String, _ state: SettingState) -> Void
    ) -> Box {
        let card = Box(orientation: .vertical, spacing: 0)
        card.add(cssClass: "luma-widget-box")
        let column = Box(orientation: .vertical, spacing: 12)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12
        card.append(child: column)
        for setting in settings {
            let state = config.settings[setting.id] ?? SettingState(enabled: setting.enabledByDefault, value: setting.schema.defaultValue)
            let row = InstrumentSettingRow(setting: setting, state: state) { onChange(setting.id, $0) }
            rows.append(row)
            column.append(child: row.widget)
        }
        return card
    }

    init(setting: CustomInstrumentDef.Setting, state: SettingState, onChange: @escaping (SettingState) -> Void) {
        var current = state
        let isBoolean = if case .boolean = setting.schema { true } else { false }
        widget.hexpand = true

        if setting.optional || isBoolean {
            let check = CheckButton(label: setting.name)
            check.active = setting.optional ? state.enabled : state.value == .boolean(true)
            widget.append(child: check)
            check.onToggled { [weak self] ref in
                MainActor.assumeIsolated {
                    if setting.optional {
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
            let nameLabel = Label(str: setting.name)
            nameLabel.halign = .start
            widget.append(child: nameLabel)
        }

        let editor = SettingValueEditor(schema: setting.schema, value: state.value) { newValue in
            current.value = newValue
            onChange(current)
        }
        editor.widget.marginStart = 20
        editor.widget.sensitive = !setting.optional || state.enabled
        widget.append(child: editor.widget)
        valueEditor = editor
    }
}
