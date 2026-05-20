import Frida
import SwiftUI
import SwiftyMonaco
import LumaCore

struct TracerConfigView: View {
    @Binding var config: TracerConfig
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @Environment(\.instrumentSession) private var instrumentSession
    @Environment(\.instrumentInstance) private var instrumentInstance
    @Environment(\.instrumentConfigCommitCoordinator) private var commitCoordinator

    @State private var searchQuery = ""
    @State private var searchScope: TracerTargetScope = .function
    @State private var isResolving = false
    @State private var resolveResults: [ResolvedApi] = []
    @State private var searchError: String?
    @State private var searchErrorHint: SearchErrorHint?
    @State private var searchTask: Task<Void, Never>?
    @State private var installingPackage: String?

    @State private var selectedHookID: UUID?

    @State private var isShowingSearchPopover = false
    @State private var showDeleteConfirmation = false
    @State private var hookToDelete: TracerConfig.Hook?

    @State private var showUnsavedChangesAlert = false
    @State private var pendingSelectionID: UUID?

    @State private var isShowingITraceConfig = false
    @State private var itraceDraftMaxInvocations: Int = ITraceArming.defaultMaxInvocations
    @State private var itraceDraftMaxBytes: Int = ITraceArming.defaultMaxBytesPerInvocation

