import LumaCore
import SwiftUI

struct AddInstrumentSheet: View {
    let session: LumaCore.ProcessSession
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?
    let onInstrumentAdded: ((LumaCore.InstrumentInstance) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var selectedDescriptorID: InstrumentDescriptor.ID?
    @State private var initialConfigJSON = Data()
    @State private var isShowingCodeShareBrowser = false

    var descriptors: [InstrumentDescriptor] {
        workspace.engine.descriptors
    }

    private var selectedDescriptor: InstrumentDescriptor? {
        guard let id = selectedDescriptorID else { return nil }
        return descriptors.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            NavigationSplitView {
                List(selection: $selectedDescriptorID) {
                    ForEach(descriptors) { descriptor in
                        HStack {
                            InstrumentIconView(icon: descriptor.icon, pointSize: 12)
                            Text(descriptor.displayName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tag(descriptor.id)
                    }
                }
                .frame(minWidth: 240, idealWidth: 260)
                .listStyle(.sidebar)
                .navigationTitle("Add Instrument")
            } detail: {
                Group {
                    if let descriptor = selectedDescriptor,
                        let ui = InstrumentUIRegistry.shared.ui(for: descriptor.id)
                    {
                        ui.makeConfigEditor(
                            configJSON: $initialConfigJSON,
                            workspace: workspace,
                            selection: $selection
                        )
                        .environment(\.instrumentSession, session)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                    } else {
                        Text("Select an instrument to configure.")
                            .foregroundStyle(.secondary)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .center
                            )
                    }
                }
                .padding()
            }
            .onChange(of: selectedDescriptorID) { _, newID in
                guard
                    let id = newID,
                    let desc = descriptors.first(where: { $0.id == id })
                else { return }

                initialConfigJSON = desc.makeInitialConfigJSON()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { @MainActor in
                            if let descriptor = selectedDescriptor {
                                let newInstrument = await workspace.engine.addInstrument(
                                    kind: descriptor.kind,
                                    sourceIdentifier: descriptor.sourceIdentifier,
                                    configJSON: initialConfigJSON,
                                    sessionID: session.id
                                )
                                onInstrumentAdded?(newInstrument)
                            }
                            dismiss()
                        }
                    }
                    .disabled(selectedDescriptor == nil)
                }
                ToolbarItem(placement: .automatic) {
                    Button("Browse CodeShare…") {
                        isShowingCodeShareBrowser = true
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 420)
        .sheet(isPresented: $isShowingCodeShareBrowser) {
            CodeShareBrowserView(
                session: session,
                workspace: workspace,
                onInstrumentAdded: { instance in
                    onInstrumentAdded?(instance)
                    dismiss()
                }
            )
        }
    }
}
