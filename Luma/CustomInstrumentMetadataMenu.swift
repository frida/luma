import LumaCore
import SwiftUI

struct CustomInstrumentMetadataMenu: View {
    let defID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var isShowingRename = false
    @State private var isShowingCompatibility = false
    @State private var isShowingFeaturesEditor = false
    @State private var isShowingWidgetsEditor = false
    @State private var isShowingDeleteConfirm = false
    @State private var renameEntrypointPrompt = RenamePromptState()
    @State private var errorMessage: String?

    private var def: CustomInstrumentDef? {
        engine.customInstruments.def(withId: defID)
    }

    var body: some View {
        Group {
            if def != nil {
                Menu {
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
                        isShowingFeaturesEditor = true
                    } label: {
                        Label("Features\u{2026}", systemImage: "switch.2")
                    }
                    Button {
                        isShowingWidgetsEditor = true
                    } label: {
                        Label("Widgets\u{2026}", systemImage: "chart.xyaxis.line")
                    }
                    if let entrypoint = def?.entrypoint {
                        Divider()
                        Button {
                            renameEntrypointPrompt.present(current: entrypoint)
                        } label: {
                            Label("Rename Entrypoint File\u{2026}", systemImage: "pencil")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        isShowingDeleteConfirm = true
                    } label: {
                        Label("Delete Custom Instrument", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Custom instrument actions")
            }
        }
        .popover(isPresented: $isShowingRename, arrowEdge: .trailing) {
            if let def {
                CustomInstrumentRenamePopover(def: def, engine: engine)
            }
        }
        .popover(isPresented: $isShowingCompatibility, arrowEdge: .trailing) {
            if let def {
                CustomInstrumentCompatibilityPopover(def: def, engine: engine)
            }
        }
        .popover(isPresented: $isShowingFeaturesEditor, arrowEdge: .trailing) {
            if let def {
                CustomInstrumentFeaturesPopover(def: def, engine: engine)
            }
        }
        .popover(isPresented: $isShowingWidgetsEditor, arrowEdge: .trailing) {
            if let def {
                CustomInstrumentWidgetsPopover(def: def, engine: engine)
            }
        }
        .alert("Rename Entrypoint File", isPresented: $renameEntrypointPrompt.isPresented) {
            TextField("path/to/file.ts", text: $renameEntrypointPrompt.draft)
                .disableAutocorrection(true)
            Button("Rename") { commitRenameEntrypoint() }
                .disabled(!renameEntrypointPrompt.canCommit(originalPath: def?.entrypoint ?? ""))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames the entrypoint file and updates the entrypoint automatically.")
        }
        .confirmationDialog(
            "Delete \"\(def?.name ?? "")\"?",
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteInstrument() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the custom instrument from the project and from any sessions where it is loaded.")
        }
        .alert("Custom instrument error", isPresented: errorBinding, presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func commitRenameEntrypoint() {
        let trimmed = renameEntrypointPrompt.draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let original = def?.entrypoint, trimmed != original else { return }
        let id = defID
        Task { @MainActor in
            do {
                let renamedPath = try engine.renameCustomInstrumentFile(defID: id, from: original, to: trimmed)
                if selection == .customInstrumentFile(id, original) {
                    selection = .customInstrumentFile(id, renamedPath)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteInstrument() {
        let id = defID
        Task { @MainActor in
            await engine.deleteCustomInstrument(id)
            if selection?.belongsTo(defID: id) ?? false {
                selection = .notebook
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
