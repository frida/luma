import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct CustomInstrumentMetadataMenu: View {
    let defID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var presentation = CustomInstrumentMenuPresentation()

    var body: some View {
        if let def = engine.customInstruments.def(withId: defID) {
            Menu {
                CustomInstrumentMenuItems(def: def, engine: engine, presentation: $presentation)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Custom instrument actions")
            .customInstrumentMenuPresentations(def: def, engine: engine, selection: $selection, presentation: $presentation)
        }
    }
}

struct CustomInstrumentMenuItems: View {
    let def: CustomInstrumentDef
    let engine: Engine
    @Binding var presentation: CustomInstrumentMenuPresentation
    @Environment(\.errorPresenter) private var errorPresenter

    private var isLinked: Bool { engine.instrumentFolderLinks[def.id] != nil }
    private var labSubject: LabSubject { LabSubject(.definition, def.id) }

    var body: some View {
        Button {
            presentation.isShowingRename = true
        } label: {
            Label("Rename & Icon\u{2026}", systemImage: "pencil")
        }
        Button {
            presentation.isShowingCompatibility = true
        } label: {
            Label("Compatibility\u{2026}", systemImage: "checkmark.shield")
        }
        Button {
            presentation.isShowingSettings = true
        } label: {
            Label("Settings\u{2026}", systemImage: "switch.2")
        }
        Button {
            presentation.widgetsEditor = .widgets
        } label: {
            Label("Widgets\u{2026}", systemImage: "chart.xyaxis.line")
        }
        Button {
            presentation.widgetsEditor = .layout
        } label: {
            Label("Layout\u{2026}", systemImage: "rectangle.3.group")
        }
        Button {
            presentation.isShowingPackages = true
        } label: {
            Label("Packages\u{2026}", systemImage: "shippingbox")
        }
        Divider()
        Button {
            presentation.addFilePrompt.present()
        } label: {
            Label("Add File\u{2026}", systemImage: "plus")
        }
        Button {
            presentation.renameEntrypointPrompt.present(current: def.entrypoint)
        } label: {
            Label("Rename Entrypoint File\u{2026}", systemImage: "pencil")
        }
        Divider()
        if isLinked {
            Button {
                presentation.reloadFromFolder(def.id, engine: engine)
            } label: {
                Label("Reload from Folder", systemImage: "arrow.down.doc")
            }
            if engine.instrumentFolderDrifts[def.id] == .diverged {
                Button {
                    presentation.writeToFolder(def.id, engine: engine)
                } label: {
                    Label("Write to Folder", systemImage: "arrow.up.doc")
                }
            }
            Button {
                engine.unlinkInstrumentFolder(defID: def.id)
            } label: {
                Label("Unlink Folder", systemImage: "minus.circle")
            }
        }
        Button(action: presentExportPicker) {
            Label("Export to Folder\u{2026}", systemImage: "square.and.arrow.up")
        }
        if isLinked {
            Button {
                presentation.isShowingPublish = true
            } label: {
                Label("Publish to Store\u{2026}", systemImage: "storefront")
            }
            .accessibilityIdentifier("customInstrument.publishToStore")
        }
        if engine.isKeptFromLab(labSubject) {
            Button {
                if let refusal = engine.addToLab(labSubject) {
                    errorPresenter.present("Can’t add “\(def.name)” to the lab", refusal)
                }
            } label: {
                Label("Add to Lab", systemImage: "person.2.wave.2")
            }
        }
        Divider()
        Button(role: .destructive) {
            presentation.isShowingDeleteConfirm = true
        } label: {
            Label("Delete Custom Instrument", systemImage: "trash")
        }
    }

    private func presentExportPicker() {
        do {
            presentation.exportBundle = InstrumentFolderExportBundle(files: try engine.exportedFiles(forCustomInstrument: def.id))
        } catch {
            presentation.errorMessage = error.localizedDescription
        }
    }
}

extension View {
    func customInstrumentMenuPresentations(
        def: CustomInstrumentDef,
        engine: Engine,
        selection: Binding<SidebarItemID?>,
        presentation: Binding<CustomInstrumentMenuPresentation>
    ) -> some View {
        modifier(CustomInstrumentMenuPresentations(def: def, engine: engine, selection: selection, presentation: presentation))
    }
}

private struct CustomInstrumentMenuPresentations: ViewModifier {
    let def: CustomInstrumentDef
    let engine: Engine
    @Binding var selection: SidebarItemID?
    @Binding var presentation: CustomInstrumentMenuPresentation

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $presentation.isShowingRename, arrowEdge: .trailing) {
                CustomInstrumentRenamePopover(def: def, engine: engine)
            }
            .popover(isPresented: $presentation.isShowingCompatibility, arrowEdge: .trailing) {
                CustomInstrumentCompatibilityPopover(def: def, engine: engine)
            }
            .popover(isPresented: $presentation.isShowingSettings, arrowEdge: .trailing) {
                CustomInstrumentSettingsPopover(def: def, engine: engine)
            }
            .sheet(item: $presentation.widgetsEditor) { tab in
                CustomInstrumentWidgetsSheet(def: def, engine: engine, tab: tab)
            }
            .popover(isPresented: $presentation.isShowingPackages, arrowEdge: .trailing) {
                CustomInstrumentPackagesPopover(def: def, engine: engine, selection: $selection)
            }
            .popover(isPresented: $presentation.addFilePrompt.isPresented, arrowEdge: .trailing) {
                CustomInstrumentFilePathPopover(
                    title: "Add File",
                    hint: "Relative path inside this instrument. Subdirectories allowed. "
                        + "Use .hexpat for a pattern, .pat for a pattern library.",
                    commitLabel: "Add",
                    draft: $presentation.addFilePrompt.draft,
                    problem: presentation.addFilePrompt.problem(defID: def.id, engine: engine),
                    canCommit: presentation.addFilePrompt.canCommit(defID: def.id, engine: engine),
                    onCommit: commitAddFile)
            }
            .popover(isPresented: $presentation.renameEntrypointPrompt.isPresented, arrowEdge: .trailing) {
                CustomInstrumentFilePathPopover(
                    title: "Rename Entrypoint File",
                    hint: "Renaming the entrypoint updates the entrypoint automatically.",
                    commitLabel: "Rename",
                    draft: $presentation.renameEntrypointPrompt.draft,
                    problem: presentation.renameEntrypointPrompt.problem(originalPath: def.entrypoint, defID: def.id, engine: engine),
                    canCommit: presentation.renameEntrypointPrompt.canCommit(originalPath: def.entrypoint, defID: def.id, engine: engine),
                    onCommit: commitRenameEntrypoint)
            }
            .sheet(isPresented: $presentation.isShowingPublish) {
                StorePublishSheet(defID: def.id, engine: engine)
            }
            .confirmationDialog(
                "Delete \"\(def.name)\"?",
                isPresented: $presentation.isShowingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteInstrument() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the custom instrument from the project and from any sessions where it is loaded.")
            }
            .fileExporter(
                isPresented: exportPickerBinding,
                document: presentation.exportBundle.map(InstrumentFolderExportDocument.init),
                contentType: .folder,
                defaultFilename: InstrumentFolderExportDocument.suggestedFilename(for: def.name)
            ) { result in
                if case .failure(let error) = result {
                    presentation.errorMessage = error.localizedDescription
                }
                presentation.exportBundle = nil
            }
            .alert("Custom instrument error", isPresented: errorBinding, presenting: presentation.errorMessage) { _ in
                Button("OK") { presentation.errorMessage = nil }
            } message: { message in
                Text(message)
            }
    }

    private func commitAddFile() {
        let path = presentation.addFilePrompt.normalizedPath
        let defID = def.id
        presentation.addFilePrompt.reset()
        presentation.reportingErrors {
            selection = .customInstrumentFile(defID, try engine.addCustomInstrumentFile(defID: defID, path: path))
        }
    }

    private func commitRenameEntrypoint() {
        let from = def.entrypoint
        let to = presentation.renameEntrypointPrompt.normalizedPath
        let defID = def.id
        presentation.renameEntrypointPrompt.reset()
        presentation.reportingErrors {
            let renamedPath = try engine.renameCustomInstrumentFile(defID: defID, from: from, to: to)
            if selection == .customInstrumentFile(defID, from) {
                selection = .customInstrumentFile(defID, renamedPath)
            }
        }
    }

    private func deleteInstrument() {
        let defID = def.id
        Task { @MainActor in
            await engine.deleteCustomInstrument(defID)
            if selection?.belongsTo(defID: defID) ?? false {
                selection = .notebook
            }
        }
    }

    private var exportPickerBinding: Binding<Bool> {
        Binding(
            get: { presentation.exportBundle != nil },
            set: { if !$0 { presentation.exportBundle = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { presentation.errorMessage != nil },
            set: { if !$0 { presentation.errorMessage = nil } }
        )
    }
}

struct CustomInstrumentMenuPresentation {
    var isShowingRename = false
    var isShowingCompatibility = false
    var isShowingSettings = false
    var widgetsEditor: WidgetsEditorTab?
    var isShowingPackages = false
    var addFilePrompt = AddFilePromptState()
    var renameEntrypointPrompt = RenamePromptState()
    var exportBundle: InstrumentFolderExportBundle?
    var isShowingPublish = false
    var isShowingDeleteConfirm = false
    var errorMessage: String?

    mutating func reloadFromFolder(_ defID: UUID, engine: Engine) {
        reportingErrors { try engine.reloadCustomInstrumentFromFolder(defID: defID) }
    }

    mutating func writeToFolder(_ defID: UUID, engine: Engine) {
        reportingErrors { try engine.writeCustomInstrumentToFolder(defID: defID) }
    }

    mutating func reportingErrors(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
