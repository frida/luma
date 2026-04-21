import SwiftUI
import LumaCore

struct CodeShareUI: InstrumentUI {
    func makeConfigEditor(
        configJSON: Binding<Data>,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        let cfgBinding = Binding<CodeShareConfig>(
            get: {
                (try? JSONDecoder().decode(CodeShareConfig.self, from: configJSON.wrappedValue))
                    ?? CodeShareConfig(
                        name: "",
                        description: "",
                        source: "",
                        exports: [],
                        project: nil,
                        lastSyncedHash: nil,
                        lastReviewedHash: nil,
                        fridaVersion: "",
                        allowRemoteUpdates: false
                    )
            },
            set: { newValue in
                if let data = try? JSONEncoder().encode(newValue) {
                    configJSON.wrappedValue = data
                }
            }
        )

        return AnyView(
            CodeShareConfigView(
                config: cfgBinding,
                workspace: workspace
            )
        )
    }

    func renderEvent(
        _ event: RuntimeEvent,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        if case .jsValue(let v) = event.payload {
            return AnyView(
                JSInspectValueView(
                    value: v,
                    sessionID: event.sessionID ?? UUID(),
                    workspace: workspace,
                    selection: selection
                )
                .font(.system(.footnote, design: .monospaced))
            )
        }
        return AnyView(Text(String(describing: event.payload)))
    }
}
