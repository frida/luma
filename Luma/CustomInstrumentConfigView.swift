import LumaCore
import SwiftUI

struct CustomInstrumentConfigView: View {
    let defID: UUID
    @Binding var config: CustomInstrumentConfig
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @Environment(\.instrumentInstance) private var instrumentInstance

    private var def: CustomInstrumentDef? {
        engine.customInstruments.def(withId: defID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if let def, !def.settings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings")
                            .font(.subheadline)
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(def.settings) { setting in
                                    InstrumentSettingRow(
                                        setting: setting,
                                        state: stateBinding(for: setting)
                                    )
                                }
                            }
                            .padding(.leading, 12)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let def {
                    InstrumentWidgetsRenderer(
                        widgets: def.widgets,
                        engine: engine,
                        selection: $selection
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            StoreUpdateBanner(defID: defID, engine: engine)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let def {
                InstrumentIconView(icon: def.icon, pointSize: 14)
                Text(def.name).font(.headline)
            } else {
                Text("Custom Instrument").font(.headline)
            }
            Spacer()
            if instrumentInstance != nil {
                Button("Edit Source\u{2026}") {
                    if let entrypoint = def?.entrypoint {
                        selection = .customInstrumentFile(defID, entrypoint)
                    } else {
                        selection = .customInstrumentDef(defID)
                    }
                }
                .accessibilityIdentifier("customInstrument.editSource")
            }
        }
    }

    private func stateBinding(for setting: CustomInstrumentDef.Setting) -> Binding<SettingState> {
        Binding(
            get: {
                config.settings[setting.id]
                    ?? SettingState(enabled: setting.enabledByDefault, value: setting.schema.defaultValue)
            },
            set: { newValue in
                var updated = config
                updated.settings[setting.id] = newValue
                config = updated
            }
        )
    }
}
