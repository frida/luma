import LumaCore
import SwiftUI

struct CustomInstrumentConfigView: View {
    let defID: UUID
    @Binding var config: CustomInstrumentConfig
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    private var def: CustomInstrumentDef? {
        workspace.engine.customInstruments.def(withId: defID)
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
                InstrumentWidgetsRenderer(widgets: def.widgets, workspace: workspace)
            }

            Spacer()
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
            Button("Edit Source\u{2026}") {
                selection = .customInstrumentDef(defID)
            }
            .accessibilityIdentifier("customInstrument.editSource")
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
