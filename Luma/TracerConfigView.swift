import Frida
import SwiftUI
import SwiftyMonaco

struct TracerConfigView: View {
    @Binding var config: TracerConfig
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Environment(\.instrumentSession) private var instrumentSession

    @State private var searchQuery = ""
    @State private var isResolving = false
    @State private var resolveResults: [ResolvedApi] = []
    @State private var searchTask: Task<Void, Never>?

    @State private var selectedHookID: UUID?
    @State private var listSelection: Set<UUID> = []
    @State private var lastHandledNavigationID: UUID?

    @State private var isShowingSearchPopover = false
    @State private var showDeleteConfirmation = false
    @State private var hookToDelete: TracerConfig.Hook?

    @State private var showUnsavedChangesAlert = false
    @State private var pendingSelectionID: UUID?

    @State private var showMultiDeleteAlert = false
    @State private var pendingMultiDeleteIDs: Set<UUID> = []

    @State private var layoutMode: LayoutMode = .compact

    @State private var draftCode: String = ""
    @State private var isDirty: Bool = false
    @State private var showSavedCheck: Bool = false

    enum LayoutMode: String, CaseIterable, Identifiable {
        case compact
        case expanded

        var id: String { rawValue }

        var label: String {
            switch self {
            case .compact: return "Compact"
            case .expanded: return "List"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let isNarrow = geo.size.width < 800
            content(isNarrow: isNarrow)
        }
    }

    @ViewBuilder
    private func content(isNarrow: Bool) -> some View {
        let effectiveMode: LayoutMode = isNarrow ? .compact : layoutMode

        Group {
            if config.hooks.isEmpty {
                emptyState
            } else {
                switch effectiveMode {
                case .compact:
                    compactLayout(isNarrow: isNarrow)
                case .expanded:
                    expandedLayout(isNarrow: isNarrow)
                }
            }
        }
        .onAppear {
            ensureValidSelection()
        }
        .onChange(of: config.hooks) { _, hooks in
            if hooks.isEmpty {
                selectedHookID = nil
            } else if let sel = selectedHookID,
                !hooks.contains(where: { $0.id == sel })
            {
                selectedHookID = hooks.first?.id
            } else if selectedHookID == nil {
                selectedHookID = hooks.first?.id
            }
        }
        .onChange(of: selection) { _, newSelection in
            handleSelectionChangeFromOutside(newSelection)
        }
        .onChange(of: selectedHookID) {
            syncDraftWithSelection()
        }
        .onChange(of: isShowingSearchPopover) { _, showing in
            if !showing {
                searchTask?.cancel()
                searchQuery = ""
                resolveResults = []
            }
        }
        .onChange(of: layoutMode) { _, newValue in
            if newValue == .expanded {
                if let sel = selectedHookID {
                    listSelection = [sel]
                } else {
                    listSelection = []
                }
            } else {
                listSelection = []
            }
        }
        .onChange(of: searchQuery) { _, newValue in
            searchTask?.cancel()
            resolveResults = []

            guard !newValue.isEmpty, canResolve else { return }

            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                await performSearch()
            }
        }
        .alert("Delete Hook?", isPresented: $showDeleteConfirmation, presenting: hookToDelete) { hook in
            Button("Delete", role: .destructive) {
                removeHooks(ids: [hook.id])
            }
            Button("Cancel", role: .cancel) {}
        } message: { hook in
            Text("Are you sure you want to delete “\(hook.displayName)”?")
        }
        .alert("Delete \(pendingMultiDeleteIDs.count) Hooks?", isPresented: $showMultiDeleteAlert) {
            Button("Delete", role: .destructive) {
                removeHooks(ids: pendingMultiDeleteIDs)
                pendingMultiDeleteIDs = []
            }
            Button("Cancel", role: .cancel) {
                pendingMultiDeleteIDs = []
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
            Button("Save") {
                saveDraft()
                applyPendingSelection()
            }
            Button("Discard Changes", role: .destructive) {
                discardDraft()
                applyPendingSelection()
            }
            Button("Cancel", role: .cancel) {
                if layoutMode == .expanded {
                    if let sel = selectedHookID {
                        listSelection = [sel]
                    } else {
                        listSelection = []
                    }
                }
                pendingSelectionID = nil
            }
        } message: {
            Text("You have unsaved changes to this hook’s script.")
        }
        .animation(.none, value: layoutMode)
    }

