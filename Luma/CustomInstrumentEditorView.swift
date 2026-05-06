import LumaCore
import SwiftUI
import SwiftyMonaco

struct CustomInstrumentEditorView: View {
    let defID: UUID
    @ObservedObject var workspace: Workspace

    @State private var draftSource: String = ""
    @State private var isDirty = false
    @State private var showSavedCheck = false

    private var def: CustomInstrumentDef? {
        workspace.engine.customInstruments.def(withId: defID)
    }

    var body: some View {
        Group {
            if let def {
                content(def: def)
            } else {
                Text("Custom instrument not found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func content(def: CustomInstrumentDef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(def: def)
                .padding(.horizontal, 16)
            CodeEditorView(
                text: $draftSource,
                profile: EditorProfile.fridaCustomInstrument(
                    packages: workspace.engine.installedPackages,
                    def: def
                ),
                introspector: nil,
                workspace: workspace,
            )
            .accessibilityIdentifier("customInstrument.editor")
        }
        .padding(.top, 8)
        .onAppear { syncFromDef(def) }
        .onChange(of: defID) { _, _ in
            if let d = self.def { syncFromDef(d) }
        }
        .onChange(of: draftSource) { _, _ in recomputeDirty() }
    }

    private func header(def: CustomInstrumentDef) -> some View {
        HStack(spacing: 8) {
            InstrumentIconView(icon: def.icon, pointSize: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(def.name).font(.headline)
                Text("Custom instrument")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            saveStatusIcon
            Button("Save") { saveDraft() }
                .disabled(!isDirty)
                .accessibilityIdentifier("customInstrument.save")
                .keyboardShortcut("s", modifiers: [.command])
        }
    }

    private var saveStatusIcon: some View {
        ZStack {
            if isDirty {
                Circle().frame(width: 6, height: 6)
            }
            if showSavedCheck {
                Image(systemName: "checkmark.circle.fill")
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .frame(width: 14, height: 14)
    }

    private func saveDraft() {
        guard var d = def else { return }
        d.source = draftSource
        Task { @MainActor in
            await workspace.engine.updateCustomInstrument(d)
            isDirty = false
            showSavedCheck = true
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation { showSavedCheck = false }
        }
    }

    private func syncFromDef(_ def: CustomInstrumentDef) {
        draftSource = def.source
        isDirty = false
    }

    private func recomputeDirty() {
        guard let def else { return }
        isDirty = draftSource != def.source
    }
}

struct CustomInstrumentFeaturesPopover: View {
    let def: CustomInstrumentDef
    @ObservedObject var workspace: Workspace
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
        .frame(width: 520)
        .onAppear { draftFeatures = def.features }
    }

    private func toggleAdding() {
        isAddingFeature.toggle()
        if isAddingFeature {
            expandedFeatureID = nil
            DispatchQueue.main.async { draftFocus = .id }
        } else {
            resetDraft()
        }
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
        var updated = def
        updated.features = draftFeatures
        Task { @MainActor in
            await workspace.engine.updateCustomInstrument(updated)
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
                if isBooleanSchema {
                    Image(systemName: "chevron.right").opacity(0)
                } else {
                    Button {
                        expandedID = isExpanded ? nil : feature.id
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                }
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
            if isExpanded && !isBooleanSchema {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Optional (user can disable)", isOn: $feature.optional)
                        .platformCheckboxToggleStyle()
                    if feature.optional {
                        Toggle("Enabled by default", isOn: $feature.enabledByDefault)
                            .platformCheckboxToggleStyle()
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
            if case .boolean = newSchema {
                if feature.optional { feature.optional = false }
            } else {
                expandedID = feature.id
            }
        }
    }
}
