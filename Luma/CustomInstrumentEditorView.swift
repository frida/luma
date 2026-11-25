import LumaCore
import SwiftUI

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
        .safeAreaInset(edge: .top, spacing: 0) {
            StoreUpdateBanner(defID: defID, engine: engine, prepareForUpdate: saveDraftIfDirty)
        }
        .onAppear {
            isEditorFocused = true
        }
        .onChange(of: file.content, initial: true) { _, newValue in
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

    private func saveDraftIfDirty() throws {
        guard isDirty, let file = displayedFile else { return }
        _ = try engine.writeCustomInstrumentFile(defID: defID, path: file.path, content: draftContent)
        isDirty = false
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

struct CustomInstrumentSettingsPopover: View {
    let def: CustomInstrumentDef
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var draftSettings: [CustomInstrumentDef.Setting] = []
    @State private var newSettingID: String = ""
    @State private var newSettingName: String = ""
    @State private var newSettingKind: SchemaKind = .boolean
    @State private var isAddingSetting: Bool = false
    @State private var nameAutoFilled: Bool = true
    @State private var expandedSettingID: String? = nil
    @State private var isCancelled = false
    @FocusState private var draftFocus: NewSettingField?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.headline)
            Text("Per-session knobs the user can configure. Each has a typed schema (boolean, number, string, regex, combo, object, array, …). Agent code reads `config.settings.<id>` directly; optional settings may be undefined when the user has disabled them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            settingList

            if isAddingSetting {
                HStack(spacing: 6) {
                    TextField("id", text: $newSettingID)
                        .frame(width: 110)
                        .focused($draftFocus, equals: .id)
                        .onChange(of: newSettingID) { _, newValue in
                            applyIDChange(newValue)
                        }
                        .onSubmit(addSetting)
                    TextField("Name", text: $newSettingName)
                        .focused($draftFocus, equals: .name)
                        .onChange(of: newSettingName) { _, newValue in
                            if newValue != CamelCase.humanized(newSettingID) {
                                nameAutoFilled = false
                            }
                        }
                        .onSubmit(addSetting)
                    Picker("", selection: $newSettingKind) {
                        ForEach(SchemaKind.allCases) { k in
                            Text(k.label).tag(k)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    Button("Add") { addSetting() }
                        .disabled(addDisabled)
                }
            }

            HStack {
                Button {
                    toggleAdding()
                } label: {
                    Label(
                        isAddingSetting ? "Done Adding" : "Add Setting",
                        systemImage: isAddingSetting ? "checkmark" : "plus"
                    )
                }
                Spacer()
                Button("Cancel") {
                    isCancelled = true
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .popoverFormSheet(width: 520)
        .onAppear { draftSettings = def.settings }
        .onDisappear {
            if !isCancelled { commit() }
        }
    }

    private func toggleAdding() {
        if isAddingSetting {
            flushDraft()
            isAddingSetting = false
        } else {
            isAddingSetting = true
            expandedSettingID = nil
            DispatchQueue.main.async { draftFocus = .id }
        }
    }

    private func flushDraft() {
        addSetting()
        resetDraft()
    }

    private func resetDraft() {
        newSettingID = ""
        newSettingName = ""
        newSettingKind = .boolean
        nameAutoFilled = true
    }

    private var addDisabled: Bool {
        let id = newSettingID.trimmingCharacters(in: .whitespaces)
        let name = newSettingName.trimmingCharacters(in: .whitespaces)
        return id.isEmpty || name.isEmpty
    }

    private func applyIDChange(_ newValue: String) {
        let lowered = CamelCase.sanitized(newValue)
        if lowered != newValue {
            newSettingID = lowered
            return
        }
        if nameAutoFilled {
            newSettingName = CamelCase.humanized(lowered)
        }
    }

    @ViewBuilder
    private var settingList: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            if draftSettings.isEmpty {
                Text("No settings defined.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach($draftSettings) { $setting in
                    SettingRow(setting: $setting, expandedID: $expandedSettingID) {
                        let removedID = setting.id
                        draftSettings.removeAll { $0.id == removedID }
                        if expandedSettingID == removedID { expandedSettingID = nil }
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

    private func addSetting() {
        let id = newSettingID.trimmingCharacters(in: .whitespaces)
        let name = newSettingName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !draftSettings.contains(where: { $0.id == id }) else { return }
        let kindHasChildren = newSettingKind.hasChildren
        draftSettings.append(
            .init(
                id: id,
                name: name,
                schema: newSettingKind.defaultSchema(),
                optional: false
            )
        )
        newSettingID = ""
        newSettingName = ""
        nameAutoFilled = true
        if kindHasChildren {
            expandedSettingID = id
            isAddingSetting = false
            newSettingKind = .boolean
        } else {
            expandedSettingID = nil
            draftFocus = .id
        }
    }

    private func commit() {
        if isAddingSetting {
            flushDraft()
        }
        let settings = draftSettings
        engine.updateCustomInstrument(def.id) { $0.settings = settings }
    }
}

private enum NewSettingField: Hashable { case id, name }

private struct SettingRow: View {
    @Binding var setting: CustomInstrumentDef.Setting
    @Binding var expandedID: String?
    let onDelete: () -> Void

    private var isExpanded: Bool { expandedID == setting.id }

    private var isBooleanSchema: Bool {
        if case .boolean = setting.schema { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    expandedID = isExpanded ? nil : setting.id
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Text(setting.id).font(.system(.caption, design: .monospaced))
                Text("—").foregroundStyle(.secondary)
                Text(setting.name)
                Spacer()
                SchemaKindPicker(schema: $setting.schema)
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
                        Toggle("Optional (user can disable)", isOn: $setting.optional)
                            .platformCheckboxToggleStyle()
                        if setting.optional {
                            Toggle("Enabled by default", isOn: $setting.enabledByDefault)
                                .platformCheckboxToggleStyle()
                        }
                    }
                    CustomInstrumentSchemaEditor(schema: $setting.schema)
                }
                .padding(.leading, 20)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
        .onChange(of: setting.schema) { _, newSchema in
            if case .boolean = newSchema, setting.optional {
                setting.optional = false
            }
            expandedID = setting.id
        }
    }
}
