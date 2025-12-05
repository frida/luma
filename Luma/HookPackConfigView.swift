import SwiftUI

struct HookPackConfigView: View {
    let manifest: HookPackManifest
    @Binding var config: HookPackConfig

    var body: some View {
        HStack(spacing: 0) {
            GroupBox("Features") {
                if manifest.features.isEmpty {
                    Text("This hook-pack does not define any configurable features.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(manifest.features) { feature in
                            Toggle(isOn: binding(for: feature)) {
                                Text(feature.name)
                            }
                        }
                    }
                }
            }

            Spacer()
        }
    }

    private func binding(for feature: HookPackManifest.Feature) -> Binding<Bool> {
        Binding(
            get: {
                config.features[feature.id] != nil
            },
            set: { newValue in
                if newValue {
                    config.features[feature.id] = FeatureConfig()
                } else {
                    config.features.removeValue(forKey: feature.id)
                }
            }
        )
    }
}
