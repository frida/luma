import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct CustomInstrumentsSidebarSection: View {
    let engine: Engine
    @Binding var selection: SidebarItemID?

    private var defs: [LumaCore.CustomInstrumentDef] { engine.customInstruments.defs }

    var body: some View {
        if !defs.isEmpty {
            Section("Custom Instruments") {
                ForEach(defs) { def in
                    let auxiliaryFiles = auxiliaryFiles(for: def)
                    let isExpanded = engine.sidebarExpansion(forCustomInstrumentDefID: def.id) == .expanded
                    SidebarCustomInstrumentDefRow(
                        def: def,
                        engine: engine,
                        selection: $selection,
                        hasAuxiliaryFiles: !auxiliaryFiles.isEmpty,
                        isExpanded: isExpanded,
                        onToggleExpansion: { toggleExpansion(defID: def.id) }
                    )
                    .tag(SidebarItemID.customInstrumentFile(def.id, def.entrypoint))

                    if isExpanded {
                        ForEach(auxiliaryFiles, id: \.path) { file in
                            SidebarCustomInstrumentFileRow(
                                def: def,
                                file: file,
                                engine: engine,
                                selection: $selection
                            )
                            .tag(SidebarItemID.customInstrumentFile(def.id, file.path))
                        }
                    }
                }
            }
        }
    }

    private func auxiliaryFiles(for def: LumaCore.CustomInstrumentDef) -> [LumaCore.CustomInstrumentFile] {
        CustomInstrumentFile.sortedByPath(
            engine.customInstruments.files(forDefID: def.id).filter { $0.path != def.entrypoint },
            entrypoint: def.entrypoint
        )
    }

    private func toggleExpansion(defID: UUID) {
        let current = engine.sidebarExpansion(forCustomInstrumentDefID: defID)
        engine.setSidebarExpansion(customInstrumentDefID: defID, current == .expanded ? .collapsed : .expanded)
    }
}

struct SidebarCustomInstrumentDefRow: View {
    let def: LumaCore.CustomInstrumentDef
    let engine: Engine
    @Binding var selection: SidebarItemID?
    var hasAuxiliaryFiles: Bool = false
    var isExpanded: Bool = false
    var onToggleExpansion: () -> Void = {}

