import Frida
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct AddInstrumentSheet: View {
    let session: LumaCore.ProcessSession
    let engine: Engine
    @Binding var selection: SidebarItemID?
    let onInstrumentAdded: ((LumaCore.InstrumentInstance) -> Void)?
    let onBrowseCodeShare: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var commitCoordinator = InstrumentConfigCommitCoordinator()
    @State private var systemParams: SystemParameters?

    @State private var selectedDescriptorID: InstrumentDescriptor.ID?
    @State private var initialConfigJSON = Data()
    @State private var compactPath: [InstrumentDescriptor.ID] = []
    @State private var isShowingImportPicker = false
    @State private var importErrorMessage: String?
    @State private var alreadyAddedDescriptorIDs: Set<InstrumentDescriptor.ID> = []

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    var descriptors: [InstrumentDescriptor] {
        engine.descriptors
    }

    private var builtinDescriptors: [InstrumentDescriptor] {
        descriptors.filter { $0.kind != .custom }
    }

    private var customDescriptors: [InstrumentDescriptor] {
        descriptors.filter { $0.kind == .custom }
    }

    private var libraryFolders: [InstrumentFolder] {
        engine.instrumentFolders.folders.filter { engine.customInstrumentID(linkedToFolderAt: $0.folderURL) == nil }
    }

    private static let newCustomDescriptorID: String = "custom:__new__"
    private static let linkFolderDescriptorID: String = "custom:__link__"

    private static func libraryFolderDescriptorID(_ folder: InstrumentFolder) -> String {
        "folder:\(folder.folderURL.path)"
    }

    private var selectedDescriptor: InstrumentDescriptor? {
        guard let id = selectedDescriptorID else { return nil }
        return descriptors.first { $0.id == id }
    }

    private var selectedLibraryFolder: InstrumentFolder? {
        guard let id = selectedDescriptorID else { return nil }
        return libraryFolders.first { Self.libraryFolderDescriptorID($0) == id }
    }

    private var confirmActionLabel: String {
        selectedDescriptorID == Self.linkFolderDescriptorID ? "Choose Folder\u{2026}" : "Add"
    }

    private var isConfirmActionDisabled: Bool {
        if selectedDescriptorID == Self.newCustomDescriptorID { return false }
        if selectedDescriptorID == Self.linkFolderDescriptorID { return false }
        if selectedLibraryFolder != nil { return false }
        guard let descriptor = selectedDescriptor else { return true }
        if isAlreadyAdded(descriptor) { return true }
        return incompatibilityReason(for: descriptor) != nil
    }

    private func isAlreadyAdded(_ descriptor: InstrumentDescriptor) -> Bool {
        alreadyAddedDescriptorIDs.contains(descriptor.id)
    }

    private func incompatibilityReason(for descriptor: InstrumentDescriptor) -> String? {
        guard let systemParams else { return nil }
        return descriptor.compatibility.incompatibilityReason(for: systemParams)
    }

    private func refreshAlreadyAdded() {
        let existing = (try? engine.store.fetchInstruments(sessionID: session.id)) ?? []
        alreadyAddedDescriptorIDs = Set(existing.map { engine.descriptor(for: $0).id })
    }

    private func resolveSystemParameters() async {
        let devices = await engine.deviceManager.currentDevices()
        guard let device = devices.first(where: { $0.id == session.deviceID }) else { return }
        systemParams = await engine.systemParameters.parameters(for: device)
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
        .fileImporter(
            isPresented: $isShowingImportPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                linkFolder(at: url)
            }
        }
        .alert("Could not link folder", isPresented: importErrorBinding, presenting: importErrorMessage) { _ in
            Button("OK") { importErrorMessage = nil }
        } message: { message in
            Text(message)
        }
        .task(id: session.deviceID) { await resolveSystemParameters() }
        .task(id: session.id) { refreshAlreadyAdded() }
        .task { engine.instrumentFolders.reload() }
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )
    }

    private var compactBody: some View {
        NavigationStack(path: $compactPath) {
            List {
                Section {
                    ForEach(builtinDescriptors) { descriptor in
                        NavigationLink(value: descriptor.id) {
                            descriptorRow(descriptor)
                        }
                    }
                }
                Section("Custom Instruments") {
                    ForEach(customDescriptors) { descriptor in
                        NavigationLink(value: descriptor.id) {
                            descriptorRow(descriptor)
                        }
                    }
                    ForEach(libraryFolders, id: \.folderURL) { folder in
                        Button {
                            linkFolder(at: folder.folderURL)
                        } label: {
                            libraryFolderRow(folder)
                        }
                    }
                    Button {
                        Task { @MainActor in
                            await createNewCustomAndDismiss()
                        }
                    } label: {
                        Label("New Custom Instrument\u{2026}", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("addInstrument.descriptor.\(Self.newCustomDescriptorID)")
                    Button {
                        isShowingImportPicker = true
                    } label: {
                        Label("Link Folder\u{2026}", systemImage: "folder")
                    }
                    .accessibilityIdentifier("addInstrument.descriptor.\(Self.linkFolderDescriptorID)")
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

    @ViewBuilder
    private var descriptorList: some View {
        Section {
            ForEach(builtinDescriptors) { descriptor in
                descriptorRow(descriptor).tag(descriptor.id)
            }
        }
        Section("Custom Instruments") {
            ForEach(customDescriptors) { descriptor in
                descriptorRow(descriptor).tag(descriptor.id)
            }
            ForEach(libraryFolders, id: \.folderURL) { folder in
                libraryFolderRow(folder).tag(Self.libraryFolderDescriptorID(folder))
            }
            HStack {
                Image(systemName: "plus.circle")
                Text("New Custom Instrument\u{2026}")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("addInstrument.descriptor.\(Self.newCustomDescriptorID)")
            .tag(Self.newCustomDescriptorID)
            HStack {
                Image(systemName: "folder")
                Text("Link Folder\u{2026}")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("addInstrument.descriptor.\(Self.linkFolderDescriptorID)")
            .tag(Self.linkFolderDescriptorID)
        }
    }

    private var regularBody: some View {
        NavigationSplitView {
            List(selection: $selectedDescriptorID) {
                descriptorList
            }
            .frame(minWidth: 240, idealWidth: 260)
            .listStyle(.sidebar)
            .navigationTitle("Add Instrument")
        } detail: {
            Group {
                if selectedDescriptorID == Self.newCustomDescriptorID {
                    newCustomDetail
                } else if selectedDescriptorID == Self.linkFolderDescriptorID {
                    linkFolderDetail
                } else if let folder = selectedLibraryFolder {
                    libraryFolderDetail(folder)
                } else if let descriptor = selectedDescriptor {
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
            guard let id = newID else { return }
            guard let desc = descriptors.first(where: { $0.id == id }) else {
                initialConfigJSON = Data()
                return
            }
            initialConfigJSON = desc.makeInitialConfigJSON()
        }
    }

    @MainActor
    private func createNewCustomAndDismiss() async {
        let def = engine.createCustomInstrument()
        let configJSON = CustomInstrumentConfig(
            defID: def.id,
            features: CustomInstrumentLibrary.initialFeatureStates(for: def)
        ).encode()
        let added = await engine.addInstrument(
            kind: .custom,
            sourceIdentifier: def.id.uuidString,
            configJSON: configJSON,
            sessionID: session.id
        )
        if let added {
            onInstrumentAdded?(added)
        }
        selection = .customInstrumentFile(def.id, def.entrypoint)
        dismiss()
    }

    @ViewBuilder
    private var newCustomDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 32))
            Text("Create a Custom Instrument")
                .font(.headline)
            Text("Custom instruments are TypeScript snippets you write inline. They are saved with the project, can be added to multiple sessions, and synchronized when collaboration is enabled. After creating one you can rename it, choose an icon, and define toggleable features from the sidebar.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private var linkFolderDetail: some View {
        folderDetail(
            systemImage: "folder",
            title: "Link Folder",
            explanation: "Pick a folder holding a package.json and a TypeScript entry file. The instrument is brought into the project as a custom instrument that stays linked to the folder: when the files change, Luma offers to reload it."
        )
    }

    private func libraryFolderDetail(_ folder: InstrumentFolder) -> some View {
        folderDetail(
            systemImage: "shippingbox",
            title: folder.name,
            explanation: "This instrument lives in \(folder.folderURL.path). Adding it brings it into the project as a custom instrument that stays linked to the folder: when the files change, Luma offers to reload it."
        )
    }

    private func folderDetail(systemImage: String, title: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
            Text(title)
                .font(.headline)
            Text(explanation)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    @MainActor
    private func linkFolder(at folderURL: URL) {
        let started = folderURL.startAccessingSecurityScopedResource()
        defer { if started { folderURL.stopAccessingSecurityScopedResource() } }
        do {
            let def = try engine.linkInstrumentFolder(at: folderURL)
            Task { @MainActor in
                let configJSON = CustomInstrumentConfig(
                    defID: def.id,
                    features: CustomInstrumentLibrary.initialFeatureStates(for: def)
                ).encode()
                let added = await engine.addInstrument(
                    kind: .custom,
                    sourceIdentifier: def.id.uuidString,
                    configJSON: configJSON,
                    sessionID: session.id
                )
                if let added {
                    onInstrumentAdded?(added)
                }
                selection = .customInstrumentFile(def.id, def.entrypoint)
                dismiss()
            }
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func detailContent(descriptor: InstrumentDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isAlreadyAdded(descriptor) {
                incompatibilityBanner(reason: "This instrument is already added to the session.")
            } else if let reason = incompatibilityReason(for: descriptor) {
                incompatibilityBanner(reason: reason)
            }
            if let ui = InstrumentUIRegistry.shared.ui(for: descriptor.id) {
                ui.makeConfigEditor(
                    configJSON: $initialConfigJSON,
                    engine: engine,
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
    }

    private func incompatibilityBanner(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private func descriptorRow(_ descriptor: InstrumentDescriptor) -> some View {
        let reason = incompatibilityReason(for: descriptor)
        let alreadyAdded = isAlreadyAdded(descriptor)
        let dimmed = reason != nil || alreadyAdded
        let helpText = reason ?? (alreadyAdded ? "Already added" : "")
        return HStack {
            InstrumentIconView(icon: descriptor.icon, pointSize: 12)
            Text(descriptor.displayName)
            Spacer(minLength: 4)
            if dimmed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dimmed ? 0.5 : 1)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("addInstrument.descriptor.\(descriptor.id)")
    }

    private func libraryFolderRow(_ folder: InstrumentFolder) -> some View {
        HStack {
            InstrumentIconView(icon: folder.icon, pointSize: 12)
            Text(folder.name)
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("addInstrument.descriptor.\(Self.libraryFolderDescriptorID(folder))")
    }

    @ToolbarContentBuilder
    private var sharedToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                dismiss()
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(confirmActionLabel) {
                commitCoordinator.flushPendingEdits()
                if selectedDescriptorID == Self.linkFolderDescriptorID {
                    isShowingImportPicker = true
                    return
                }
                if let folder = selectedLibraryFolder {
                    linkFolder(at: folder.folderURL)
                    return
                }
                Task { @MainActor in
                    if selectedDescriptorID == Self.newCustomDescriptorID {
                        await createNewCustomAndDismiss()
                        return
                    }
                    if let descriptor = selectedDescriptor {
                        let newInstrument = await engine.addInstrument(
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
            .disabled(isConfirmActionDisabled)
            .accessibilityIdentifier("addInstrument.add")
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
