import Adw
import CGtk
import Foundation
import Frida
import Gdk
import GLibObject
import Gtk
import LumaCore

@MainActor
final class TracerConfigEditor {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let apply: (Data) -> Void
    private let sharedEditor: MonacoEditor
    private let isConfigOnly: Bool

    fileprivate var config: TracerConfig
    private var selectedHookID: UUID?
    private var forceEmptyState: Bool = false
    private var onHookAdded: ((UUID) -> Void)?

    private let contentSlot: Box
    private var editorPane: EditorPane?
    private var saveBar: SaveBar?
    private var emptyStateSearch: TracerHookSearch?
    private var popoverSearch: TracerHookSearch?
    private var addPopover: Popover?
    private var tracesObservation: StoreObservation?

    init(
        engine: Engine,
        sessionID: UUID,
        config: TracerConfig,
        tracerEditor: MonacoEditor,
        isConfigOnly: Bool = false,
        apply: @escaping (Data) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.config = config
        self.sharedEditor = tracerEditor
        self.isConfigOnly = isConfigOnly
        self.apply = apply
        self.selectedHookID = isConfigOnly ? config.hooks.first?.id : nil

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        contentSlot = Box(orientation: .vertical, spacing: 0)
        contentSlot.hexpand = true
        contentSlot.vexpand = true
        widget.append(child: contentSlot)

        rebuildContent()

        tracesObservation = engine.store.observeAllITraces { [weak self] grouped in
            Task { @MainActor in
                guard let self else { return }
                let traces = grouped[self.sessionID] ?? []
                self.refreshITracePills(traces: traces)
            }
        }
    }

    func update(config newConfig: TracerConfig) {
        let structureChanged = config.hooks.map(\.id) != newConfig.hooks.map(\.id)
        let selectedRemoved = selectedHookID.map { id in
            !newConfig.hooks.contains(where: { $0.id == id })
        } ?? false

        config = newConfig

        if selectedRemoved {
            selectedHookID = nil
            rebuildContent()
            return
        }

        if structureChanged {
            rebuildContent()
            return
        }

        guard let id = selectedHookID,
            let hook = newConfig.hooks.first(where: { $0.id == id }),
            let pane = editorPane
        else { return }
        pane.refreshHookMetadata(hook)
    }

    var onRevertNavigation: ((UUID) -> Void)?

    func selectHook(id: UUID) {
        guard config.hooks.contains(where: { $0.id == id }) else { return }
        guard id != selectedHookID || forceEmptyState else { return }
        requestNavigation(to: .hook(id))
    }

    func showConfigurationView() {
        guard !forceEmptyState else { return }
        requestNavigation(to: .configurationView)
    }

    private enum NavigationTarget {
        case hook(UUID)
        case configurationView
    }
    private var pendingNavigation: NavigationTarget?

    private func requestNavigation(to target: NavigationTarget) {
        guard let editorPane, editorPane.isDirty else {
            applyNavigation(target)
            return
        }
        pendingNavigation = target
        UnsavedChangesDialog.present(
            anchor: editorPane.widget,
            message: "You have unsaved changes to this hook\u{2019}s script.",
            onSave: { [weak self] in
                self?.editorPane?.commit()
                self?.applyPendingNavigation()
            },
            onDiscard: { [weak self] in
                self?.applyPendingNavigation()
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.pendingNavigation = nil
                if let oldID = self.selectedHookID {
                    self.onRevertNavigation?(oldID)
                }
            }
        )
    }

    private func applyPendingNavigation() {
        guard let target = pendingNavigation else { return }
        pendingNavigation = nil
        applyNavigation(target)
    }

    private func applyNavigation(_ target: NavigationTarget) {
        switch target {
        case .hook(let id):
            forceEmptyState = false
            selectedHookID = id
        case .configurationView:
            forceEmptyState = true
            selectedHookID = nil
        }
        rebuildContent()
    }

    func setOnHookAdded(_ handler: ((UUID) -> Void)?) {
        onHookAdded = handler
    }

    func applySessionState() {
        emptyStateSearch?.refreshAttached()
    }

