import LumaCore
import SwiftUI

struct InstrumentSettingRow: View {
    let setting: CustomInstrumentDef.Setting
    @Binding var state: SettingState

    var body: some View {
        if setting.optional {
            optionalRow
        } else {
            requiredRow
        }
    }

    @ViewBuilder
    private var optionalRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(setting.name, isOn: enabledBinding)
                .platformCheckboxToggleStyle()
            if case .boolean = setting.schema {
                EmptyView()
            } else {
                SettingValueEditor(schema: setting.schema, value: valueBinding)
                    .disabled(!state.enabled)
                    .opacity(state.enabled ? 1 : 0.4)
                    .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private var requiredRow: some View {
        if case .boolean = setting.schema {
            Toggle(setting.name, isOn: requiredBoolBinding)
                .platformCheckboxToggleStyle()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(setting.name).font(.subheadline)
                SettingValueEditor(schema: setting.schema, value: valueBinding)
                    .padding(.leading, 20)
            }
        }
    }

    private var requiredBoolBinding: Binding<Bool> {
        Binding(
            get: {
                if case .boolean(let b) = state.value { return b }
                if case .boolean(let b) = setting.schema.defaultValue { return b }
                return false
            },
            set: { newValue in
                state = SettingState(enabled: state.enabled, value: .boolean(newValue))
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.enabled },
            set: { state = SettingState(enabled: $0, value: state.value) }
        )
    }

    private var valueBinding: Binding<SettingValue> {
        Binding(
            get: { state.value },
            set: { state = SettingState(enabled: state.enabled, value: $0) }
        )
    }
}
