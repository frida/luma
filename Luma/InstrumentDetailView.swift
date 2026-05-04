import LumaCore
import SwiftUI

struct InstrumentDetailView: View {
    let instanceID: UUID
    let sessionID: UUID
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    private var instance: LumaCore.InstrumentInstance? {
        try? workspace.store.fetchInstrument(id: instanceID)
    }

    private var session: LumaCore.ProcessSession? {
        try? workspace.store.fetchSession(id: sessionID)
    }

    private var configBinding: Binding<Data> {
        Binding(
            get: { instance?.configJSON ?? Data() },
            set: { newValue in
                guard let snapshot = instance else { return }
                Task { @MainActor in
                    await workspace.engine.applyInstrumentConfig(snapshot, configJSON: newValue)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let inst = instance, let ui = InstrumentUIRegistry.shared.ui(for: inst) {
                    ui.makeConfigEditor(configJSON: configBinding, workspace: workspace, selection: $selection)
                        .environment(\.instrumentSession, session)
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
