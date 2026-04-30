import LumaCore
import SwiftUI

struct AddInstrumentSheet: View {
    let session: LumaCore.ProcessSession
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?
    let onInstrumentAdded: ((LumaCore.InstrumentInstance) -> Void)?
    let onBrowseCodeShare: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var commitCoordinator = InstrumentConfigCommitCoordinator()

    @State private var selectedDescriptorID: InstrumentDescriptor.ID?
    @State private var initialConfigJSON = Data()
    @State private var compactPath: [InstrumentDescriptor.ID] = []

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    var descriptors: [InstrumentDescriptor] {
        workspace.engine.descriptors
    }

    private var selectedDescriptor: InstrumentDescriptor? {
        guard let id = selectedDescriptorID else { return nil }
        return descriptors.first { $0.id == id }
    }

    var body: some View {
        Group {
            if isCompactWidth {
                compactBody
            } else {
                regularBody
            }
        }
        .frame(minWidth: isCompactWidth ? 0 : 800, minHeight: isCompactWidth ? 0 : 420)
    }

    private var compactBody: some View {
        NavigationStack(path: $compactPath) {
            List(descriptors) { descriptor in
                NavigationLink(value: descriptor.id) {
                    descriptorRow(descriptor)
                }
            }
            .navigationTitle("Add Instrument")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: InstrumentDescriptor.ID.self) { id in
                if let descriptor = descriptors.first(where: { $0.id == id }) {
                    detailContent(descriptor: descriptor)
                        .navigationTitle(descriptor.displayName)
                        #if canImport(UIKit)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar { sharedToolbar }
                        .onAppear {
                            if selectedDescriptorID != descriptor.id {
                                selectedDescriptorID = descriptor.id
                                initialConfigJSON = descriptor.makeInitialConfigJSON()
                            }
                        }
                }
            }
        }
    }

    private var regularBody: some View {
        NavigationSplitView {
            List(selection: $selectedDescriptorID) {
                ForEach(descriptors) { descriptor in
                    descriptorRow(descriptor).tag(descriptor.id)
                }
            }
            .frame(minWidth: 240, idealWidth: 260)
            .listStyle(.sidebar)
            .navigationTitle("Add Instrument")
        } detail: {
            Group {
                if let descriptor = selectedDescriptor {
                    detailContent(descriptor: descriptor)
                } else {
                    Text("Select an instrument to configure.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .toolbar { sharedToolbar }
        }
        .onChange(of: selectedDescriptorID) { _, newID in
            guard
                let id = newID,
                let desc = descriptors.first(where: { $0.id == id })
            else { return }

            initialConfigJSON = desc.makeInitialConfigJSON()
        }
    }

    @ViewBuilder
    private func detailContent(descriptor: InstrumentDescriptor) -> some View {
        if let ui = InstrumentUIRegistry.shared.ui(for: descriptor.id) {
            ui.makeConfigEditor(
                configJSON: $initialConfigJSON,
                workspace: workspace,
                selection: $selection
            )
            .environment(\.instrumentSession, session)
            .environment(\.instrumentConfigCommitCoordinator, commitCoordinator)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        } else {
            Text("Configuration unavailable.")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    private func descriptorRow(_ descriptor: InstrumentDescriptor) -> some View {
        HStack {
            InstrumentIconView(icon: descriptor.icon, pointSize: 12)
            Text(descriptor.displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ToolbarContentBuilder
    private var sharedToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                dismiss()
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Add") {
                commitCoordinator.flushPendingEdits()
                Task { @MainActor in
                    if let descriptor = selectedDescriptor {
                        let newInstrument = await workspace.engine.addInstrument(
                            kind: descriptor.kind,
                            sourceIdentifier: descriptor.sourceIdentifier,
                            configJSON: initialConfigJSON,
                            sessionID: session.id
                        )
                        if let newInstrument {
                            onInstrumentAdded?(newInstrument)
                        }
                    }
                    dismiss()
                }
            }
            .disabled(selectedDescriptor == nil)
        }
        ToolbarItem(placement: .automatic) {
            Button("Browse CodeShare…") {
                onBrowseCodeShare()
                dismiss()
            }
        }
    }
}

@MainActor
final class InstrumentConfigCommitCoordinator {
    private var handlers: [UUID: () -> Void] = [:]

    func register(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UUID) {
        handlers.removeValue(forKey: id)
    }

    func flushPendingEdits() {
        for handler in handlers.values { handler() }
    }
}

extension EnvironmentValues {
    var instrumentConfigCommitCoordinator: InstrumentConfigCommitCoordinator? {
        get { self[InstrumentConfigCommitCoordinatorKey.self] }
        set { self[InstrumentConfigCommitCoordinatorKey.self] = newValue }
    }
}

private struct InstrumentConfigCommitCoordinatorKey: EnvironmentKey {
    static let defaultValue: InstrumentConfigCommitCoordinator? = nil
}
