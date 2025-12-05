import Combine
import Frida
import SwiftUI

struct InstrumentDetailView: View {
    @Bindable var instance: InstrumentInstance
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    let template: InstrumentTemplate?

    private var runtime: InstrumentRuntime? {
        guard let node = self.node else { return nil }
        return node.instruments.first { $0.instance == instance }
    }

    private var node: ProcessNode? {
        let processSession = instance.session
        return workspace.processNodes.first { $0.sessionRecord == processSession }
    }

    @State private var configJSON: Data

    init(instance: InstrumentInstance, workspace: Workspace, selection: Binding<SidebarItemID?>) {
        self._instance = Bindable(instance)
        self.workspace = workspace
        self.template = workspace.template(for: instance)
        self._selection = selection
        _configJSON = State(initialValue: instance.configJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if node == nil, let session = instance.session {
                SessionDetachedBanner(session: session, workspace: workspace)
            }

            VStack(alignment: .leading, spacing: 0) {
                if let template {
                    template.makeConfigEditor($configJSON, $selection)
                        .environment(\.instrumentSession, instance.session)
                        .onChange(of: configJSON) { _, newValue in
                            Task { @MainActor in
                                if let runtime {
                                    await runtime.applyConfigJSON(newValue)
                                } else {
                                    instance.configJSON = newValue
                                }
                            }
                        }
                } else {
                    Text("This instrument doesn’t expose any configurable settings yet.")
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
