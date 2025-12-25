import SwiftUI

struct AddInstrumentSheet: View {
    let session: ProcessSession
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?
    let onInstrumentAdded: ((InstrumentInstance) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: InstrumentTemplate.ID?
    @State private var initialConfigJSON = Data()
    @State private var isShowingCodeShareBrowser = false

    var templates: [InstrumentTemplate] {
        workspace.allInstrumentTemplates
    }

    private var selectedTemplate: InstrumentTemplate? {
        guard let id = selectedTemplateID else { return nil }
        return templates.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            NavigationSplitView {
                List(selection: $selectedTemplateID) {
                    ForEach(templates) { template in
                        HStack {
                            InstrumentIconView(icon: template.icon, pointSize: 12)
                            Text(template.displayName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tag(template.id)
                    }
                }
                .frame(minWidth: 240, idealWidth: 260)
                .listStyle(.sidebar)
                .navigationTitle("Add Instrument")
            } detail: {
                Group {
                    if let template = selectedTemplate {
                        template
                            .makeConfigEditor($initialConfigJSON, $selection)
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
            .onChange(of: selectedTemplateID) { _, newID in
                guard
                    let id = newID,
                    let tpl = templates.first(where: { $0.id == id })
                else { return }

                initialConfigJSON = tpl.makeInitialConfigJSON()
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
                            if let template = selectedTemplate {
                                let newInstrument = await workspace.addInstrument(
                                    template: template,
                                    initialConfigJSON: initialConfigJSON,
                                    for: session
                                )
                                onInstrumentAdded?(newInstrument)
                            }
                            dismiss()
                        }
                    }
                    .disabled(selectedTemplate == nil)
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