    private func rebuildContent() {
        while let child = contentSlot.firstChild {
            contentSlot.remove(child: child)
        }
        editorPane = nil
        saveBar = nil
        emptyStateSearch = nil
        dismissAddPopover()

        if config.hooks.isEmpty || forceEmptyState {
            let search = TracerHookSearch(
                engine: engine,
                sessionID: sessionID,
                layout: .emptyState,
                hasExistingHooks: !config.hooks.isEmpty,
                existingHookByAnchor: { [weak self] anchor in
                    self?.config.hooks.first(where: { $0.addressAnchor == anchor })
                },
                hooksProvider: { [weak self] in self?.config.hooks ?? [] },
                onPick: { [weak self] apis in
                    self?.handlePickedAPIs(apis)
                },
                onView: { [weak self] hook in
                    self?.onHookAdded?(hook.id)
                }
            )
            emptyStateSearch = search
            contentSlot.append(child: search.widget)
            return
        }

        if isConfigOnly {
            contentSlot.append(child: makeHookSwitcherRow())
        }

        let editorPane = EditorPane(
            engine: engine,
            hook: selectedHook,
            sharedEditor: sharedEditor,
            showToolbar: false,
            onSave: { [weak self] updated in
                self?.saveHook(updated)
            }
        )
        self.editorPane = editorPane

        let saveBar = SaveBar(saveTooltip: "Save current hook script") { [weak editorPane] in
            editorPane?.commit()
        }
        saveBar.setDirty(editorPane.isDirty)
        editorPane.onDirtyChanged = { [weak saveBar] dirty in
            saveBar?.setDirty(dirty)
        }
        self.saveBar = saveBar

        let overlay = Overlay()
        overlay.hexpand = true
        overlay.vexpand = true
        overlay.set(child: editorPane.widget)
        overlay.addOverlay(widget: saveBar.widget)
        contentSlot.append(child: overlay)
    }

    private func makeHookSwitcherRow() -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.marginStart = 12
        row.marginEnd = 12
        row.marginTop = 8
        row.marginBottom = 8