    @State private var draftCode: String = ""
    @State private var isDirty: Bool = false
    @State private var showSavedCheck: Bool = false
    @State private var commitRegistrationToken: UUID?

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    var body: some View {
        content
            .padding(.top, isConfigOnlyContext ? 0 : 8)
            .padding(.leading, 8)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if isTracerItemSelected || config.hooks.isEmpty {
                emptyState
            } else {
                hookLayout
            }
        }
        .onAppear {
            handleSelectionChangeFromOutside(selection)
            ensureValidSelection()
            if let coordinator = commitCoordinator, commitRegistrationToken == nil {
                commitRegistrationToken = coordinator.register {
                    if isDirty { saveDraft() }
                }
            }
        }
        .onDisappear {
            if let coordinator = commitCoordinator, let token = commitRegistrationToken {
                coordinator.unregister(token)
                commitRegistrationToken = nil
            }
        }
        .onChange(of: config.hooks) { _, hooks in
            if hooks.isEmpty {
                selectedHookID = nil
            } else if let sel = selectedHookID,
                !hooks.contains(where: { $0.id == sel })
            {
                selectedHookID = (isConfigOnlyContext || isCompactWidth) ? hooks.first?.id : nil
            } else if selectedHookID == nil, isConfigOnlyContext || isCompactWidth {
                selectedHookID = hooks.first?.id
            }
        }
        .onChange(of: selection) { _, newSelection in
            handleSelectionChangeFromOutside(newSelection)
        }
        .onChange(of: selectedHookID) {
            syncDraftWithSelection()
        }
        .onChange(of: selectedHook?.code) { _, newCode in
            guard !isDirty, let newCode, newCode != draftCode else { return }
            draftCode = newCode
        }
        .onChange(of: isShowingSearchPopover) { _, showing in
            if !showing {
                searchTask?.cancel()
                searchQuery = ""
                resolveResults = []
                searchError = nil
                searchErrorHint = nil
            }
        }
        .onChange(of: searchScope) {
            searchTask?.cancel()
            resolveResults = []
            searchError = nil
            guard !searchQuery.isEmpty, canResolve else { return }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                await performSearch()
            }
        }
        .onChange(of: searchQuery) { _, newValue in
            searchTask?.cancel()
            resolveResults = []
            searchError = nil

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
            Text("Are you sure you want to delete \"\(hook.displayName)\"?")
        }
        .unsavedChangesAlert(
            isPresented: $showUnsavedChangesAlert,
            message: "You have unsaved changes to this hook’s script.",
            onSave: {
                saveDraft()
                applyPendingSelection()
            },
            onDiscard: {
                discardDraft()
                applyPendingSelection()
            },
            onCancel: {
                pendingSelectionID = nil
            }
        )
    }

    private var selectedHook: TracerConfig.Hook? {
        guard let id = selectedHookID else { return nil }
        return config.hooks.first(where: { $0.id == id })
    }

    private var attachedNode: LumaCore.ProcessNode? {
        guard let session = instrumentSession else { return nil }
        return engine.node(forSessionID: session.id)
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
        return config.hooks.first(where: { $0.addressAnchor == api.anchor })
    }

    private var thisInstrumentID: UUID? {
        instrumentInstance?.id
    }

    private var isConfigOnlyContext: Bool {
        instrumentInstance == nil
    }

    private var isTracerItemSelected: Bool {
        guard let session = instrumentSession,
            let myID = thisInstrumentID,
            case .instrument(let sessionID, let instrumentID) = selection,
            sessionID == session.id,
            instrumentID == myID
        else { return false }
        return true
    }

    private func handleSelectionChangeFromOutside(_ newSelection: SidebarItemID?) {
        guard let session = instrumentSession,
            let thisInstrumentID = thisInstrumentID
        else { return }

        switch newSelection {
        case .instrument(let sessionID, let instrumentID)
        where sessionID == session.id && instrumentID == thisInstrumentID:
            handleUserSelectionChange(nil)
        case .instrumentComponent(let sessionID, let instrumentID, let hookID)
        where sessionID == session.id && instrumentID == thisInstrumentID:
            handleUserSelectionChange(hookID)
        default:
            break
        }
    }

    private func ensureValidSelection() {
        if isTracerItemSelected {
            selectedHookID = nil
            return
        }
        if config.hooks.isEmpty {
            selectedHookID = nil
            return
        }
        if let sel = selectedHookID,
            config.hooks.contains(where: { $0.id == sel })
        {
            return
        }
        selectedHookID = (isConfigOnlyContext || isCompactWidth) ? config.hooks.first?.id : nil
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
        VStack(spacing: 16) {
            if shouldShowEmptyHero {
                Spacer(minLength: 0)
                heroBlock
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            searchSection
                .frame(maxWidth: isCompactWidth ? .infinity : 520, alignment: .top)
                .frame(maxHeight: shouldShowEmptyHero ? nil : .infinity, alignment: .top)
            if shouldShowEmptyHero {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: shouldShowEmptyHero)
    }

    private var shouldShowEmptyHero: Bool {
        searchQuery.isEmpty && resolveResults.isEmpty && !isResolving && searchError == nil
    }

    private var heroBlock: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text(heroTitle)
                    .font(.title3.weight(.semibold))

                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 24)
    }

    private var heroTitle: String {
        config.hooks.isEmpty ? "Start tracing functions" : "Trace another function"
    }

    private var heroSubtitle: String {
        config.hooks.isEmpty
            ? "Search for functions in the attached process and add them as hooks."
            : "Search for more functions to add, or select an existing hook to edit it."
    }

    private var hookLayout: some View {
        VStack(spacing: 0) {
            if isCompactWidth || isConfigOnlyContext {
                compactHookSwitcher
            }
            ZStack(alignment: .topTrailing) {
                if selectedHook != nil {
                    HookEditorView(
                        draftCode: $draftCode,
                        isDirty: $isDirty,
                        selectedHook: selectedHook,
                        engine: engine,
                    )
                } else {
                    Text("Select a hook to edit its script.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                SaveBarOverlay(
                    isDirty: selectedHook != nil && isDirty,
                    showSavedCheck: selectedHook != nil && showSavedCheck,
                    saveTooltip: "Save current hook script (\u{2318}S)",
                    onSave: saveDraft
                )
            }
        }
    }

    private var compactHookSwitcher: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Hook", selection: hookPickerBinding) {
                    ForEach(config.hooksByMostRecentlyEdited(), id: \.id) { hook in
                        Text(hook.displayName).tag(hook.id as UUID?)
                    }
                }
                if let hook = selectedHook {
                    Divider()
                    if hook.kind == .function {
                        if hook.itraceArming != nil {
                            Button {
                                applyITraceArming(nil)
                            } label: {
                                Label("Disable Instruction Trace", systemImage: "scope")
                            }
                            Button {
                                seedITraceDrafts(from: hook)
                                isShowingITraceConfig = true
                            } label: {
                                Label("Edit Instruction Trace\u{2026}", systemImage: "slider.horizontal.3")
                            }
                        } else {
                            Button {
                                seedITraceDrafts(from: hook)
                                isShowingITraceConfig = true
                            } label: {
                                Label("Enable Instruction Trace\u{2026}", systemImage: "scope")
                            }
                        }
                        Divider()
                    }
                    Button(role: .destructive) {
                        hookToDelete = hook
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Hook", systemImage: "trash")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedHook?.displayName ?? "Select a hook")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingITraceConfig, arrowEdge: .trailing) {
                ITracePopover(
                    captured: selectedHook.map { itraceCaptured(for: $0.id) } ?? 0,
                    isOn: selectedHook?.itraceArming != nil,
                    draftMaxInvocations: $itraceDraftMaxInvocations,
                    draftMaxBytes: $itraceDraftMaxBytes,
                    onEnable: {
                        applyITraceArming(
                            ITraceArming(
                                maxInvocations: itraceDraftMaxInvocations,
                                maxBytesPerInvocation: itraceDraftMaxBytes
                            )
                        )
                        isShowingITraceConfig = false
                    },
                    onDisable: {
                        applyITraceArming(nil)
                        isShowingITraceConfig = false
                    }
                )
            }

            addHookButton
        }
        .padding(.horizontal, 12)
        .padding(.top, isConfigOnlyContext ? 0 : 8)
        .padding(.bottom, isConfigOnlyContext ? 6 : 8)
    }

    private func seedITraceDrafts(from hook: TracerConfig.Hook) {
        let seed = hook.itraceArming ?? ITraceArming()
        itraceDraftMaxInvocations = seed.maxInvocations
        itraceDraftMaxBytes = seed.maxBytesPerInvocation
    }

    private func applyITraceArming(_ arming: ITraceArming?) {
        guard let session = instrumentSession,
              let hookID = selectedHookID
        else { return }
        Task { @MainActor in
            await engine.updateTracerHook(sessionID: session.id, hookID: hookID) { hook in
                hook.itraceArming = arming
            }
        }
    }

    private var hookPickerBinding: Binding<UUID?> {
        Binding(
            get: { selectedHookID },
            set: { newValue in
                guard let newValue, newValue != selectedHookID else { return }
                if isDirty {
                    pendingSelectionID = newValue
                    showUnsavedChangesAlert = true
                } else {
                    selectedHookID = newValue
                }
            }
        )
    }

    private var addHookButton: some View {
        Button {
            isShowingSearchPopover = true
        } label: {
            Image(systemName: "plus")
        }
        .help("Add hooks by searching functions")
        .popover(isPresented: $isShowingSearchPopover) {
            #if canImport(UIKit)
            if isCompactWidth {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 0) {
                        searchSection
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .navigationTitle("Add Hook")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { isShowingSearchPopover = false }
                        }
                    }
                }
                .id("tracer.searchPopover")
                .transaction { $0.animation = nil }
            } else {
                desktopSearchPopover
            }
            #else
            desktopSearchPopover
            #endif
        }
    }

    private var desktopSearchPopover: some View {
        searchSection
            .frame(width: 520, height: 400, alignment: .top)
            .padding(12)
            .id("tracer.searchPopover")
            .transaction { $0.animation = nil }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(searchScope.placeholder, text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("tracer.searchQuery")
                    #if canImport(UIKit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif

                scopeMenu

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
                .accessibilityIdentifier("tracer.searchButton")
            }

            if isResolving {
                Text("Searching…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = searchError {
                errorBanner(message: error)
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
                    .accessibilityIdentifier("tracer.addAll")
                }

                List(resolveResults) { api in
                    HStack(alignment: .center) {
                        VStack(alignment: .leading) {
                            Text(api.displayName)
                                .font(.callout)
                            if let detail = api.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let hook = existingHook(for: api) {
                            Button("View Handler") {
                                openHook(hook)
                            }
                            .platformLinkButtonStyle()
                        } else {
                            Button("Add") {
                                addAndOpen(api)
                            }
                            .platformLinkButtonStyle()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let hook = existingHook(for: api) {
                            openHook(hook)
                        } else {
                            addAndOpen(api)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            } else if !searchQuery.isEmpty && !isResolving && canResolve && searchError == nil {
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
            searchError = nil
        }
    }

    @ViewBuilder
    private func errorBanner(message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let hint = searchErrorHint {
                let pkg = hint.packageName
                Button {
                    installMissingPackage(hint)
                } label: {
                    if installingPackage == pkg {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Install")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(installingPackage == pkg)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(TracerTargetScope.allCases, id: \.self) { scope in
                Button(scope.label) {
                    searchScope = scope
                }
            }
        } label: {
            Text(searchScope.label)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Target scope")
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
        } else {
            selectedHookID = nil
        }
        pendingSelectionID = nil
    }

    private var selectedHookIsFunctionHook: Bool {
        selectedHook?.kind == .function
    }

    private func bindingForSelectedHookITraceArming() -> Binding<ITraceArming?> {
        Binding(
            get: {
                guard let hook = selectedHook else { return nil }
                return config.hooks.first(where: { $0.id == hook.id })?.itraceArming
            },
            set: { newValue in
                guard let hook = selectedHook,
                    let idx = config.hooks.firstIndex(where: { $0.id == hook.id })
                else { return }
                config.hooks[idx].itraceArming = newValue
            }
        )
    }

    private func itraceCaptured(for hookID: UUID) -> Int {
        guard let session = instrumentSession else { return 0 }
        let traces = engine.tracesBySession[session.id] ?? []
        return traces.reduce(into: 0) { count, trace in
            if case .functionCall(let id, _) = trace.origin, id == hookID { count += 1 }
        }
    }

    private func bindingForSelectedHookEnabled() -> Binding<Bool> {
        Binding(
            get: {
                guard let hook = selectedHook else { return false }
                return config.hooks.first(where: { $0.id == hook.id })?.state == .enabled
            },
            set: { newValue in
                guard let hook = selectedHook,
                    let idx = config.hooks.firstIndex(where: { $0.id == hook.id })
                else { return }
                config.hooks[idx].state = newValue ? .enabled : .disabled
            }
        )
    }

    private func saveDraft() {
        guard let hook = selectedHook,
            let idx = config.hooks.firstIndex(where: { $0.id == hook.id })
        else { return }

        config.hooks[idx].updateCode(draftCode)
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
                navigateOuterSelection(toHookID: existing.id)
            }
            return existing
        }

        let hook = TracerConfig.Hook(
            displayName: api.displayName,
            addressAnchor: api.anchor,
            kind: .function,
            code: defaultTracerCode(kind: .function, anchor: api.anchor, displayName: api.displayName)
        )

        config.hooks.append(hook)

        if select {
            navigateOuterSelection(toHookID: hook.id)
        }

        return hook
    }

    private func openHook(_ hook: TracerConfig.Hook) {
        navigateOuterSelection(toHookID: hook.id)
        isShowingSearchPopover = false
    }

    private func addAndOpen(_ api: ResolvedApi) {
        addResultAsHook(api, select: true)
        isShowingSearchPopover = false
    }

    private func navigateOuterSelection(toHookID hookID: UUID) {
        guard let session = instrumentSession,
            let instrumentID = thisInstrumentID
        else {
            handleUserSelectionChange(hookID)
            return
        }
        selectedHookID = hookID
        selection = .instrumentComponent(session.id, instrumentID, hookID)
    }

    private func addAllResultsAsHooks() {
        var hooks = config.hooks
        let existingAnchors = Set(hooks.map(\.addressAnchor))
        for api in resolveResults where !existingAnchors.contains(api.anchor) {
            hooks.append(
                TracerConfig.Hook(
                    displayName: api.displayName,
                    addressAnchor: api.anchor,
                    kind: .function,
                    code: defaultTracerCode(kind: .function, anchor: api.anchor, displayName: api.displayName)
                )
            )
        }
        config.hooks = hooks
        isShowingSearchPopover = false
    }

    private func removeHooks(ids: Set<UUID>) {
        let idsSet = ids
        config.hooks.removeAll { idsSet.contains($0.id) }

        if let currentID = selectedHookID, idsSet.contains(currentID) {
            selectedHookID = config.hooks.first?.id
        }

        syncDraftWithSelection()
    }

    private func removeHooks(ids: [UUID]) {
        removeHooks(ids: Set(ids))
    }

    struct ResolvedApi: Identifiable, Hashable {
        let id = UUID()
        let displayName: String
        let detail: String?
        let address: UInt64
        let anchor: AddressAnchor
    }

    @MainActor
    private func performSearch() async {
        guard canResolve, let node = attachedNode, !searchQuery.isEmpty else { return }

        isResolving = true
        defer { isResolving = false }

        do {
            let arr = try await node.resolveTargets(scope: searchScope.rawValue, query: searchQuery)

            resolveResults = try arr.map(parseResolvedTarget)
            searchError = nil
            searchErrorHint = nil
        } catch {
            resolveResults = []
            let classified = classify(error)
            searchError = classified.message
            searchErrorHint = classified.hint
        }
    }

    private func classify(_ error: any Swift.Error) -> (message: String, hint: SearchErrorHint?) {
        let message: String
        if case let Frida.Error.rpcError(rpcMessage, _) = error {
            message = rpcMessage
        } else {
            message = error.localizedDescription
        }
        let hint: SearchErrorHint? =
            message.contains("'frida-java-bridge'")
            ? .installPackage(name: "frida-java-bridge", globalAlias: "Java")
            : nil
        return (message, hint)
    }

    private func installMissingPackage(_ hint: SearchErrorHint) {
        guard case .installPackage(let name, let alias) = hint else { return }
        installingPackage = name
        Task {
            defer { installingPackage = nil }
            do {
                _ = try await engine.installPackage(name: name, globalAlias: alias)
                await performSearch()
            } catch {
                let classified = classify(error)
                searchError = classified.message
                searchErrorHint = classified.hint
            }
        }
    }

    enum SearchErrorHint: Equatable {
        case installPackage(name: String, globalAlias: String?)

        var packageName: String {
            switch self {
            case .installPackage(let name, _): return name
            }
        }
    }

    private func parseResolvedTarget(_ obj: [String: Any]) throws -> ResolvedApi {
        let displayName = try expectString(obj["displayName"] as Any, "displayName")
        let detail = obj["detail"] as? String
        let addressStr = try expectString(obj["address"] as Any, "address")
        let address = try parseAgentHexAddress(addressStr)
        guard let anchorObj = obj["anchor"] as? [String: Any] else {
            throw LumaCoreError.invalidArgument("resolveTargets: missing 'anchor'")
        }
        let anchor = try AddressAnchor.fromJSON(anchorObj)
        return ResolvedApi(displayName: displayName, detail: detail, address: address, anchor: anchor)
    }

    private func expectString(_ value: Any, _ field: String) throws -> String {
        guard let s = value as? String else {
            throw LumaCoreError.invalidArgument("resolveTargets: '\(field)' is not a String")
        }
        return s
    }
}

private struct ITracePill: View {
    let captured: Int
    @Binding var arming: ITraceArming?

    @State private var isPresented = false
    @State private var draftMaxInvocations: Int
    @State private var draftMaxBytes: Int

    init(captured: Int, arming: Binding<ITraceArming?>) {
        self.captured = captured
        self._arming = arming
        let seed = arming.wrappedValue ?? ITraceArming()
        self._draftMaxInvocations = State(initialValue: seed.maxInvocations)
        self._draftMaxBytes = State(initialValue: seed.maxBytesPerInvocation)
    }

    var body: some View {
        Button {
            if let arming {
                draftMaxInvocations = arming.maxInvocations
                draftMaxBytes = arming.maxBytesPerInvocation
            }
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "scope").imageScale(.small)
                Text(label).monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fillColor, in: Capsule())
            .foregroundStyle(strokeColor)
            .overlay(Capsule().stroke(strokeColor.opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(arming == nil ? "Set up an instruction trace" : "Edit instruction trace caps")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ITracePopover(
                captured: captured,
                isOn: arming != nil,
                draftMaxInvocations: $draftMaxInvocations,
                draftMaxBytes: $draftMaxBytes,
                onEnable: enableWithDrafts,
                onDisable: disableTrace
            )
        }
    }

    private var label: String {
        guard let arming else { return "ITrace" }
        return "ITrace \(captured) / \(arming.maxInvocations)"
    }

    private var fillColor: Color {
        arming == nil ? Color.secondary.opacity(0.10) : Color.accentColor.opacity(0.18)
    }

    private var strokeColor: Color {
        arming == nil ? Color.secondary : Color.accentColor
    }

    private func enableWithDrafts() {
        arming = ITraceArming(
            maxInvocations: draftMaxInvocations,
            maxBytesPerInvocation: draftMaxBytes
        )
        isPresented = false
    }

    private func disableTrace() {
        arming = nil
        isPresented = false
    }
}

struct ITracePopover: View {
    let captured: Int
    let isOn: Bool
    @Binding var draftMaxInvocations: Int
    @Binding var draftMaxBytes: Int
    let onEnable: () -> Void
    let onDisable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Instruction trace").font(.headline)
            Text("Capture every call up to the caps below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Stepper(value: $draftMaxInvocations, in: 1...100) {
                    LabeledContent("Max calls") {
                        Text("\(draftMaxInvocations)").monospacedDigit()
                    }
                }
                Stepper(
                    value: $draftMaxBytes,
                    in: (256 * 1024)...(64 * 1024 * 1024),
                    step: 256 * 1024
                ) {
                    LabeledContent("Max per call") {
                        Text(formatBytes(draftMaxBytes)).monospacedDigit()
                    }
                }
            }

            if isOn {
                Text("\(captured) of \(draftMaxInvocations) captured")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                if isOn {
                    Button(role: .destructive, action: onDisable) {
                        Label("Disable", systemImage: "stop.circle")
                    }
                }
                Spacer()
                Button(action: onEnable) {
                    Label(isOn ? "Save caps" : "Enable", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private func formatBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }
}

private struct HookEditorView: View {
    @Binding var draftCode: String
    @Binding var isDirty: Bool
    let selectedHook: TracerConfig.Hook?
    let engine: Engine

    @State private var editorFocused: Bool = false

    var body: some View {
        let packages = (try? engine.store.fetchPackagesState().packages) ?? []
        CodeEditorView(
            text: $draftCode,
            profile: EditorProfile.fridaTracerHook(packages: packages),
            focused: $editorFocused,
            engine: engine,
        )
        .onChange(of: draftCode) { _, _ in
            isDirty = (draftCode != selectedHook?.code)
        }
        .onChange(of: selectedHook?.id) { _, _ in
            scheduleFocus()
        }
        .task(id: selectedHook?.id) {
            scheduleFocus()
        }
        .accessibilityIdentifier("tracer.hookEditor")
    }

    private func scheduleFocus() {
        guard selectedHook != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            editorFocused = true
        }
    }
}

