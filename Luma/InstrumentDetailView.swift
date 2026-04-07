import LumaCore
import SwiftUI

struct InstrumentDetailView: View {
    let instance: LumaCore.InstrumentInstance
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    private var session: LumaCore.ProcessSession? {
        try? workspace.store.fetchSession(id: instance.sessionID)
    }

    private var node: LumaCore.ProcessNode? {
        workspace.engine.node(forSessionID: instance.sessionID)
    }

    @State private var configJSON: Data

    init(instance: LumaCore.InstrumentInstance, workspace: Workspace, selection: Binding<SidebarItemID?>) {
        self.instance = instance
        self.workspace = workspace
        self._selection = selection
        _configJSON = State(initialValue: instance.configJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if node == nil, let session {
                SessionDetachedBanner(session: session, workspace: workspace)
            }

            VStack(alignment: .leading, spacing: 0) {
                if let ui = InstrumentUIRegistry.shared.ui(for: instance) {
                    ui.makeConfigEditor(configJSON: $configJSON, workspace: workspace, selection: $selection)
                        .environment(\.instrumentSession, session)
                        .onChange(of: configJSON) { _, newValue in
                            Task { @MainActor in
                                await workspace.engine.applyInstrumentConfig(instance, configJSON: newValue)
                            }
                        }
                } else {
                    Text("This instrument doesn't expose any configurable settings yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding(.top, 8)
            .padding(.leading, 8)
            .padding(.trailing, 8)
        }
        .frame(minWidth: 360, minHeight: 300)
    }
}
