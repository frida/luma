import SwiftUI
import LumaCore

struct HookPackUI: InstrumentUI {
    let manifest: HookPackManifest

    func makeConfigEditor(
        configJSON: Binding<Data>,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        let cfgBinding = Binding<HookPackConfig>(
            get: {
                (try? JSONDecoder().decode(HookPackConfig.self, from: configJSON.wrappedValue))
                    ?? HookPackConfig(packId: manifest.id, features: [:])
            },
            set: { newValue in
                if let data = try? JSONEncoder().encode(newValue) {
                    configJSON.wrappedValue = data
                }
            }
        )

        return AnyView(
            HookPackConfigView(
                manifest: manifest,
                config: cfgBinding
            )
        )
    }

    func renderEvent(
        _ event: RuntimeEvent,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        guard case .jsValue(let v) = event.payload else {
            return AnyView(Text(String(describing: event.payload)))
        }

        return AnyView(
            JSInspectValueView(
                value: v,
                sessionID: event.processNode.sessionRecord.id,
                workspace: workspace,
                selection: selection
            )
        )
    }
}
