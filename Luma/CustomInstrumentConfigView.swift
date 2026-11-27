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
        Group {
            if let def, let instrumentInstance {
                InstrumentWidgetPage(
                    widgets: def.widgets,
                    layout: def.pageLayout,
                    gate: InstrumentPageGate(instanceID: instrumentInstance.id, icon: def.icon, name: def.name),
                    engine: engine,
                    selection: $selection
                ) {
                    header
                }
            } else if let def {
                setup(def)
            } else {
                header
                    .padding(8)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
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
                if !def.settings.isEmpty {
                    InstrumentSettingsPill { settingsForm(def.settings) }
                }
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

    private func setup(_ def: CustomInstrumentDef) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                InstrumentIconView(icon: def.icon, pointSize: 32)
                Text(def.name)
                    .font(.headline)
                if def.settings.isEmpty {
                    Text("This instrument has no settings.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Settings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    settingsForm(def.settings)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func settingsForm(_ settings: [CustomInstrumentDef.Setting]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(settings) { setting in
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

private struct InstrumentSettingsPill<Form: View>: View {
    @ViewBuilder let form: () -> Form

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "switch.2").imageScale(.small)
                Text("Settings")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .foregroundStyle(Color.secondary)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Settings")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("customInstrument.settings")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollView {
                form()
                    .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 400)
            .frame(maxHeight: 500)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