    private var selectedHook: TracerConfig.Hook? {
        guard let id = selectedHookID else { return nil }
        return config.hooks.first(where: { $0.id == id })
    }

    private var attachedNode: ProcessNode? {
        guard let session = instrumentSession else { return nil }
        return workspace.processNodes.first { $0.sessionRecord.id == session.id }
    }

    private var canResolve: Bool {
        attachedNode != nil
    }

    private var saveStatusIcon: some View {
        ZStack {
            if isDirty {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
            if showSavedCheck {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .frame(width: 14, height: 14)
        .help(isDirty ? "Unsaved changes" : (showSavedCheck ? "Saved" : ""))
    }

    private func existingHook(for api: ResolvedApi) -> TracerConfig.Hook? {
        config.hooks.first { hook in
            hook.symbolName == api.symbolName && hook.moduleName == api.moduleName
        }
    }

    private func handleSelectionChangeFromOutside(_ newSelection: SidebarItemID?) {
        guard
            let session = instrumentSession,
            case .instrumentComponent(let sessionID, let instrumentID, let hookID, let navID) = newSelection,
            sessionID == session.id,
            let thisInstrumentID = session.instruments.first(where: { $0.kind == .tracer })?.id,
            thisInstrumentID == instrumentID
        else {
            return
        }

        guard navID != lastHandledNavigationID else { return }

        handleUserSelectionChange(hookID)

        lastHandledNavigationID = navID
    }

    private func ensureValidSelection() {
        if config.hooks.isEmpty {
            selectedHookID = nil
            return
        }
        if let sel = selectedHookID,
            config.hooks.contains(where: { $0.id == sel })
        {
            return
        }
        selectedHookID = config.hooks.first?.id
    }

    private func syncDraftWithSelection() {
        if let hook = selectedHook {
            draftCode = hook.code
        } else {
            draftCode = ""
        }
        isDirty = false
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "scope")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Start tracing functions")
                    .font(.title3.weight(.semibold))

                Text("Search for functions in the attached process and add them as hooks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            searchSection
                .frame(width: 420)
                .padding(12)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactLayout(isNarrow: Bool) -> some View {
        VStack(spacing: 0) {
            compactToolbar(showLayoutPicker: !isNarrow)
            Divider()
            if selectedHook != nil {
                HookEditorView(
                    draftCode: $draftCode,
                    isDirty: $isDirty,
                    selectedHook: selectedHook
                )
            } else {
                Text("Select a hook to edit its script.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func expandedLayout(isNarrow: Bool) -> some View {
        PlatformHSplit {
            leftPane(isNarrow: isNarrow)
            rightPane(isNarrow: isNarrow)
        }
    }

    @ViewBuilder
    private func leftPane(isNarrow: Bool) -> some View {
        Group {
            if listSelection.count <= 1, selectedHook != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            saveStatusIcon
                            saveButton
                        }
                    }

                    HookEditorView(
                        draftCode: $draftCode,
                        isDirty: $isDirty,
                        selectedHook: selectedHook
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listSelection.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Multiple hooks selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Choose a single hook to edit its handler.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
            } else {
                Text("Select a hook to edit its script.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(minWidth: 320, idealWidth: 1024, maxHeight: .infinity)
        .padding(.trailing, 10)
    }

    private func rightPane(isNarrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            expandedToolbar(showLayoutPicker: !isNarrow)

            HooksListView(
                hooks: config.hooks,
                selection: $listSelection,
                onToggleEnabled: { hook, newValue in
                    if let idx = config.hooks.firstIndex(where: { $0.id == hook.id }) {
                        config.hooks[idx].isEnabled = newValue
                    }
                },
                onDeleteSingle: { hook in
                    hookToDelete = hook
                    showDeleteConfirmation = true
                },
                onMultiDelete: {
                    pendingMultiDeleteIDs = listSelection
                    showMultiDeleteAlert = true
                },
                onSelectionChange: { newValue in
                    if newValue.count == 1, let id = newValue.first {
                        handleUserSelectionChange(id)
                    } else if newValue.isEmpty {
                        handleUserSelectionChange(nil)
                    }
                }
            )
        }
        .frame(minWidth: 320, idealWidth: 320, maxWidth: 500, maxHeight: .infinity)
    }

    private func compactToolbar(showLayoutPicker: Bool) -> some View {
        HStack(spacing: 8) {
            if config.hooks.count > 1 {
                Picker(
                    "Hook",
                    selection: Binding<UUID>(
                        get: {
                            selectedHookID ?? config.hooks.first!.id
                        },
                        set: { newID in
                            handleUserSelectionChange(newID)
                        }
                    )
                ) {
                    ForEach(config.hooks) { hook in
                        Text(hook.displayName).tag(hook.id)
                    }
                }
                .labelsHidden()
            } else if let hook = config.hooks.first {
                Text(hook.displayName)
                    .font(.headline)
            }

            if selectedHook != nil {
                Toggle("Enabled", isOn: bindingForSelectedHookEnabled())
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Spacer()

            HStack(spacing: 6) {
                saveStatusIcon
                saveButton
            }

            addHookButton

            if selectedHook != nil {
                Button(role: .destructive) {
                    hookToDelete = selectedHook
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected hook")
            }

            if showLayoutPicker {
                layoutPicker
            }
        }
        .padding(.bottom, 6)
    }

    private func expandedToolbar(showLayoutPicker: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Hooks")
                .font(.headline)

            Spacer()

            if listSelection.count > 1 {
                Button(role: .destructive) {
                    pendingMultiDeleteIDs = listSelection
                    showMultiDeleteAlert = true
                } label: {
                    Label("Delete (\(listSelection.count))", systemImage: "trash")
                }
            }

            addHookButton

            if showLayoutPicker {
                layoutPicker
            }
        }
        .padding(.horizontal)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var saveButton: some View {
        Button("Save") {
            saveDraft()
        }
        .disabled(!isDirty || selectedHook == nil)
        .keyboardShortcut("s", modifiers: [.command])
        .help("Save current hook script")
    }

    private var addHookButton: some View {
        Button {
            isShowingSearchPopover = true
        } label: {
            Image(systemName: "plus")
        }
        .help("Add hooks by searching functions")
        .popover(isPresented: $isShowingSearchPopover) {
            searchSection
                .frame(width: 420)
                .padding(12)
        }
    }

    private var layoutPicker: some View {
        Picker("", selection: $layoutMode) {
            ForEach(LayoutMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
        .help("Change hooks layout")
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search APIs (e.g. open, objc_msgSend)", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await performSearch() }
                } label: {
                    if isResolving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .disabled(searchQuery.isEmpty || isResolving || !canResolve)
                .help(canResolve ? "Search in the attached process" : "Attach to a process to search APIs")
            }

            if isResolving {
                Text("Searching…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !resolveResults.isEmpty {
                HStack {
                    Text("Results")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add All") {
                        addAllResultsAsHooks()
                    }
                    .disabled(resolveResults.isEmpty)
                }

                List(resolveResults) { api in
                    HStack(alignment: .center) {
                        VStack(alignment: .leading) {
                            Text(api.symbolName)
                                .font(.callout)
                            if let module = api.moduleName {
                                Text(module)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let hook = existingHook(for: api) {
                            Button("View Handler") {
                                handleUserSelectionChange(hook.id)
                                isShowingSearchPopover = false
                            }
                            .platformLinkButtonStyle()
                        } else {
                            Button("Add") {
                                _ = addResultAsHook(api, select: false)
                                isShowingSearchPopover = false
                            }
                            .platformLinkButtonStyle()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let hook = existingHook(for: api) {
                            handleUserSelectionChange(hook.id)
                            isShowingSearchPopover = false
                        } else {
                            _ = addResultAsHook(api, select: false)
                            isShowingSearchPopover = false
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 200)
            } else if !searchQuery.isEmpty && !isResolving && canResolve {
                Text("No results. Try another pattern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !canResolve {
                Text("Attach to a process to search functions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            searchTask?.cancel()
            searchQuery = ""
            resolveResults = []
        }
    }

    private func handleUserSelectionChange(_ newValue: UUID?) {
        guard newValue != selectedHookID else { return }

        if isDirty {
            pendingSelectionID = newValue
            showUnsavedChangesAlert = true
        } else {
            selectedHookID = newValue
        }
    }

    private func applyPendingSelection() {
        if let id = pendingSelectionID {
            selectedHookID = id
            if layoutMode == .expanded {
                listSelection = [id]
            }
        } else {
            selectedHookID = nil
            if layoutMode == .expanded {
                listSelection = []
            }
        }
        pendingSelectionID = nil
    }

    private func bindingForSelectedHookEnabled() -> Binding<Bool> {
        Binding(
            get: {
                guard let hook = selectedHook else { return false }
                return config.hooks.first(where: { $0.id == hook.id })?.isEnabled ?? false
            },
            set: { newValue in
                guard let hook = selectedHook,
                    let idx = config.hooks.firstIndex(where: { $0.id == hook.id })
                else { return }
                config.hooks[idx].isEnabled = newValue
            }
        )
    }

    private func saveDraft() {
        guard let hook = selectedHook,
            let idx = config.hooks.firstIndex(where: { $0.id == hook.id })
        else { return }

        config.hooks[idx].code = draftCode
        isDirty = false

        showSavedCheck = true
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                withAnimation {
                    showSavedCheck = false
                }
            }
        }
    }

    private func discardDraft() {
        draftCode = selectedHook?.code ?? ""
        isDirty = false
    }

    @discardableResult
    private func addResultAsHook(_ api: ResolvedApi, select: Bool) -> TracerConfig.Hook {
        if let existing = existingHook(for: api) {
            if select {
                handleUserSelectionChange(existing.id)
            }
            return existing
        }

        var stub = defaultTracerStub
        stub = stub.replacingOccurrences(of: "CALL(args[0]", with: "\(api.symbolName)(args[0]")

        let hook = TracerConfig.Hook(
            displayName: api.symbolName,
            moduleName: api.moduleName,
            symbolName: api.symbolName,
            isEnabled: true,
            code: stub
        )

        config.hooks.append(hook)

        if select {
            handleUserSelectionChange(hook.id)
        }

        return hook
    }

    private func addAllResultsAsHooks() {
        for api in resolveResults {
            if existingHook(for: api) == nil {
                _ = addResultAsHook(api, select: false)
            }
        }
        isShowingSearchPopover = false
    }

    private func removeHooks(ids: Set<UUID>) {
        let idsSet = ids
        config.hooks.removeAll { idsSet.contains($0.id) }

        if let currentID = selectedHookID, idsSet.contains(currentID) {
            selectedHookID = config.hooks.first?.id
        }
        listSelection.subtract(idsSet)

        syncDraftWithSelection()
    }

    private func removeHooks(ids: [UUID]) {
        removeHooks(ids: Set(ids))
    }

    struct ResolvedApi: Identifiable, Hashable {
        let id = UUID()
        let moduleName: String?
        let symbolName: String
    }

    @MainActor
    private func performSearch() async {
        guard canResolve, let node = attachedNode, !searchQuery.isEmpty else { return }

        isResolving = true
        defer { isResolving = false }

        do {
            let raw = try await node.script.exports.resolveApis(searchQuery)

            guard let arr = raw as? [JSONObject] else {
                resolveResults = []
                return
            }

            resolveResults = arr.compactMap { obj in
                guard let symbol = (obj["symbolName"] as? String) ?? (obj["name"] as? String) else {
                    return nil
                }
                let module = obj["moduleName"] as? String ?? obj["module"] as? String
                return ResolvedApi(moduleName: module, symbolName: symbol)
            }
        } catch {
            resolveResults = []
        }
    }
}

private struct HookEditorView: View {
    @Binding var draftCode: String
    @Binding var isDirty: Bool
    let selectedHook: TracerConfig.Hook?

    var body: some View {
        CodeEditorView(
            text: $draftCode,
            profile: TracerEditorProfile.typescript,
        )
        .onChange(of: draftCode) { _, _ in
            isDirty = (draftCode != selectedHook?.code)
        }
    }
}

private struct HooksListView: View {
    let hooks: [TracerConfig.Hook]
    @Binding var selection: Set<UUID>
    let onToggleEnabled: (TracerConfig.Hook, Bool) -> Void
    let onDeleteSingle: (TracerConfig.Hook) -> Void
    let onMultiDelete: () -> Void
    let onSelectionChange: (Set<UUID>) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(hooks) { hook in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hook.displayName)
                        if let module = hook.moduleName {
                            Text(module)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: {
                                hooks.first(where: { $0.id == hook.id })?.isEnabled ?? false
                            },
                            set: { newValue in
                                onToggleEnabled(hook, newValue)
                            }
                        )
                    )
                    .labelsHidden()
                }
                .tag(hook.id)
                .contextMenu {
                    if selection.count > 1 {
                        Button("Delete (\(selection.count))", role: .destructive) {
                            onMultiDelete()
                        }
                    }
                    Button("Delete This Hook", role: .destructive) {
                        onDeleteSingle(hook)
                    }
                }
            }
        }
        .onChange(of: selection) { _, newValue in
            onSelectionChange(newValue)
        }
    }
}
