import SwiftUI
import LumaCore

struct HookPackConfigView: View {
    let pack: HookPack
    @Binding var config: HookPackConfig
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                InstrumentIconView(icon: pack.resolvedIcon, pointSize: 14)
                Text(pack.manifest.name).font(.headline)
                Spacer()
            }

            GroupBox("Features") {
                Group {
                    if pack.manifest.features.isEmpty {
                        Text("This hook-pack does not declare any features.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(pack.manifest.features) { feature in
                                InstrumentFeatureRow(
                                    feature: feature,
                                    state: stateBinding(for: feature)
                                )
                            }
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            InstrumentWidgetsRenderer(widgets: pack.manifest.widgets, workspace: workspace)

            Spacer()
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
