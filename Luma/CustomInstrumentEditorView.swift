import LumaCore
import SwiftUI
import SwiftyMonaco

struct CustomInstrumentEditorView: View {
    let defID: UUID
    let path: String?
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var isEditorFocused: Bool = false
    @State private var draftContent: String = ""
    @State private var isDirty = false
    @State private var showSavedCheck = false
    @State private var activePath: String?
    @State private var pendingPath: String?
    @State private var showUnsavedAlert = false
    @State private var errorMessage: String?

    private var def: CustomInstrumentDef? {
        engine.customInstruments.def(withId: defID)
    }

    private var requestedPath: String? {
        path ?? def?.entrypoint
    }

    private var displayedFile: CustomInstrumentFile? {
        guard let activePath else { return nil }
        return engine.customInstruments.file(defID: defID, path: activePath)
    }

    var body: some View {
        Group {
            if let def, let file = displayedFile {
                content(def: def, file: file)
            } else if def == nil {
                missingMessage("Custom instrument not found.")
            } else {
                missingMessage("File not found.")
            }
        }
        .onAppear {
            if activePath == nil {
                activePath = requestedPath
                if let file = displayedFile {
                    syncFromFile(file)
                }
            }
        }
        .onChange(of: requestedPath) { _, newPath in
            handleNavigationRequest(toPath: newPath)
        }
        .onChange(of: def?.entrypoint) { _, newEntrypoint in
            guard let newEntrypoint, !isDirty else { return }
            if displayedFile == nil {
                applyNavigation(toPath: newEntrypoint)
            }
        }
        .alert("Custom instrument error", isPresented: errorBinding, presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private func content(def: CustomInstrumentDef, file: CustomInstrumentFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(def: def, file: file)

            ZStack(alignment: .topTrailing) {
                CodeEditorView(
                    text: $draftContent,
                    profile: EditorProfile.fridaCustomInstrument(
                        packages: engine.installedPackages,
                        def: def,
                        files: engine.customInstruments.files(forDefID: defID),
                        activePath: CustomInstrumentFile.workspaceRelativePath(defID: defID, path: file.path)
                    ),
                    focused: $isEditorFocused,
                    engine: engine,
                )
                .accessibilityIdentifier("customInstrument.editor")

                SaveBarOverlay(
                    isDirty: isDirty,
                    showSavedCheck: showSavedCheck,
                    saveTooltip: "Save current file (\u{2318}S)",
                    onSave: saveDraft
                )
            }
        }
        .padding(.top, 8)
        .padding(.leading, 8)
        .padding(.bottom, 8)
        .onAppear {
            isEditorFocused = true
        }
        .onChange(of: file.content) { _, newValue in
            if !isDirty { draftContent = newValue }
        }
        .onChange(of: draftContent) { _, _ in recomputeDirty() }
        .onDisappear { flushDraftIfNeeded() }
        .unsavedChangesAlert(
            isPresented: $showUnsavedAlert,
            message: "You have unsaved changes to \u{201C}\(file.path)\u{201D}.",
            onSave: {
                saveDraft()
                applyNavigation(toPath: pendingPath)
                pendingPath = nil
            },
            onDiscard: {
                applyNavigation(toPath: pendingPath)
                pendingPath = nil
            },
            onCancel: {
                revertSidebarToActive()
                pendingPath = nil
            }
        )
    }

    private func header(def: CustomInstrumentDef, file: CustomInstrumentFile) -> some View {
        HStack(spacing: 8) {
            InstrumentIconView(icon: def.icon, pointSize: 14)
            Text(def.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(file.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            CustomInstrumentMetadataMenu(
                defID: defID,
                engine: engine,
                selection: $selection
            )
            .font(.title3)
            .frame(width: 36, height: 36)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.bottom, 6)
    }

    private func handleNavigationRequest(toPath newPath: String?) {
        guard newPath != activePath else { return }
        if isDirty {
            pendingPath = newPath
            showUnsavedAlert = true
        } else {
            applyNavigation(toPath: newPath)
        }
    }

    private func applyNavigation(toPath newPath: String?) {
        activePath = newPath
        if let file = displayedFile {
            syncFromFile(file)
        }
        isEditorFocused = true
    }

    private func revertSidebarToActive() {
        guard let activePath else { return }
        selection = .customInstrumentFile(defID, activePath)
    }

    private func saveDraft() {
        guard let file = displayedFile else { return }
        let pathToSave = file.path
        let content = draftContent
        Task { @MainActor in
            do {
                _ = try engine.writeCustomInstrumentFile(defID: defID, path: pathToSave, content: content)
                isDirty = false
                showSavedCheck = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                withAnimation { showSavedCheck = false }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func flushDraftIfNeeded() {
        guard isDirty, let file = displayedFile else { return }
        let pathToSave = file.path
        let content = draftContent
        Task { @MainActor in
            do {
                _ = try engine.writeCustomInstrumentFile(defID: defID, path: pathToSave, content: content)
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

    private func syncFromFile(_ file: CustomInstrumentFile) {
        draftContent = file.content
        isDirty = false
    }

    private func recomputeDirty() {
        guard let file = displayedFile else { return }
        isDirty = draftContent != file.content
    }

    private func missingMessage(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct CustomInstrumentFeaturesPopover: View {
    let def: CustomInstrumentDef
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var draftFeatures: [CustomInstrumentDef.Feature] = []
    @State private var newFeatureID: String = ""
    @State private var newFeatureName: String = ""
    @State private var newFeatureKind: SchemaKind = .boolean
    @State private var isAddingFeature: Bool = false
    @State private var nameAutoFilled: Bool = true
    @State private var expandedFeatureID: String? = nil
    @FocusState private var draftFocus: NewFeatureField?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Features").font(.headline)
            Text("Per-session knobs the user can configure. Each has a typed schema (boolean, number, string, regex, combo, object, array, …). Agent code reads `config.features.<id>` directly; optional features may be undefined when the user has disabled them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            featureList

            if isAddingFeature {
                HStack(spacing: 6) {
                    TextField("id", text: $newFeatureID)
                        .frame(width: 110)
                        .focused($draftFocus, equals: .id)
                        .onChange(of: newFeatureID) { _, newValue in
                            applyIDChange(newValue)
                        }
                        .onSubmit(addFeature)
                    TextField("Name", text: $newFeatureName)
                        .focused($draftFocus, equals: .name)
                        .onChange(of: newFeatureName) { _, newValue in
                            if newValue != CamelCase.humanized(newFeatureID) {
                                nameAutoFilled = false
                            }
                        }
                        .onSubmit(addFeature)
                    Picker("", selection: $newFeatureKind) {
                        ForEach(SchemaKind.allCases) { k in
                            Text(k.label).tag(k)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    Button("Add") { addFeature() }
                        .disabled(addDisabled)
                }
            }

            HStack {
                Button {
                    toggleAdding()
                } label: {
                    Label(
                        isAddingFeature ? "Done Adding" : "Add Feature",
                        systemImage: isAddingFeature ? "checkmark" : "plus"
                    )
                }
                Spacer()
                Button("Done") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .popoverFormSheet(width: 520)
        .onAppear { draftFeatures = def.features }
    }

    private func toggleAdding() {
        if isAddingFeature {
            flushDraft()
            isAddingFeature = false
        } else {
            isAddingFeature = true
            expandedFeatureID = nil
            DispatchQueue.main.async { draftFocus = .id }
        }
    }

    private func flushDraft() {
        addFeature()
        resetDraft()
    }

    private func resetDraft() {
        newFeatureID = ""
        newFeatureName = ""
        newFeatureKind = .boolean
        nameAutoFilled = true
    }

    private var addDisabled: Bool {
        let id = newFeatureID.trimmingCharacters(in: .whitespaces)
        let name = newFeatureName.trimmingCharacters(in: .whitespaces)
        return id.isEmpty || name.isEmpty
    }

    private func applyIDChange(_ newValue: String) {
        let lowered = CamelCase.sanitized(newValue)
        if lowered != newValue {
            newFeatureID = lowered
            return
        }
        if nameAutoFilled {
            newFeatureName = CamelCase.humanized(lowered)
        }
    }

    @ViewBuilder
    private var featureList: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            if draftFeatures.isEmpty {
                Text("No features defined.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach($draftFeatures) { $feature in
                    FeatureRow(feature: $feature, expandedID: $expandedFeatureID) {
                        let removedID = feature.id
                        draftFeatures.removeAll { $0.id == removedID }
                        if expandedFeatureID == removedID { expandedFeatureID = nil }
                    }
                }
            }
        }

        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addFeature() {
        let id = newFeatureID.trimmingCharacters(in: .whitespaces)
        let name = newFeatureName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !draftFeatures.contains(where: { $0.id == id }) else { return }
        let kindHasChildren = newFeatureKind.hasChildren
        draftFeatures.append(
            .init(
                id: id,
                name: name,
                schema: newFeatureKind.defaultSchema(),
                optional: false
            )
        )
        newFeatureID = ""
        newFeatureName = ""
        nameAutoFilled = true
        if kindHasChildren {
            expandedFeatureID = id
            isAddingFeature = false
        } else {
            expandedFeatureID = nil
            draftFocus = .id
        }
    }

    private func commit() {
        if isAddingFeature {
            flushDraft()
        }
        var updated = def
        updated.features = draftFeatures
        Task { @MainActor in
            engine.updateCustomInstrument(updated)
            dismiss()
        }
    }
}

private enum NewFeatureField: Hashable { case id, name }

private struct FeatureRow: View {
    @Binding var feature: CustomInstrumentDef.Feature
    @Binding var expandedID: String?
    let onDelete: () -> Void

    private var isExpanded: Bool { expandedID == feature.id }

    private var isBooleanSchema: Bool {
        if case .boolean = feature.schema { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    expandedID = isExpanded ? nil : feature.id
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Text(feature.id).font(.system(.caption, design: .monospaced))
                Text("—").foregroundStyle(.secondary)
                Text(feature.name)
                Spacer()
                SchemaKindPicker(schema: $feature.schema)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !isBooleanSchema {
                        Toggle("Optional (user can disable)", isOn: $feature.optional)
                            .platformCheckboxToggleStyle()
                        if feature.optional {
                            Toggle("Enabled by default", isOn: $feature.enabledByDefault)
                                .platformCheckboxToggleStyle()
                        }
                    }
                    CustomInstrumentSchemaEditor(schema: $feature.schema)
                }
                .padding(.leading, 20)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
        .onChange(of: feature.schema) { _, newSchema in
            if case .boolean = newSchema, feature.optional {
                feature.optional = false
            }
            expandedID = feature.id
        }
    }
}