        let ordered = config.hooksByMostRecentlyEdited()
        let labels = ordered.map { $0.displayName }
        let cStrings = labels.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        ptrs.append(nil)
        let dropdownPtr = ptrs.withUnsafeBufferPointer { buf in
            gtk_drop_down_new_from_strings(buf.baseAddress)
        }!
        g_object_ref_sink(UnsafeMutableRawPointer(dropdownPtr))
        let dropdown = DropDown(raw: UnsafeMutableRawPointer(dropdownPtr))
        dropdown.hexpand = true
        if let selectedHookID,
            let idx = ordered.firstIndex(where: { $0.id == selectedHookID })
        {
            dropdown.selected = idx
        }
        let orderedIDs = ordered.map(\.id)
        dropdown.onNotifySelected { [weak self] dd, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let index = Int(dd.selected)
                guard index >= 0, index < orderedIDs.count else { return }
                let id = orderedIDs[index]
                guard id != self.selectedHookID else { return }
                self.selectHook(id: id)
            }
        }
        row.append(child: dropdown)

        if let hook = selectedHook {
            row.append(child: makeActionsMenuButton(for: hook))
        }

        row.append(child: makeAddMenuButton())

        return row
    }

    private func makeActionsMenuButton(for hook: TracerConfig.Hook) -> MenuButton {
        let mb = MenuButton()
        mb.set(iconName: "view-more-symbolic")
        mb.hasFrame = false
        mb.add(cssClass: "flat")
        mb.tooltipText = "Hook actions"
        mb.alwaysShowArrow = false

        let actions = TracerHookContextMenu.Actions(
            toggleEnabled: nil,
            setITraceArming: { [weak self] arming in
                self?.setITraceArming(id: hook.id, arming: arming)
            },
            itraceCaptured: { [weak self] in
                self?.itraceCaptured(for: hook.id) ?? 0
            },
            confirmDelete: { [weak self, weak mb] in
                guard let mb else { return }
                TracerHookContextMenu.presentDeleteDialog(anchor: mb, hook: hook) {
                    self?.deleteHook(id: hook.id)
                }
            }
        )
        mb.set(popover: TracerHookContextMenu.makePopover(for: hook, anchor: mb, actions: actions, dismiss: { [weak mb] in
            mb?.active = false
        }))
        return mb
    }

    private func makeAddMenuButton() -> MenuButton {
        let mb = MenuButton()
        mb.set(iconName: "list-add-symbolic")
        mb.hasFrame = false
        mb.add(cssClass: "flat")
        mb.tooltipText = "Add hooks by searching functions"
        mb.alwaysShowArrow = false

        let popover = Popover()
        popover.autohide = true

        let search = TracerHookSearch(
            engine: engine,
            sessionID: sessionID,
            layout: .popover,
            existingHookByAnchor: { [weak self] anchor in
                self?.config.hooks.first(where: { $0.addressAnchor == anchor })
            },
            hooksProvider: { [weak self] in self?.config.hooks ?? [] },
            onPick: { [weak self, weak popover] apis in
                self?.handlePickedAPIs(apis)
                popover?.popdown()
            },
            onView: { [weak self, weak popover] hook in
                popover?.popdown()
                self?.onHookAdded?(hook.id)
            }
        )

        popover.set(child: search.widget)
        mb.set(popover: popover)
        return mb
    }

    private var selectedHook: TracerConfig.Hook? {
        guard let id = selectedHookID else { return nil }
        return config.hooks.first(where: { $0.id == id })
    }

    private func setHookState(id: UUID, state: TracerConfig.Hook.State) {
        guard let idx = config.hooks.firstIndex(where: { $0.id == id }) else { return }
        config.hooks[idx].state = state
        emit()
    }

    private func setITraceArming(id: UUID, arming: ITraceArming?) {
        guard let idx = config.hooks.firstIndex(where: { $0.id == id }) else { return }
        config.hooks[idx].itraceArming = arming
        emit()
    }

    private func itraceCaptured(for hookID: UUID) -> Int {
        let traces = engine?.tracesBySession[sessionID] ?? []
        return capturedCount(in: traces, hookID: hookID)
    }

    private func capturedCount(in traces: [ITrace], hookID: UUID) -> Int {
        traces.reduce(into: 0) { count, trace in
            if case .functionCall(let id, _) = trace.origin, id == hookID { count += 1 }
        }
    }

    private func refreshITracePills(traces: [ITrace]) {
        guard let hookID = selectedHookID,
            let hook = config.hooks.first(where: { $0.id == hookID })
        else { return }
        let captured = capturedCount(in: traces, hookID: hookID)
        editorPane?.refreshITrace(arming: hook.itraceArming, captured: captured)
    }

    private func saveHook(_ updated: TracerConfig.Hook) {
        guard let idx = config.hooks.firstIndex(where: { $0.id == updated.id }) else { return }
        config.hooks[idx] = updated
        emit()
    }

    private func deleteHook(id: UUID) {
        deleteHooks(ids: [id])
    }

    private func deleteHooks(ids: Set<UUID>) {
        config.hooks.removeAll { ids.contains($0.id) }
        if let sel = selectedHookID, ids.contains(sel) {
            selectedHookID = config.hooks.first?.id
        }
        emit()
        rebuildContent()
    }

    private func emit() {
        apply(config.encode())
    }

    fileprivate struct ResolvedApi {
        let displayName: String
        let detail: String?
        let address: UInt64
        let anchor: AddressAnchor
    }

    private func presentAddPopover(anchor: WidgetRef) {
        dismissAddPopover()
        let popover = Popover()
        popover.autohide = true
        let search = TracerHookSearch(
            engine: engine,
            sessionID: sessionID,
            layout: .popover,
            existingHookByAnchor: { [weak self] anchor in
                self?.config.hooks.first(where: { $0.addressAnchor == anchor })
            },
            hooksProvider: { [weak self] in self?.config.hooks ?? [] },
            onPick: { [weak self] apis in
                self?.handlePickedAPIs(apis)
                self?.dismissAddPopover()
            },
            onView: { [weak self] hook in
                self?.dismissAddPopover()
                self?.onHookAdded?(hook.id)
            }
        )
        popover.set(child: search.widget)
        popover.set(parent: anchor)
        addPopover = popover
        popoverSearch = search
        popover.popup()
    }

    private func dismissAddPopover() {
        if let popover = addPopover {
            popover.popdown()
            popover.unparent()
        }
        addPopover = nil
        popoverSearch = nil
    }

    fileprivate func handlePickedAPIs(_ apis: [ResolvedApi]) {
        let wasInEmptyMode = config.hooks.isEmpty || forceEmptyState
        let newHooks = apis.map(makeHook(for:))
        config.hooks.append(contentsOf: newHooks)
        forceEmptyState = false

        let navigateTarget: TracerConfig.Hook? = (newHooks.count == 1 || isConfigOnly) ? newHooks.first : nil
        if let target = navigateTarget {
            selectedHookID = target.id
        }

        emit()

        if wasInEmptyMode || isConfigOnly {
            rebuildContent()
        } else if let target = navigateTarget {
            editorPane?.setHook(target)
        }

        if let target = navigateTarget {
            onHookAdded?(target.id)
        }
    }

    private func makeHook(for api: ResolvedApi) -> TracerConfig.Hook {
        TracerConfig.Hook(
            displayName: api.displayName,
            addressAnchor: api.anchor,
            kind: .function,
            code: defaultTracerCode(kind: .function, anchor: api.anchor, displayName: api.displayName)
        )
    }
}

private struct SearchInstallHint: Equatable {
    let name: String
    let globalAlias: String?
}

private func classifySearchError(_ error: any Swift.Error) -> (message: String, hint: SearchInstallHint?) {
    let message: String
    if case let Frida.Error.rpcError(rpcMessage, _) = error {
        message = rpcMessage
    } else {
        message = error.localizedDescription
    }
    let hint = message.contains("'frida-java-bridge'")
        ? SearchInstallHint(name: "frida-java-bridge", globalAlias: "Java")
        : nil
    return (message, hint)
}

