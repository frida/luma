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
        VStack(alignment: .leading, spacing: 12) {
            header

            GroupBox("Features") {
                Group {
                    if let def, !def.features.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(def.features) { feature in
                                InstrumentFeatureRow(
                                    feature: feature,
                                    state: stateBinding(for: feature)
                                )
                            }
                        }
                    } else {
                        Text("This custom instrument does not declare any features.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let def {
                InstrumentWidgetsRenderer(widgets: def.widgets, engine: engine)
            }

            Spacer()
        }
        .padding(8)
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

    private func stateBinding(for feature: CustomInstrumentDef.Feature) -> Binding<FeatureState> {
        Binding(
            get: {
                config.features[feature.id]
                    ?? FeatureState(enabled: feature.enabledByDefault, value: feature.schema.defaultValue)
            },
            set: { newValue in
                var updated = config
                updated.features[feature.id] = newValue
                config = updated
            }
        )
    }
}
