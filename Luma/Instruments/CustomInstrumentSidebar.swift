import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct CustomInstrumentsSidebarSection: View {
    let engine: Engine
    @Binding var selection: SidebarItemID?
    @Binding var isSectionExpanded: Bool

    private var defs: [LumaCore.CustomInstrumentDef] { engine.customInstruments.defs }

    var body: some View {
        if !defs.isEmpty {
            Section("Custom Instruments", isExpanded: $isSectionExpanded) {
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
                    .sidebarItemTag(SidebarItemID.customInstrumentFile(def.id, def.entrypoint))

                    if isExpanded {
                        ForEach(auxiliaryFiles, id: \.path) { file in
                            SidebarCustomInstrumentFileRow(
                                def: def,
                                file: file,
                                engine: engine,
                                selection: $selection
                            )
                            .sidebarItemTag(SidebarItemID.customInstrumentFile(def.id, file.path))
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

    @State private var presentation = CustomInstrumentMenuPresentation()

    var body: some View {
        HStack(spacing: 0) {
            chevron
                .padding(.leading, sidebarRowLeadingPad)
                .padding(.trailing, sidebarChevronToIconSpacing)
            InstrumentIconView(icon: def.icon, pointSize: 16)
                .frame(width: sidebarParentIconWidth, alignment: .center)
                .padding(.trailing, sidebarIconToLabelSpacing)
            Text(def.name)
            if let newerItem = engine.storefront.newerItem(forCustomInstrument: def.id) {
                StoreUpdateMark(item: newerItem)
                    .padding(.leading, 6)
                    .accessibilityIdentifier("sidebar.customInstrumentUpdate.\(def.id.uuidString)")
            }
            if engine.isKeptFromLab(LabSubject(.definition, def.id)) {
                NotInLabMark()
                    .padding(.leading, 6)
            }
            Spacer()
            if let drift = engine.instrumentFolderDrifts[def.id] {
                folderDriftIndicator(drift)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("sidebar.customInstrument.\(def.id.uuidString)")
        .contextMenu {
            CustomInstrumentMenuItems(def: def, engine: engine, presentation: $presentation)
        }
        .customInstrumentMenuPresentations(def: def, engine: engine, selection: $selection, presentation: $presentation)
    }

    @ViewBuilder
    private func folderDriftIndicator(_ drift: InstrumentFolderDrift) -> some View {
        switch drift {
        case .folderChanged:
            Button(action: reloadFromFolder) {
                Image(systemName: "arrow.down.doc")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Changed on disk \u{2014} reload")
            .accessibilityLabel("Reload from folder")
        case .diverged:
            Menu {
                Button("Reload from Folder, Discarding Edits Made Here", action: reloadFromFolder)
                Button("Write to Folder, Discarding Changes on Disk", action: writeToFolder)
            } label: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Changed both here and on disk")
            .accessibilityLabel("Resolve differences with folder")
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

    private func reloadFromFolder() {
        presentation.reloadFromFolder(def.id, engine: engine)
    }

    private func writeToFolder() {
        presentation.writeToFolder(def.id, engine: engine)
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

    var normalizedPath: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    func canCommit(defID: UUID, engine: Engine) -> Bool {
        !normalizedPath.isEmpty && problem(defID: defID, engine: engine) == nil
    }

    func problem(defID: UUID, engine: Engine) -> String? {
        normalizedPath.isEmpty ? nil : engine.customInstrumentFileProblem(defID: defID, path: normalizedPath)
    }

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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.patternKind?.symbolName ?? "doc.text")
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
            if !isEntrypoint && file.patternKind == nil {
                Button {
                    setAsEntrypoint()
                } label: {
                    Label("Set as Entrypoint", systemImage: "play.circle")
                }
            }
            Button {
                renamePrompt.present(current: file.path)
            } label: {
                Label("Rename\u{2026}", systemImage: "pencil")
            }
            if !isEntrypoint {
                Divider()
                Button(role: .destructive) {
                    isShowingDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .popover(isPresented: $renamePrompt.isPresented, arrowEdge: .trailing) {
            CustomInstrumentFilePathPopover(
                title: "Rename File",
                hint: isEntrypoint
                    ? "Renaming the entrypoint updates the entrypoint automatically." : "Relative path inside this instrument.",
                commitLabel: "Rename",
                draft: $renamePrompt.draft,
                problem: renamePrompt.problem(originalPath: file.path, defID: def.id, engine: engine),
                canCommit: renamePrompt.canCommit(originalPath: file.path, defID: def.id, engine: engine),
                onCommit: commitRename)
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

    func canCommit(originalPath: String, defID: UUID, engine: Engine) -> Bool {
        !normalizedPath.isEmpty && normalizedPath != originalPath
            && problem(originalPath: originalPath, defID: defID, engine: engine) == nil
    }

    func problem(originalPath: String, defID: UUID, engine: Engine) -> String? {
        guard !normalizedPath.isEmpty, normalizedPath != originalPath else { return nil }
        return engine.customInstrumentFileProblem(defID: defID, path: normalizedPath)
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

struct InstrumentFolderExportBundle: Identifiable {
    let id = UUID()
    let files: [InstrumentFolder.File]
}

struct InstrumentFolderExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.folder]

    let files: [InstrumentFolder.File]

    init(_ exportBundle: InstrumentFolderExportBundle) {
        self.files = exportBundle.files
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        for file in files {
            addFileWrapper(at: file.path, data: file.content, to: root)
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
        return collapsed.isEmpty ? "instrument" : collapsed
    }
}

struct CustomInstrumentRenamePopover: View {
    let def: LumaCore.CustomInstrumentDef
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String = ""
    @State private var draftIcon: InstrumentIcon = .symbolic(InstrumentIconCatalog.default.id)
    @State private var isPickingFile = false
    @State private var isCancelled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename & Icon").font(.headline)
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("customInstrument.rename.name")
            Text("Icon").font(.subheadline)
            iconGrid
            customBitmapRow
            HStack {
                Spacer()
                Button("Cancel") {
                    isCancelled = true
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(12)
        .popoverFormSheet(width: 360)
        .onAppear {
            draftName = def.name
            draftIcon = def.icon
        }
        .onDisappear {
            if !isCancelled { commit() }
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
            ForEach(InstrumentIconCatalog.all, id: \.id) { concept in
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

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespaces)
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        let name = trimmedName
        let icon = draftIcon
        engine.updateCustomInstrument(def.id) {
            $0.name = name
            $0.icon = icon
        }
    }
}
