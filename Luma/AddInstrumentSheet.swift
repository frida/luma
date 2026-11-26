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
    @State private var storeItemBeingAdded: StoreItem.ID?
    @State private var editedStoreCopyAction: EditedStoreCopyAction?
    @State private var storeFailure: UIError?
    @State private var searchText = ""

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
        let storeFolderPaths = Set(storefront.installedItems.map { storefront.installationFolderURL(for: $0.id).standardizedFileURL.path })
        return engine.instrumentFolders.folders.filter {
            engine.customInstrumentID(linkedToFolderAt: $0.folderURL) == nil
                && !storeFolderPaths.contains($0.folderURL.standardizedFileURL.path)
        }
    }

    private var storefront: Storefront {
        engine.storefront
    }

    private var storeItems: [StoreItem] {
        storefront.installedItems + storefront.results
    }

    private var shownBuiltinDescriptors: [InstrumentDescriptor] {
        builtinDescriptors.filter { matchesSearch($0.displayName) }
    }

    private var shownCustomDescriptors: [InstrumentDescriptor] {
        let representedByStoreRows = customInstrumentIDsOfInstalledStoreItems
        return customDescriptors.filter { !representedByStoreRows.contains($0.sourceIdentifier) && matchesSearch($0.displayName) }
    }

    private var customInstrumentIDsOfInstalledStoreItems: Set<String> {
        Set(
            storefront.installedItems.compactMap {
                engine.customInstrumentID(linkedToFolderAt: storefront.installationFolderURL(for: $0.id))?.uuidString
            }
        )
    }

    private var shownInstalledStoreItems: [StoreItem] {
        storefront.installedItems.filter { matchesSearch($0.name) }
    }

    private var shownLibraryFolders: [InstrumentFolder] {
        libraryFolders.filter { matchesSearch($0.name) }
    }

    private func matchesSearch(_ name: String) -> Bool {
        searchQuery.isEmpty || name.localizedStandardContains(searchQuery)
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let storeResultsShownAtFirst = 6
    private static let newCustomDescriptorID: String = "custom:__new__"
    private static let linkFolderDescriptorID: String = "custom:__link__"

    private static func libraryFolderDescriptorID(_ folder: InstrumentFolder) -> String {
        "folder:\(folder.folderURL.path)"
    }

    private static func storeItemDescriptorID(_ item: StoreItem) -> String {
        "store:\(item.id)"
    }

    private var selectedDescriptor: InstrumentDescriptor? {
        guard let id = selectedDescriptorID else { return nil }
        return descriptors.first { $0.id == id }
    }

    private var selectedLibraryFolder: InstrumentFolder? {
        guard let id = selectedDescriptorID else { return nil }
        return libraryFolders.first { Self.libraryFolderDescriptorID($0) == id }
    }

    private var selectedStoreItem: StoreItem? {
        guard let id = selectedDescriptorID else { return nil }
        return storeItems.first { Self.storeItemDescriptorID($0) == id }
    }

    private var confirmActionLabel: String {
        selectedDescriptorID == Self.linkFolderDescriptorID ? "Choose Folder\u{2026}" : "Add"
    }

    private var isConfirmActionDisabled: Bool {
        if selectedDescriptorID == Self.newCustomDescriptorID { return false }
        if selectedDescriptorID == Self.linkFolderDescriptorID { return false }
        if selectedLibraryFolder != nil { return false }
        if let item = selectedStoreItem { return !canAdd(item) }
        guard let descriptor = selectedDescriptor else { return true }
        if isAlreadyAdded(descriptor) { return true }
        return incompatibilityReason(for: descriptor) != nil
    }

    private func canAdd(_ item: StoreItem) -> Bool {
        guard storeItemBeingAdded == nil, !isAlreadyAdded(item), incompatibilityReason(for: item.compatibility) == nil else { return false }
        if case .requiresLuma = storefront.installState(of: item) { return false }
        if case .sponsorshipNeeded = storefront.entitlementToAdd(item) { return false }
        return true
    }

    private func isAlreadyAdded(_ descriptor: InstrumentDescriptor) -> Bool {
        alreadyAddedDescriptorIDs.contains(descriptor.id)
    }

    private func isAlreadyAdded(_ item: StoreItem) -> Bool {
        guard let defID = engine.customInstrumentID(linkedToFolderAt: storefront.installationFolderURL(for: item.id)),
            let descriptor = customDescriptors.first(where: { $0.sourceIdentifier == defID.uuidString })
        else { return false }
        return isAlreadyAdded(descriptor)
    }

    private func incompatibilityReason(for descriptor: InstrumentDescriptor) -> String? {
        incompatibilityReason(for: descriptor.compatibility)
    }

    private func incompatibilityReason(for compatibility: InstrumentCompatibility) -> String? {
        guard let systemParams else { return nil }
        return compatibility.incompatibilityReason(for: systemParams)
    }

    private func refreshAlreadyAdded() {
        let existing = (try? engine.store.fetchInstruments(sessionID: session.id)) ?? []
        alreadyAddedDescriptorIDs = Set(existing.map { engine.descriptor(for: $0).id })
    }

    private func openStore() async {
        await resolveSystemParameters()
        await storefront.open(for: systemParams, showing: Self.storeResultsShownAtFirst)
        await searchStore()
    }

    private func resolveSystemParameters() async {
        let devices = await engine.deviceManager.currentDevices()
        guard let device = devices.first(where: { $0.id == session.deviceID }) else { return }
        systemParams = await engine.systemParameters.parameters(for: device)
    }

    private func searchStore() async {
        guard storefront.searchText != searchQuery else { return }
        await storefront.search(searchQuery)
    }

    var body: some View {
        Group {
            if isCompactWidth {
                compactBody
            } else {
                regularBody
            }
        }
        .frame(minWidth: isCompactWidth ? 0 : 800, minHeight: isCompactWidth ? 0 : 420, idealHeight: isCompactWidth ? nil : 540)
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
        .confirmationDialog(
            editedStoreCopyAction?.title ?? "",
            isPresented: editedStoreCopyBinding,
            titleVisibility: .visible,
            presenting: editedStoreCopyAction
        ) { action in
            Button(action.confirmTitle, role: .destructive) {
                discardEditedStoreCopy(action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .alert(storeFailure?.title ?? "", isPresented: storeFailureBinding, presenting: storeFailure) { _ in
            Button("OK") { storeFailure = nil }
        } message: { failure in
            Text(failure.message)
        }
        .gitHubSignInSheet(auth: engine.gitHubAuth, precedence: .foremost)
        .task(id: session.deviceID) { await openStore() }
        .onChange(of: searchQuery) { Task { await searchStore() } }
        .task(id: session.id) { refreshAlreadyAdded() }
        .task { engine.instrumentFolders.reload() }
        .onDisappear { Task { await storefront.close() } }
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )
    }

    private var editedStoreCopyBinding: Binding<Bool> {
        Binding(
            get: { editedStoreCopyAction != nil },
            set: { if !$0 { editedStoreCopyAction = nil } }
        )
    }

    private func discardEditedStoreCopy(_ action: EditedStoreCopyAction) {
        switch action {
        case .replace(let item):
            addStoreItem(item, localChanges: .discard)
        case .remove(let item):
            uninstallStoreItem(item, localChanges: .discard)
        }
    }

    private var storeFailureBinding: Binding<Bool> {
        Binding(
            get: { storeFailure != nil },
            set: { if !$0 { storeFailure = nil } }
        )
    }

    private var compactBody: some View {
        NavigationStack(path: $compactPath) {
            List {
                Section {
                    ForEach(shownBuiltinDescriptors) { descriptor in
                        NavigationLink(value: descriptor.id) {
                            descriptorRow(descriptor)
                        }
                    }
                }
                StoreResultsSection(storefront: storefront) { item in
                    storeItemLink(item)
                }
                Section("Custom Instruments") {
                    ForEach(shownCustomDescriptors) { descriptor in
                        NavigationLink(value: descriptor.id) {
                            descriptorRow(descriptor)
                        }
                    }
                    ForEach(shownInstalledStoreItems) { item in
                        storeItemLink(item)
                    }
                    ForEach(storefront.installationsAwaitingStore) { outdated in
                        awaitingStoreRow(outdated)
                    }
                    ForEach(shownLibraryFolders, id: \.folderURL) { folder in
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
            .searchable(text: $searchText)
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
                } else if let item = storeItems.first(where: { Self.storeItemDescriptorID($0) == id }) {
                    storeItemDetail(item)
                        .navigationTitle(item.name)
                        #if canImport(UIKit)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar { sharedToolbar }
                        .onAppear { selectedDescriptorID = id }
                }
            }
        }
    }

    private func storeItemLink(_ item: StoreItem) -> some View {
        NavigationLink(value: Self.storeItemDescriptorID(item)) {
            storeItemRow(item)
        }
    }

    @ViewBuilder
    private var descriptorList: some View {
        Section {
            ForEach(shownBuiltinDescriptors) { descriptor in
                descriptorRow(descriptor).tag(descriptor.id)
            }
        }
        StoreResultsSection(storefront: storefront) { item in
            storeItemRow(item).tag(Self.storeItemDescriptorID(item))
        }
        Section("Custom Instruments") {
            ForEach(shownCustomDescriptors) { descriptor in
                descriptorRow(descriptor).tag(descriptor.id)
            }
            ForEach(shownInstalledStoreItems) { item in
                storeItemRow(item).tag(Self.storeItemDescriptorID(item))
            }
            ForEach(storefront.installationsAwaitingStore) { outdated in
                awaitingStoreRow(outdated)
            }
            ForEach(shownLibraryFolders, id: \.folderURL) { folder in
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
            VStack(spacing: 0) {
                searchField
                List(selection: $selectedDescriptorID) {
                    descriptorList
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 240, idealWidth: 260)
            .navigationTitle("Add Instrument")
        } detail: {
            Group {
                if selectedDescriptorID == Self.newCustomDescriptorID {
                    newCustomDetail
                } else if selectedDescriptorID == Self.linkFolderDescriptorID {
                    linkFolderDetail
                } else if let folder = selectedLibraryFolder {
                    libraryFolderDetail(folder)
                } else if let item = selectedStoreItem {
                    storeItemDetail(item)
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

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier("addInstrument.search")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @MainActor
    private func createNewCustomAndDismiss() async {
        let def = engine.createCustomInstrument()
        let configJSON = CustomInstrumentConfig(
            defID: def.id,
            settings: CustomInstrumentLibrary.initialSettingStates(for: def)
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
            Text("Custom instruments are TypeScript snippets you write inline. They are saved with the project, can be added to multiple sessions, and synchronized when collaboration is enabled. After creating one you can rename it, choose an icon, and define toggleable settings from the sidebar.")
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
                    settings: CustomInstrumentLibrary.initialSettingStates(for: def)
                ).encode()
                let added = await engine.addInstrument(
                    kind: .custom,
                    sourceIdentifier: def.id.uuidString,
                    configJSON: configJSON,
                    sessionID: session.id
                )
                if let added {
                    onInstrumentAdded?(added)
                } else {
                    selection = .customInstrumentFile(def.id, def.entrypoint)
                }
                dismiss()
            }
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func detailContent(descriptor: InstrumentDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            unavailabilityBanner(isAlreadyAdded: isAlreadyAdded(descriptor), compatibility: descriptor.compatibility)
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

    private func storeItemDetail(_ item: StoreItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            unavailabilityBanner(isAlreadyAdded: isAlreadyAdded(item), compatibility: item.compatibility)
            StoreItemDetailView(item: item, storefront: storefront) {
                uninstallStoreItem(item, localChanges: .keep)
            }
            .id(item.id)
        }
    }

    @ViewBuilder
    private func unavailabilityBanner(isAlreadyAdded: Bool, compatibility: InstrumentCompatibility) -> some View {
        if isAlreadyAdded {
            incompatibilityBanner(reason: "This instrument is already added to the session.")
        } else if let reason = incompatibilityReason(for: compatibility) {
            incompatibilityBanner(reason: reason)
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

    private func storeItemRow(_ item: StoreItem) -> some View {
        let reason = incompatibilityReason(for: item.compatibility)
        let alreadyAdded = isAlreadyAdded(item)
        let dimmed = reason != nil || alreadyAdded
        let helpText = reason ?? (alreadyAdded ? "Already added" : "")
        return HStack {
            StoreItemIconView(item: item, storefront: storefront, pointSize: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                Text(storefront.updateNotice(for: item.id) ?? item.publisher.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if dimmed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.access.listingTitle)
                if let badgeTitle = storefront.installState(of: item).badgeTitle {
                    Text(badgeTitle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dimmed ? 0.5 : 1)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("addInstrument.descriptor.\(Self.storeItemDescriptorID(item))")
    }

    @ToolbarContentBuilder
    private var sharedToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                dismiss()
            }
        }
        if storeItemBeingAdded != nil {
            ToolbarItem(placement: .confirmationAction) {
                ProgressView()
                    .controlSize(.small)
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
                if let item = selectedStoreItem {
                    addStoreItem(item, localChanges: .keep)
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

    private func awaitingStoreRow(_ outdated: Storefront.OutdatedInstallation) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(outdated.name)
            Text(outdated.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
    }

    private func addStoreItem(_ item: StoreItem, localChanges: Storefront.LocalChanges) {
        Task { @MainActor in
            storeItemBeingAdded = item.id
            defer { storeItemBeingAdded = nil }
            do {
                if storefront.installState(of: item).needsDownload {
                    try await storefront.install(item, localChanges: localChanges)
                }
                linkFolder(at: storefront.installationFolderURL(for: item.id))
            } catch StorefrontError.signInCancelled, StorefrontError.rejected(.sponsorshipRequired, _) {
            } catch StorefrontError.localChanges {
                editedStoreCopyAction = .replace(item)
            } catch {
                storeFailure = UIError(title: "Could not add \(item.name)", message: error.localizedDescription)
            }
        }
    }

    private func uninstallStoreItem(_ item: StoreItem, localChanges: Storefront.LocalChanges) {
        do {
            try storefront.uninstall(itemID: item.id, localChanges: localChanges)
        } catch StorefrontError.localChanges {
            editedStoreCopyAction = .remove(item)
        } catch {
            storeFailure = UIError(title: "Could not uninstall \(item.name)", message: error.localizedDescription)
        }
    }
}

private enum EditedStoreCopyAction {
    case replace(StoreItem)
    case remove(StoreItem)

    var title: String {
        switch self {
        case .replace:
            return "Replace Your Edits?"
        case .remove:
            return "Delete Your Edits?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .replace:
            return "Replace"
        case .remove:
            return "Uninstall"
        }
    }

    var message: String {
        switch self {
        case .replace(let item):
            return "\(item.name) has been edited since it was installed. Installing \(item.version.description) replaces those edits."
        case .remove(let item):
            return "\(item.name) has been edited since it was installed. Uninstalling it deletes those edits."
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