private let scopeDropdownChanged: @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?
) -> Void = { widget, _, userData in
    guard let userData else { return }
    let rawSelf = UInt(bitPattern: userData)
    let rawWidget = UInt(bitPattern: widget)
    MainActor.assumeIsolated {
        let search = Unmanaged<TracerHookSearch>.fromOpaque(
            UnsafeMutableRawPointer(bitPattern: rawSelf)!
        ).takeUnretainedValue()
        let dropdownPtr = UnsafeMutablePointer<GtkDropDown>(
            OpaquePointer(bitPattern: rawWidget)!
        )
        search.handleScopeChanged(rawIndex: Int(gtk_drop_down_get_selected(dropdownPtr)))
    }
}

@MainActor
private final class TracerHookSearch {
    enum Layout {
        case emptyState
        case popover
    }

    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let onPick: ([TracerConfigEditor.ResolvedApi]) -> Void
    private let existingHookByAnchor: (AddressAnchor) -> TracerConfig.Hook?
    private let hooksProvider: () -> [TracerConfig.Hook]
    private let onView: (TracerConfig.Hook) -> Void

    private let entry: Entry
    private let scopeDropdown: DropDown
    private let spinner: Spinner
    private let statusRow: Box
    private let status: Label
    private let addAllButton: Button
    private let installBanner: Box
    private let installBannerLabel: Label
    private let installButton: Button
    private let listBox: ListBox
    private let scroll: ScrolledWindow
    private var heroRevealer: Revealer?

    private var scope: TracerTargetScope = .function
    private var results: [TracerConfigEditor.ResolvedApi] = []
    private var hookAddresses: [UUID: UInt64] = [:]
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pendingInstallHint: SearchInstallHint?
    private var installTask: Task<Void, Never>?