    @State private var isShowingRename = false
    @State private var isShowingCompatibility = false
    @State private var isShowingFeatures = false
    @State private var isShowingWidgets = false
    @State private var isShowingDeleteConfirm = false
    @State private var addFilePrompt = AddFilePromptState()
    @State private var renameEntrypointPrompt = RenamePromptState()
    @State private var exportBundle: HookPackExportBundle?
    @State private var exportErrorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            chevron
                .padding(.leading, sidebarRowLeadingPad)
                .padding(.trailing, sidebarChevronToIconSpacing)
            InstrumentIconView(icon: def.icon, pointSize: 16)
                .frame(width: sidebarParentIconWidth, alignment: .center)
                .padding(.trailing, sidebarIconToLabelSpacing)
            Text(def.name)
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("sidebar.customInstrument.\(def.id.uuidString)")
        .contextMenu {
            Button {
                isShowingRename = true
            } label: {
                Label("Rename & Icon\u{2026}", systemImage: "pencil")
            }
            Button {
                isShowingCompatibility = true
            } label: {
                Label("Compatibility\u{2026}", systemImage: "checkmark.shield")
            }
            Button {
                isShowingFeatures = true
            } label: {
                Label("Features\u{2026}", systemImage: "switch.2")
            }
            Button {
                isShowingWidgets = true
            } label: {
                Label("Widgets\u{2026}", systemImage: "chart.xyaxis.line")
            }
            Divider()
            Button {
                addFilePrompt.present()
            } label: {
                Label("Add File\u{2026}", systemImage: "plus")
            }
            Button {
                renameEntrypointPrompt.present(current: def.entrypoint)
            } label: {
                Label("Rename Entrypoint File\u{2026}", systemImage: "pencil")
            }
            Divider()
            Button {
                presentExportPicker()
            } label: {
                Label("Export as Hookpack\u{2026}", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                isShowingDeleteConfirm = true
            } label: {
                Label("Delete Custom Instrument", systemImage: "trash")
            }
        }
        .alert("Add File", isPresented: $addFilePrompt.isPresented) {
            TextField("path/to/file.ts", text: $addFilePrompt.draft)
                .disableAutocorrection(true)
            Button("Add") { commitAddFile() }
                .disabled(!addFilePrompt.canCommit)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Relative path inside this instrument. Subdirectories allowed.")
        }
        .alert("Rename Entrypoint File", isPresented: $renameEntrypointPrompt.isPresented) {
            TextField("path/to/file.ts", text: $renameEntrypointPrompt.draft)
                .disableAutocorrection(true)
            Button("Rename") { commitRenameEntrypoint() }
                .disabled(!renameEntrypointPrompt.canCommit(originalPath: def.entrypoint))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames the entrypoint file and updates the entrypoint automatically.")
        }
        .popover(isPresented: $isShowingRename, arrowEdge: .trailing) {
            CustomInstrumentRenamePopover(
                def: def,
                engine: engine
            )
        }
        .popover(isPresented: $isShowingCompatibility, arrowEdge: .trailing) {
            CustomInstrumentCompatibilityPopover(
                def: def,
                engine: engine
            )
        }
        .popover(isPresented: $isShowingFeatures, arrowEdge: .trailing) {
            CustomInstrumentFeaturesPopover(
                def: def,
                engine: engine
            )
        }
        .popover(isPresented: $isShowingWidgets, arrowEdge: .trailing) {
            CustomInstrumentWidgetsPopover(
                def: def,
                engine: engine
            )
        }
        .confirmationDialog(
            "Delete \"\(def.name)\"?",
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let defID = def.id
                Task { @MainActor in
                    await engine.deleteCustomInstrument(defID)
                    if selection?.belongsTo(defID: defID) ?? false {
                        selection = .notebook
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the custom instrument from the project and from any sessions where it is loaded.")
        }
        .fileExporter(
            isPresented: exportPickerBinding,
            document: exportBundle.map(HookPackExportDocument.init),
            contentType: .folder,
            defaultFilename: HookPackExportDocument.suggestedFilename(for: def.name)
        ) { result in
            if case .failure(let error) = result {
                exportErrorMessage = error.localizedDescription
            }
            exportBundle = nil
        }
        .alert("Custom instrument error", isPresented: exportErrorBinding, presenting: exportErrorMessage) { _ in
            Button("OK") { exportErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if hasAuxiliaryFiles {
            Button(action: onToggleExpansion) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: sidebarChevronWidth, height: sidebarChevronWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse instrument" : "Expand instrument")
        } else {
            Color.clear.frame(width: sidebarChevronWidth, height: sidebarChevronWidth)
        }
    }

    private var exportPickerBinding: Binding<Bool> {
        Binding(
            get: { exportBundle != nil },
            set: { if !$0 { exportBundle = nil } }
        )
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )
    }

    private func presentExportPicker() {
        do {
            let bundle = try engine.buildHookPackBundle(for: def)
            exportBundle = HookPackExportBundle(bundle: bundle)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func commitAddFile() {
        let trimmed = addFilePrompt.normalizedPath
        guard !trimmed.isEmpty else { return }
        let defID = def.id
        Task { @MainActor in
            do {
                let path = try engine.writeCustomInstrumentFile(defID: defID, path: trimmed, content: "")
                selection = .customInstrumentFile(defID, path)
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
        addFilePrompt.reset()
    }

    private func commitRenameEntrypoint() {
        let from = def.entrypoint
        let to = renameEntrypointPrompt.normalizedPath
        guard !to.isEmpty, to != from else { return }
        let defID = def.id
        Task { @MainActor in
            do {
                let renamedPath = try engine.renameCustomInstrumentFile(defID: defID, from: from, to: to)
                if selection == .customInstrumentFile(defID, from) {
                    selection = .customInstrumentFile(defID, renamedPath)
                }
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
        renameEntrypointPrompt.reset()
    }
}

extension SidebarItemID {
    func belongsTo(defID: UUID) -> Bool {
        switch self {
        case .customInstrumentDef(let id) where id == defID:
            return true
        case .customInstrumentFile(let id, _) where id == defID:
            return true
        default:
            return false
        }
    }
}

struct AddFilePromptState {
    var isPresented = false
    var draft = ""

    var canCommit: Bool { !normalizedPath.isEmpty }
    var normalizedPath: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    mutating func present() {
        draft = ""
        isPresented = true
    }

    mutating func reset() {
        draft = ""
        isPresented = false
    }
}

struct SidebarCustomInstrumentFileRow: View {
    let def: LumaCore.CustomInstrumentDef
    let file: LumaCore.CustomInstrumentFile
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var renamePrompt = RenamePromptState()
    @State private var isShowingDeleteConfirm = false
    @State private var errorMessage: String?

    private var isEntrypoint: Bool { file.path == def.entrypoint }
    private var canDelete: Bool { !isEntrypoint }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .frame(width: 16, alignment: .center)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(file.path)
                .fontWeight(isEntrypoint ? .semibold : .regular)
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, sidebarChildIndent)
        .accessibilityIdentifier("sidebar.customInstrumentFile.\(def.id.uuidString).\(file.path)")
        .contextMenu {
            if !isEntrypoint {
                Button {
                    setAsEntrypoint()
                } label: {
                    Label("Set as Entrypoint", systemImage: "play.circle")
                }
                Divider()
            }
            Button {
                renamePrompt.present(current: file.path)
            } label: {
                Label("Rename\u{2026}", systemImage: "pencil")
            }
            Button(role: .destructive) {
                isShowingDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canDelete)
        }
        .alert("Rename File", isPresented: $renamePrompt.isPresented) {
            TextField("path/to/file.ts", text: $renamePrompt.draft)
                .disableAutocorrection(true)
            Button("Rename") { commitRename() }
                .disabled(!renamePrompt.canCommit(originalPath: file.path))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isEntrypoint ? "Renaming the entrypoint updates the entrypoint automatically." : "Relative path inside this instrument.")
        }
        .confirmationDialog(
            "Delete \"\(file.path)\"?",
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteFile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this file from the instrument.")
        }
        .alert("Custom instrument error", isPresented: errorBinding, presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func setAsEntrypoint() {
        let defID = def.id
        let path = file.path
        Task { @MainActor in
            do {
                _ = try engine.setCustomInstrumentEntrypoint(defID: defID, path: path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commitRename() {
        let from = file.path
        let to = renamePrompt.normalizedPath
        guard !to.isEmpty, to != from else { return }
        let defID = def.id
        Task { @MainActor in
            do {
                let renamedPath = try engine.renameCustomInstrumentFile(defID: defID, from: from, to: to)
                if selection == .customInstrumentFile(defID, from) {
                    selection = .customInstrumentFile(defID, renamedPath)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        renamePrompt.reset()
    }

    private func deleteFile() {
        let defID = def.id
        let path = file.path
        let entrypoint = def.entrypoint
        Task { @MainActor in
            do {
                try engine.deleteCustomInstrumentFile(defID: defID, path: path)
                if selection == .customInstrumentFile(defID, path) {
                    selection = .customInstrumentFile(defID, entrypoint)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

struct RenamePromptState {
    var isPresented = false
    var draft = ""

    var normalizedPath: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    func canCommit(originalPath: String) -> Bool {
        let trimmed = normalizedPath
        return !trimmed.isEmpty && trimmed != originalPath
    }

    mutating func present(current: String) {
        draft = current
        isPresented = true
    }

    mutating func reset() {
        draft = ""
        isPresented = false
    }
}

struct HookPackExportBundle: Identifiable {
    let id = UUID()
    let bundle: HookPackBundle
}

struct HookPackExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.folder]

    let bundle: HookPackBundle

    init(_ exportBundle: HookPackExportBundle) {
        self.bundle = exportBundle.bundle
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: bundle.manifestData)
        ])
        for file in bundle.files {
            addFileWrapper(at: file.path, data: file.content, to: root)
        }
        if let icon = bundle.icon {
            let iconWrapper = FileWrapper(regularFileWithContents: icon.data)
            iconWrapper.preferredFilename = icon.filename
            root.addFileWrapper(iconWrapper)
        }
        return root
    }

    private func addFileWrapper(at path: String, data: Data, to root: FileWrapper) {
        var components = path.split(separator: "/").map(String.init)
        guard let leafName = components.popLast() else { return }
        var dir = root
        for segment in components {
            if let existing = dir.fileWrappers?[segment], existing.isDirectory {
                dir = existing
            } else {
                let child = FileWrapper(directoryWithFileWrappers: [:])
                child.preferredFilename = segment
                dir.addFileWrapper(child)
                dir = child
            }
        }
        let leaf = FileWrapper(regularFileWithContents: data)
        leaf.preferredFilename = leafName
        dir.addFileWrapper(leaf)
    }

    static func suggestedFilename(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        let slug = trimmed.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(slug).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "hookpack" : collapsed
    }
}

struct CustomInstrumentRenamePopover: View {
    let def: LumaCore.CustomInstrumentDef
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String = ""
    @State private var draftIcon: InstrumentIcon = .symbolic(InstrumentIconCatalog.default.id)
    @State private var isPickingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename Instrument").font(.headline)
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("customInstrument.rename.name")
            Text("Icon").font(.subheadline)
            iconGrid
            customBitmapRow
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .popoverFormSheet(width: 360)
        .onAppear {
            draftName = def.name
            draftIcon = def.icon
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                loadIcon(from: url)
            }
        }
    }

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 8), spacing: 8) {
            ForEach(InstrumentIconCatalog.userPickable, id: \.id) { concept in
                Button {
                    draftIcon = .symbolic(concept.id)
                } label: {
                    Image(systemName: concept.sfSymbol)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isConceptSelected(concept) ? Color.accentColor.opacity(0.25) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(concept.displayName)
            }
        }
    }

    private var customBitmapRow: some View {
        HStack(spacing: 10) {
            Group {
                if case .pixels = draftIcon {
                    InstrumentIconView(icon: draftIcon, pointSize: 32)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.25)))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2]))
                        .frame(width: 32, height: 32)
                }
            }
            Button("Choose File\u{2026}") { isPickingFile = true }
        }
    }

    private func isConceptSelected(_ c: InstrumentIconConcept) -> Bool {
        if case .symbolic(let id) = draftIcon, id == c.id { return true }
        return false
    }

    private func loadIcon(from url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? Data(contentsOf: url) else { return }
        guard let normalized = InstrumentIconRasterizer.normalize(raw) else { return }
        draftIcon = .pixels(normalized)
    }

    private func commit() {
        var updated = def
        updated.name = draftName.trimmingCharacters(in: .whitespaces)
        updated.icon = draftIcon
        Task { @MainActor in
            engine.updateCustomInstrument(updated)
            dismiss()
        }
    }
}