    init(
        engine: Engine?,
        sessionID: UUID,
        layout: Layout,
        hasExistingHooks: Bool = false,
        existingHookByAnchor: @escaping (AddressAnchor) -> TracerConfig.Hook?,
        hooksProvider: @escaping () -> [TracerConfig.Hook],
        onPick: @escaping ([TracerConfigEditor.ResolvedApi]) -> Void,
        onView: @escaping (TracerConfig.Hook) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.onPick = onPick
        self.existingHookByAnchor = existingHookByAnchor
        self.hooksProvider = hooksProvider
        self.onView = onView

        widget = Box(orientation: .vertical, spacing: 12)
        widget.hexpand = true
        widget.vexpand = true
        switch layout {
        case .emptyState:
            widget.valign = .center
            widget.halign = .center
            widget.setSizeRequest(width: 480, height: -1)
            widget.marginStart = 24
            widget.marginEnd = 24
            widget.marginTop = 24
            widget.marginBottom = 24
        case .popover:
            widget.setSizeRequest(width: 420, height: 360)
            widget.marginStart = 10
            widget.marginEnd = 10
            widget.marginTop = 10
            widget.marginBottom = 10
        }

        if layout == .emptyState {
            let hero = Box(orientation: .vertical, spacing: 12)
            hero.halign = .center

            let icon = Image(iconName: "edit-find-symbolic")
            icon.set(pixelSize: 48)
            icon.add(cssClass: "dim-label")
            hero.append(child: icon)

            let title = Label(str: hasExistingHooks
                ? "Trace another function"
                : "Start tracing functions")
            title.add(cssClass: "title-3")
            hero.append(child: title)

            let subtitleLabel = Label(str: hasExistingHooks
                ? "Search for another function to trace, or select a hook to edit it."
                : "Search for a function to start tracing it.")
            subtitleLabel.add(cssClass: "dim-label")
            subtitleLabel.wrap = true
            subtitleLabel.justify = .center
            hero.append(child: subtitleLabel)

            let revealer = Revealer()
            revealer.transitionType = .slideUp
            revealer.transitionDuration = 200
            revealer.revealChild = true
            revealer.set(child: hero)
            widget.append(child: revealer)
            heroRevealer = revealer
        }

        let attached = engine?.node(forSessionID: sessionID) != nil

        let queryRow = Box(orientation: .horizontal, spacing: 6)
        queryRow.hexpand = true
        entry = Entry()
        entry.hexpand = true
        entry.placeholderText = TracerTargetScope.function.placeholder
        entry.sensitive = attached
        queryRow.append(child: entry)

        scopeDropdown = Self.makeScopeDropdown()
        scopeDropdown.valign = .center
        scopeDropdown.tooltipText = "Target scope"
        queryRow.append(child: scopeDropdown)

        spinner = makeSpinner()
        spinner.visible = false
        spinner.valign = .center
        queryRow.append(child: spinner)
        widget.append(child: queryRow)

        statusRow = Box(orientation: .horizontal, spacing: 6)
        statusRow.hexpand = true
        status = Label(str: attached ? "Type a query to search." : "Attach to a process to search APIs.")
        status.add(cssClass: "dim-label")
        status.add(cssClass: "caption")
        status.halign = .start
        status.hexpand = true
        statusRow.append(child: status)

        addAllButton = Button(label: "Add All")
        addAllButton.add(cssClass: "flat")
        addAllButton.add(cssClass: "caption")
        addAllButton.tooltipText = "Add all results as hooks"
        addAllButton.visible = false
        statusRow.append(child: addAllButton)
        widget.append(child: statusRow)

        installBanner = Box(orientation: .horizontal, spacing: 10)
        installBanner.add(cssClass: "luma-install-banner")
        installBanner.marginTop = 4
        installBanner.marginBottom = 4
        installBanner.visible = false

        let bannerIcon = Image(iconName: "package-x-generic-symbolic")
        bannerIcon.set(pixelSize: 16)
        bannerIcon.valign = .center
        bannerIcon.marginStart = 12
        installBanner.append(child: bannerIcon)

        installBannerLabel = Label(str: "")
        installBannerLabel.add(cssClass: "caption")
        installBannerLabel.halign = .start
        installBannerLabel.hexpand = true
        installBannerLabel.wrap = true
        installBannerLabel.xalign = 0
        installBannerLabel.marginTop = 8
        installBannerLabel.marginBottom = 8
        installBanner.append(child: installBannerLabel)

        installButton = Button(label: "Install")
        installButton.add(cssClass: "suggested-action")
        installButton.valign = .center
        installButton.marginEnd = 8
        installButton.marginTop = 6
        installButton.marginBottom = 6
        installBanner.append(child: installButton)
        widget.append(child: installBanner)

        listBox = ListBox()
        listBox.selectionMode = .none
        listBox.add(cssClass: "boxed-list")

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        if layout == .emptyState {
            scroll.setSizeRequest(width: -1, height: 280)
        }
        scroll.set(child: listBox)
        scroll.visible = false
        widget.append(child: scroll)

        entry.onChanged { [anchor = self] _ in
            MainActor.assumeIsolated {
                anchor.updateHeroVisibility()
                anchor.scheduleSearch()
            }
        }
        entry.onActivate { [anchor = self] _ in
            MainActor.assumeIsolated { anchor.runSearchNow() }
        }

        let selfContext = Unmanaged.passUnretained(self).toOpaque()
        g_signal_connect_data(
            scopeDropdown.drop_down_ptr,
            "notify::selected",
            unsafeBitCast(scopeDropdownChanged, to: GCallback.self),
            selfContext,
            nil,
            GConnectFlags(rawValue: 0)
        )

        addAllButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let toAdd = self.results.filter { self.existingHook(for: $0) == nil }
                self.onPick(toAdd)
            }
        }

        installButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installPendingPackage()
            }
        }

        if attached {
            _ = entry.grabFocus()
        }
    }

    private static func makeScopeDropdown() -> DropDown {
        let labels = TracerTargetScope.allCases.map { $0.label }
        let cStrings = labels.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        ptrs.append(nil)
        let widgetPtr = ptrs.withUnsafeBufferPointer { buf in
            gtk_drop_down_new_from_strings(buf.baseAddress)
        }!
        g_object_ref_sink(UnsafeMutableRawPointer(widgetPtr))
        return DropDown(raw: UnsafeMutableRawPointer(widgetPtr))
    }

    fileprivate func handleScopeChanged(rawIndex: Int) {
        let cases = TracerTargetScope.allCases
        guard rawIndex >= 0, rawIndex < cases.count else { return }
        let newScope = cases[rawIndex]
        guard newScope != scope else { return }
        scope = newScope
        entry.placeholderText = newScope.placeholder
        debounceTask?.cancel()
        searchTask?.cancel()
        results = []
        rebuildResults()
        let query = entry.text ?? ""
        if query.isEmpty {
            setSearchStatus("Type a query to search.")
        } else {
            scheduleSearch()
        }
    }

    func refreshAttached() {
        let attached = engine?.node(forSessionID: sessionID) != nil
        entry.sensitive = attached
        if !attached {
            setSearchStatus("Attach to a process to search APIs.")
        } else if (entry.text ?? "").isEmpty {
            setSearchStatus("Type a query to search.")
        }
    }

    fileprivate func updateHeroVisibility() {
        let empty = (entry.text ?? "").isEmpty
        heroRevealer?.revealChild = empty
        widget.valign = empty ? .center : .fill
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        let query = entry.text ?? ""
        if query.isEmpty {
            searchTask?.cancel()
            results = []
            rebuildResults()
            setSearchStatus("Type a query to search.")
            return
        }
        debounceTask = Task { @MainActor [anchor = self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            anchor.performSearch(query: query)
        }
    }

    private func runSearchNow() {
        debounceTask?.cancel()
        let query = entry.text ?? ""
        guard !query.isEmpty else { return }
        performSearch(query: query)
    }

    private func existingHook(for api: TracerConfigEditor.ResolvedApi) -> TracerConfig.Hook? {
        if let exact = existingHookByAnchor(api.anchor) {
            return exact
        }
        return hooksProvider().first(where: { hookAddresses[$0.id] == api.address })
    }

    private func refreshHookAddresses() async {
        guard let node = engine?.node(forSessionID: sessionID) else {
            hookAddresses = [:]
            return
        }
        var resolved: [UUID: UInt64] = [:]
        for hook in hooksProvider() {
            if let address = try? await node.resolve(hook.addressAnchor) {
                resolved[hook.id] = address
            }
        }
        hookAddresses = resolved
    }

    private func performSearch(query: String) {
        guard let node = engine?.node(forSessionID: sessionID) else {
            setSearchStatus("Attach to a process to search APIs.")
            return
        }
        searchTask?.cancel()
        spinner.visible = true
        setSearchStatus("Searching\u{2026}")
        searchTask = Task { @MainActor [anchor = self] in
            defer {
                anchor.spinner.visible = false
            }
            do {
                let arr = try await node.resolveTargets(scope: anchor.scope.rawValue, query: query)
                if Task.isCancelled { return }
                var decoded: [TracerConfigEditor.ResolvedApi] = []
                decoded.reserveCapacity(arr.count)
                for obj in arr {
                    guard let displayName = obj["displayName"] as? String,
                        let addressStr = obj["address"] as? String,
                        let address = try? parseAgentHexAddress(addressStr),
                        let anchorObj = obj["anchor"] as? [String: Any],
                        let parsedAnchor = try? AddressAnchor.fromJSON(anchorObj)
                    else { continue }
                    let detail = obj["detail"] as? String
                    decoded.append(
                        TracerConfigEditor.ResolvedApi(
                            displayName: displayName,
                            detail: detail,
                            address: address,
                            anchor: parsedAnchor
                        )
                    )
                }
                anchor.results = decoded
                await anchor.refreshHookAddresses()
                if Task.isCancelled { return }
                anchor.rebuildResults()
                anchor.setSearchStatus(
                    decoded.isEmpty
                        ? "No results. Try another pattern."
                        : "\(decoded.count) result\(decoded.count == 1 ? "" : "s")"
                )
            } catch is CancellationError {
                return
            } catch {
                anchor.results = []
                anchor.rebuildResults()
                let classified = classifySearchError(error)
                anchor.setSearchStatus(classified.message, hint: classified.hint)
            }
        }
    }

    private func setSearchStatus(_ message: String, hint: SearchInstallHint? = nil) {
        pendingInstallHint = hint

        if let hint {
            installBannerLabel.label = message
            if installTask == nil {
                installButton.label = "Install"
                installButton.tooltipText = "Install \(hint.name)"
                installButton.sensitive = true
            }
            installBanner.visible = true
            statusRow.visible = false
        } else {
            status.label = message
            statusRow.visible = true
            installBanner.visible = false
        }
    }

    private func installPendingPackage() {
        guard let hint = pendingInstallHint,
            let engine,
            installTask == nil
        else { return }

        installButton.label = "Installing\u{2026}"
        installButton.tooltipText = "Installing \(hint.name)"
        installButton.sensitive = false
        installTask = Task { @MainActor [anchor = self] in
            defer {
                anchor.installTask = nil
            }
            do {
                _ = try await engine.installPackage(name: hint.name, globalAlias: hint.globalAlias)
                anchor.setSearchStatus("Searching\u{2026}")
                anchor.runSearchNow()
            } catch {
                let classified = classifySearchError(error)
                anchor.installButton.label = "Install"
                anchor.installButton.tooltipText = "Install \(hint.name)"
                anchor.installButton.sensitive = true
                anchor.setSearchStatus(classified.message, hint: classified.hint)
            }
        }
    }

    private func rebuildResults() {
        let restoreEntryFocus = entryHasFocus()

        while let child = listBox.firstChild {
            listBox.remove(child: child)
        }

        scroll.visible = !results.isEmpty
        addAllButton.visible = !results.isEmpty

        for (idx, api) in results.enumerated() {
            let row = ListBoxRow()
            let inner = Box(orientation: .horizontal, spacing: 8)
            inner.marginStart = 10
            inner.marginEnd = 10
            inner.marginTop = 6
            inner.marginBottom = 6

            let textColumn = Box(orientation: .vertical, spacing: 2)
            textColumn.hexpand = true

            let title = Label(str: api.displayName)
            title.halign = .start
            textColumn.append(child: title)

            let subtitleText: String
            if let detail = api.detail {
                subtitleText = "\(detail)  •  " + String(format: "0x%llx", api.address)
            } else {
                subtitleText = String(format: "0x%llx", api.address)
            }
            let subtitle = Label(str: subtitleText)
            subtitle.halign = .start
            subtitle.add(cssClass: "caption")
            subtitle.add(cssClass: "dim-label")
            subtitle.add(cssClass: "monospace")
            textColumn.append(child: subtitle)

            inner.append(child: textColumn)

            let existing = existingHook(for: api)
            let actionButton = Button(label: existing != nil ? "View Handler" : "Add")
            actionButton.add(cssClass: "flat")
            actionButton.valign = .center
            let capturedIdx = idx
            actionButton.onClicked { [anchor = self] _ in
                MainActor.assumeIsolated {
                    guard capturedIdx < anchor.results.count else { return }
                    let api = anchor.results[capturedIdx]
                    if let existing = anchor.existingHook(for: api) {
                        anchor.onView(existing)
                    } else {
                        anchor.onPick([api])
                    }
                }
            }
            inner.append(child: actionButton)

            row.set(child: inner)
            listBox.append(child: row)
        }

        if restoreEntryFocus {
            _ = entry.grabFocus()
        }
    }

    private func entryHasFocus() -> Bool {
        guard let focused = entry.root?.focus else { return false }
        return focused.widget_ptr == entry.widget_ptr
    }
}


// MARK: - Editor pane (left side in SwiftUI expanded layout)

@MainActor
final class EditorPane {
    let widget: Box

    private weak var engine: Engine?
    private let onSave: (TracerConfig.Hook) -> Void
    let onITraceChanged: ((UUID, ITraceArming?) -> Void)?
    var onDirtyChanged: ((Bool) -> Void)?

    private var hook: TracerConfig.Hook?
    private var draftCode: String = ""
    private(set) var isDirty: Bool = false

    private let showToolbar: Bool
    private var toolbar: Box?
    private var titleLabel: Label?
    private var subtitleLabel: Label?
    private var enabledSwitch: Switch?
    private var itracePill: TracerITracePill?
    private var dirtyIndicator: Image?
    let saveButton: Button?
    private let editorHost: Box
    private let placeholder: Label
    private let monaco: MonacoEditor
    private let initialCaptured: Int

    init(
        engine: Engine?,
        hook: TracerConfig.Hook?,
        sharedEditor: MonacoEditor,
        showToolbar: Bool = true,
        captured: Int = 0,
        onSave: @escaping (TracerConfig.Hook) -> Void,
        onITraceChanged: ((UUID, ITraceArming?) -> Void)? = nil
    ) {
        self.engine = engine
        self.hook = hook
        self.monaco = sharedEditor
        self.showToolbar = showToolbar
        self.onSave = onSave
        self.onITraceChanged = onITraceChanged
        self.initialCaptured = captured

        widget = Box(orientation: .vertical, spacing: showToolbar ? 8 : 0)
        widget.hexpand = true
        widget.vexpand = true
        if showToolbar {
            widget.marginStart = 12
            widget.marginEnd = 12
            widget.marginTop = 12
            widget.marginBottom = 12
        }

        if showToolbar {
            let toolbar = Box(orientation: .horizontal, spacing: 8)
            toolbar.hexpand = true
            self.toolbar = toolbar

            let titleColumn = Box(orientation: .vertical, spacing: 0)
            titleColumn.hexpand = true
            let titleLabel = Label(str: "")
            titleLabel.halign = .start
            titleLabel.add(cssClass: "title-4")
            self.titleLabel = titleLabel
            titleColumn.append(child: titleLabel)
            let subtitleLabel = Label(str: "")
            subtitleLabel.halign = .start
            subtitleLabel.add(cssClass: "caption")
            subtitleLabel.add(cssClass: "dim-label")
            subtitleLabel.add(cssClass: "monospace")
            self.subtitleLabel = subtitleLabel
            titleColumn.append(child: subtitleLabel)
            toolbar.append(child: titleColumn)

            let enabledRow = Box(orientation: .horizontal, spacing: 6)
            let enabledSwitch = Switch()
            enabledSwitch.valign = .center
            self.enabledSwitch = enabledSwitch
            enabledRow.append(child: enabledSwitch)
            let enabledLabel = Label(str: "Enabled")
            enabledRow.append(child: enabledLabel)
            toolbar.append(child: enabledRow)

            let pill = TracerITracePill()
            self.itracePill = pill
            toolbar.append(child: pill.widget)

            let dirtyIndicator = Image(iconName: "media-record-symbolic")
            dirtyIndicator.tooltipText = "Unsaved changes"
            dirtyIndicator.visible = false
            self.dirtyIndicator = dirtyIndicator
            toolbar.append(child: dirtyIndicator)

            let saveButton = Button(label: "Save")
            saveButton.add(cssClass: "suggested-action")
            saveButton.sensitive = false
            saveButton.tooltipText = "Save current hook script"
            self.saveButton = saveButton
            toolbar.append(child: saveButton)

            widget.append(child: toolbar)
        } else {
            self.toolbar = nil
            self.titleLabel = nil
            self.subtitleLabel = nil
            self.enabledSwitch = nil
            self.itracePill = nil
            self.dirtyIndicator = nil
            self.saveButton = nil
        }

        editorHost = Box(orientation: .vertical, spacing: 0)
        editorHost.hexpand = true
        editorHost.vexpand = true
        editorHost.setSizeRequest(width: -1, height: 320)

        widget.append(child: editorHost)

        placeholder = Label(str: "Select a hook to edit its script.")
        placeholder.add(cssClass: "dim-label")
        placeholder.hexpand = true
        placeholder.vexpand = true
        placeholder.visible = false
        widget.append(child: placeholder)

        monaco.onTextChanged = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.draftCode = text
                self.recomputeDirty()
            }
        }

        monaco.onAccelerator = { [weak self] keyval, modifiers in
            MainActor.assumeIsolated {
                guard let self else { return false }
                let mods = Gdk.ModifierType(rawValue: UInt32(truncatingIfNeeded: modifiers))
                let isSave = keyval == UInt(UInt8(ascii: "s")) && mods == .controlMask
                guard isSave else { return false }
                if self.isDirty { self.commit() }
                return true
            }
        }

        if showToolbar {
            enabledSwitch?.onStateSet { [weak self] _, _ in
                MainActor.assumeIsolated { self?.recomputeDirty() }
                return false
            }
            saveButton?.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.commit() }
            }
            itracePill?.onArmingChanged = { [weak self] arming in
                guard let self, let id = self.hook?.id else { return }
                self.hook?.itraceArming = arming
                self.onITraceChanged?(id, arming)
            }
        }

        sharedEditor.installInto(editorHost)
        sharedEditor.setText(hook?.code ?? "")

        applyHookToUI()
    }

    func setHook(_ newHook: TracerConfig.Hook?) {
        self.hook = newHook
        applyHookToUI()
    }

    func refreshHookMetadata(_ newHook: TracerConfig.Hook) {
        hook = newHook
        titleLabel?.label = newHook.displayName.isEmpty ? "(unnamed)" : newHook.displayName
        subtitleLabel?.label = newHook.addressAnchor.displayString
        itracePill?.widget.visible = newHook.kind == .function
        itracePill?.update(arming: newHook.itraceArming, captured: initialCaptured)
        recomputeDirty()
    }

    private func applyHookToUI() {
        if let hook {
            titleLabel?.label = hook.displayName.isEmpty ? "(unnamed)" : hook.displayName
            subtitleLabel?.label = hook.addressAnchor.displayString
            enabledSwitch?.active = hook.state == .enabled
            itracePill?.widget.visible = hook.kind == .function
            itracePill?.update(arming: hook.itraceArming, captured: initialCaptured)
            draftCode = hook.code
            monaco.setText(hook.code)
            isDirty = false
            saveButton?.sensitive = false
            dirtyIndicator?.visible = false
            onDirtyChanged?(false)
            toolbar?.visible = true
            editorHost.visible = true
            placeholder.visible = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                self.monaco.focus()
            }
        } else {
            toolbar?.visible = false
            editorHost.visible = false
            placeholder.visible = true
        }
    }

    func refreshITrace(arming: ITraceArming?, captured: Int) {
        itracePill?.update(arming: arming, captured: captured)
    }

    private func recomputeDirty() {
        guard let hook else {
            isDirty = false
            saveButton?.sensitive = false
            dirtyIndicator?.visible = false
            onDirtyChanged?(false)
            return
        }
        if showToolbar {
            let switchState: TracerConfig.Hook.State = (enabledSwitch?.active ?? (hook.state == .enabled)) ? .enabled : .disabled
            isDirty =
                draftCode != hook.code
                || switchState != hook.state
        } else {
            isDirty = draftCode != hook.code
        }
        saveButton?.sensitive = isDirty
        dirtyIndicator?.visible = isDirty
        onDirtyChanged?(isDirty)
    }

    func commit() {
        guard var hook else { return }
        hook.updateCode(draftCode)
        if showToolbar, let active = enabledSwitch?.active {
            hook.state = active ? .enabled : .disabled
        }
        self.hook = hook
        isDirty = false
        saveButton?.sensitive = false
        dirtyIndicator?.visible = false
        onDirtyChanged?(false)
        onSave(hook)
    }
}
