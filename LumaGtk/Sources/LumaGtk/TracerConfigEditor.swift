import CGtk
import Foundation
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

    fileprivate var config: TracerConfig
    private var selectedHookID: UUID?
    private var preferredLayoutMode: LayoutMode = .compact
    private var lastKnownWidth: Int = 0

    private let contentSlot: Box
    private var hooksList: HooksList?
    private var editorPane: EditorPane?
    private var emptyStateSearch: TracerHookSearch?
    private var popoverSearch: TracerHookSearch?
    private var addPopover: Popover?

    enum LayoutMode {
        case compact
        case expanded
    }

    private var effectiveLayoutMode: LayoutMode {
        if lastKnownWidth > 0 && lastKnownWidth < 800 {
            return .compact
        }
        return preferredLayoutMode
    }

    init(
        engine: Engine,
        sessionID: UUID,
        config: TracerConfig,
        tracerEditor: MonacoEditor,
        apply: @escaping (Data) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.config = config
        self.sharedEditor = tracerEditor
        self.apply = apply
        self.selectedHookID = config.hooks.first?.id

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        contentSlot = Box(orientation: .vertical, spacing: 0)
        contentSlot.hexpand = true
        contentSlot.vexpand = true

        let sensorPtr = gtk_drawing_area_new()!
        gtk_widget_set_hexpand(sensorPtr, 1)
        gtk_widget_set_size_request(sensorPtr, -1, 0)
        let context = Unmanaged.passUnretained(self).toOpaque()
        g_signal_connect_data(
            sensorPtr,
            "resize",
            unsafeBitCast(widthSensorResized, to: GCallback.self),
            context,
            nil,
            GConnectFlags(rawValue: 0)
        )
        widget.append(child: WidgetRef(raw: UnsafeMutableRawPointer(sensorPtr)))
        widget.append(child: contentSlot)

        rebuildContent()
    }

    func update(config newConfig: TracerConfig) {
        self.config = newConfig
        if let id = selectedHookID, !newConfig.hooks.contains(where: { $0.id == id }) {
            selectedHookID = newConfig.hooks.first?.id
        } else if selectedHookID == nil {
            selectedHookID = newConfig.hooks.first?.id
        }
        rebuildContent()
    }

    func selectHook(id: UUID) {
        guard config.hooks.contains(where: { $0.id == id }) else { return }
        guard id != selectedHookID else { return }
        selectedHookID = id
        rebuildContent()
    }

    private func rebuildContent() {
        var child = contentSlot.firstChild
        while let cur = child {
            child = cur.nextSibling
            contentSlot.remove(child: cur)
        }
        hooksList = nil
        editorPane = nil
        emptyStateSearch = nil
        dismissAddPopover()
        dismissUnsavedChangesDialog()

        if config.hooks.isEmpty {
            let search = TracerHookSearch(
                engine: engine,
                sessionID: sessionID,
                layout: .emptyState,
                onPick: { [weak self] api in
                    self?.appendHook(for: api)
                }
            )
            emptyStateSearch = search
            contentSlot.append(child: search.widget)
            return
        }

        switch effectiveLayoutMode {
        case .compact:
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

            let toolbar = buildCompactToolbar()
            contentSlot.append(child: toolbar)
            let separator = Separator(orientation: .horizontal)
            contentSlot.append(child: separator)
            contentSlot.append(child: editorPane.widget)

        case .expanded:
            let editorPane = EditorPane(
                engine: engine,
                hook: selectedHook,
                sharedEditor: sharedEditor,
                showToolbar: true,
                onSave: { [weak self] updated in
                    self?.saveHook(updated)
                }
            )
            self.editorPane = editorPane

            let paned = Paned(orientation: .horizontal)
            paned.resizeStartChild = true
            paned.resizeEndChild = false
            paned.shrinkStartChild = false
            paned.shrinkEndChild = false
            paned.hexpand = true
            paned.vexpand = true
            let sashPosition = max(400, lastKnownWidth - 320)
            paned.position = sashPosition

            let hooksList = HooksList(
                hooks: config.hooks,
                selectedID: selectedHookID,
                onSelect: { [weak self] id in
                    self?.handleSelect(id)
                },
                onToggleEnabled: { [weak self] id, enabled in
                    self?.toggleEnabled(id: id, enabled: enabled)
                },
                onDelete: { [weak self] id in
                    self?.deleteHook(id: id)
                },
                onDeleteSelected: { [weak self] ids in
                    self?.deleteHooks(ids: ids)
                },
                onAddRequested: { [weak self] anchor in
                    self?.presentAddPopover(anchor: anchor)
                },
                onLayoutToggle: { [weak self] in
                    self?.setLayoutMode(.compact)
                },
                attached: engine?.node(forSessionID: sessionID) != nil
            )
            self.hooksList = hooksList

            paned.startChild = WidgetRef(editorPane.widget)
            paned.endChild = WidgetRef(hooksList.widget)
            contentSlot.append(child: paned)
        }
    }

    private func setLayoutMode(_ mode: LayoutMode) {
        guard mode != preferredLayoutMode else { return }
        preferredLayoutMode = mode
        scheduleRebuild()
    }

    private var rebuildScheduled = false

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor in
            self.rebuildScheduled = false
            self.rebuildContent()
        }
    }

    private func buildCompactToolbar() -> Box {
        let toolbar = Box(orientation: .horizontal, spacing: 8)
        toolbar.marginStart = 12
        toolbar.marginEnd = 12
        toolbar.marginTop = 8
        toolbar.marginBottom = 8

        if config.hooks.count > 1 {
            let names = config.hooks.map { $0.displayName.isEmpty ? "(unnamed)" : $0.displayName }
            let cStrings = names.map { strdup($0) }
            var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
            ptrs.append(nil)
            let dropdownPtr = ptrs.withUnsafeBufferPointer { buf in
                gtk_drop_down_new_from_strings(buf.baseAddress)
            }!
            let dropdown = DropDown(raw: UnsafeMutableRawPointer(dropdownPtr))
            for ptr in cStrings { free(ptr) }
            if let selID = selectedHookID,
                let idx = config.hooks.firstIndex(where: { $0.id == selID })
            {
                dropdown.selected = idx
            }
            let context = Unmanaged.passUnretained(self).toOpaque()
            g_signal_connect_data(
                dropdownPtr,
                "notify::selected",
                unsafeBitCast(compactDropdownChanged, to: GCallback.self),
                context,
                nil,
                GConnectFlags(rawValue: 0)
            )
            toolbar.append(child: dropdown)
        } else if let hook = config.hooks.first {
            let title = Label(str: hook.displayName)
            title.add(cssClass: "heading")
            toolbar.append(child: title)
        }

        if let hook = selectedHook {
            let enabledSwitch = Switch()
            enabledSwitch.active = hook.isEnabled
            enabledSwitch.valign = .center
            enabledSwitch.onStateSet { [weak self] _, state in
                MainActor.assumeIsolated {
                    guard let self, let id = self.selectedHookID else { return }
                    self.toggleEnabled(id: id, enabled: state)
                }
                return false
            }
            toolbar.append(child: enabledSwitch)

            let isFunctionHook = hook.code.contains("onEnter") || hook.code.contains("onLeave")
            if isFunctionHook {
                let itraceSwitch = Switch()
                itraceSwitch.active = hook.itraceEnabled
                itraceSwitch.valign = .center
                itraceSwitch.tooltipText = "Capture instruction trace for each call"
                itraceSwitch.onStateSet { [weak self] _, state in
                    MainActor.assumeIsolated {
                        guard let self, let id = self.selectedHookID else { return }
                        self.toggleITrace(id: id, enabled: state)
                    }
                    return false
                }
                let itraceLabel = Label(str: "ITrace")
                itraceLabel.add(cssClass: "dim-label")
                toolbar.append(child: itraceSwitch)
                toolbar.append(child: itraceLabel)
            }
        }

        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        toolbar.append(child: spacer)

        if let editorPane {
            let dirtyIcon = Image(iconName: "media-record-symbolic")
            dirtyIcon.tooltipText = "Unsaved changes"
            dirtyIcon.visible = editorPane.isDirty
            toolbar.append(child: dirtyIcon)

            let saveButton = Button(label: "Save")
            saveButton.add(cssClass: "suggested-action")
            saveButton.sensitive = editorPane.isDirty
            saveButton.tooltipText = "Save current hook script"
            saveButton.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.editorPane?.commit() }
            }
            editorPane.onDirtyChanged = { [weak dirtyIcon, weak saveButton] dirty in
                dirtyIcon?.visible = dirty
                saveButton?.sensitive = dirty
            }
            toolbar.append(child: saveButton)
        }

        let attached = engine?.node(forSessionID: sessionID) != nil
        let addButton = Button()
        let addIcon = Image(iconName: "list-add-symbolic")
        addButton.set(child: addIcon)
        addButton.add(cssClass: "flat")
        addButton.tooltipText = attached ? "Add hooks by searching functions" : "Attach to a process to search APIs."
        addButton.sensitive = attached
        addButton.onClicked { [weak self, weak addButton] _ in
            MainActor.assumeIsolated {
                guard let self, let addButton, let ref = WidgetRef(addButton.widget_ptr) else { return }
                self.presentAddPopover(anchor: ref)
            }
        }
        toolbar.append(child: addButton)

        if selectedHook != nil {
            let deleteButton = Button()
            let deleteIcon = Image(iconName: "user-trash-symbolic")
            deleteButton.set(child: deleteIcon)
            deleteButton.add(cssClass: "flat")
            deleteButton.add(cssClass: "error")
            deleteButton.tooltipText = "Delete selected hook"
            deleteButton.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let id = self.selectedHookID else { return }
                    self.deleteHook(id: id)
                }
            }
            toolbar.append(child: deleteButton)
        }

        if !(lastKnownWidth > 0 && lastKnownWidth < 800) {
            let expandButton = Button()
            let expandIcon = Image(iconName: "view-dual-symbolic")
            expandButton.set(child: expandIcon)
            expandButton.add(cssClass: "flat")
            expandButton.tooltipText = "Show hooks list"
            expandButton.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.setLayoutMode(.expanded) }
            }
            toolbar.append(child: expandButton)
        }

        return toolbar
    }

    private var selectedHook: TracerConfig.Hook? {
        guard let id = selectedHookID else { return nil }
        return config.hooks.first(where: { $0.id == id })
    }

    fileprivate func handleSelect(_ id: UUID?) {
        guard id != selectedHookID else { return }

        if let editorPane, editorPane.isDirty {
            pendingSelectionID = id
            showUnsavedChangesDialog()
            return
        }

        selectedHookID = id
        editorPane?.setHook(selectedHook)
    }

    private var pendingSelectionID: UUID?
    private var unsavedChangesPopover: Popover?

    private func showUnsavedChangesDialog() {
        dismissUnsavedChangesDialog()

        guard let editorPane else { return }

        let popover = Popover()
        popover.autohide = true

        let content = Box(orientation: .vertical, spacing: 12)
        content.marginStart = 16
        content.marginEnd = 16
        content.marginTop = 16
        content.marginBottom = 16
        content.setSizeRequest(width: 280, height: -1)

        let title = Label(str: "Unsaved Changes")
        title.add(cssClass: "title-4")
        title.halign = .start
        content.append(child: title)

        let message = Label(str: "You have unsaved changes to this hook\u{2019}s script.")
        message.wrap = true
        message.halign = .start
        message.add(cssClass: "dim-label")
        content.append(child: message)

        let buttons = Box(orientation: .horizontal, spacing: 8)
        buttons.halign = .end

        let cancelButton = Button(label: "Cancel")
        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSelectionID = nil
                self.dismissUnsavedChangesDialog()
                self.hooksList?.restoreSelection(id: self.selectedHookID)
            }
        }
        buttons.append(child: cancelButton)

        let discardButton = Button(label: "Discard")
        discardButton.add(cssClass: "destructive-action")
        discardButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dismissUnsavedChangesDialog()
                self.applyPendingSelection()
            }
        }
        buttons.append(child: discardButton)

        let saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.editorPane?.commit()
                self.dismissUnsavedChangesDialog()
                self.applyPendingSelection()
            }
        }
        buttons.append(child: saveButton)

        content.append(child: buttons)
        popover.set(child: content)
        let anchor: WidgetProtocol = editorPane.saveButton ?? editorPane.widget
        popover.set(parent: WidgetRef(anchor))
        unsavedChangesPopover = popover
        popover.popup()
    }

    private func dismissUnsavedChangesDialog() {
        if let popover = unsavedChangesPopover {
            popover.popdown()
            popover.unparent()
        }
        unsavedChangesPopover = nil
    }

    private func applyPendingSelection() {
        let id = pendingSelectionID
        pendingSelectionID = nil
        selectedHookID = id
        editorPane?.setHook(selectedHook)
    }

    private func toggleEnabled(id: UUID, enabled: Bool) {
        guard let idx = config.hooks.firstIndex(where: { $0.id == id }) else { return }
        config.hooks[idx].isEnabled = enabled
        emit()
    }

    private func toggleITrace(id: UUID, enabled: Bool) {
        guard let idx = config.hooks.firstIndex(where: { $0.id == id }) else { return }
        config.hooks[idx].itraceEnabled = enabled
        emit()
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
        if config.hooks.count <= 1 {
            preferredLayoutMode = .compact
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
            onPick: { [weak self] api in
                self?.appendHook(for: api)
                self?.dismissAddPopover()
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

    fileprivate func appendHook(for api: ResolvedApi) {
        let hadMultipleHooks = config.hooks.count > 1
        let stub = defaultTracerNativeStub.replacingOccurrences(
            of: "CALL(args[0]",
            with: "\(api.displayName)(args[0]"
        )
        let hook = TracerConfig.Hook(
            displayName: api.displayName,
            addressAnchor: api.anchor,
            isEnabled: true,
            code: stub
        )
        config.hooks.append(hook)
        selectedHookID = hook.id
        if !hadMultipleHooks && config.hooks.count > 1 {
            preferredLayoutMode = .expanded
        }
        emit()
        rebuildContent()
    }
}

private let compactDropdownChanged: @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?
) -> Void = { widget, _, userData in
    guard let userData else { return }
    let rawSelf = UInt(bitPattern: userData)
    let rawWidget = UInt(bitPattern: widget)
    MainActor.assumeIsolated {
        let editor = Unmanaged<TracerConfigEditor>.fromOpaque(
            UnsafeMutableRawPointer(bitPattern: rawSelf)!
        ).takeUnretainedValue()
        let dropdownPtr = UnsafeMutablePointer<GtkDropDown>(
            OpaquePointer(bitPattern: rawWidget)!
        )
        let idx = Int(gtk_drop_down_get_selected(dropdownPtr))
        guard idx >= 0, idx < editor.config.hooks.count else { return }
        editor.handleSelect(editor.config.hooks[idx].id)
    }
}

private let widthSensorResized: @convention(c) (
    UnsafeMutableRawPointer,
    Int32,
    Int32,
    UnsafeMutableRawPointer?
) -> Void = { _, width, _, userData in
    guard let userData else { return }
    let rawSelf = UInt(bitPattern: userData)
    let w = Int(width)
    MainActor.assumeIsolated {
        let editor = Unmanaged<TracerConfigEditor>.fromOpaque(
            UnsafeMutableRawPointer(bitPattern: rawSelf)!
        ).takeUnretainedValue()
        editor.handleWidthChanged(w)
    }
}

extension TracerConfigEditor {
    fileprivate func handleWidthChanged(_ width: Int) {
        let oldEffective = effectiveLayoutMode
        lastKnownWidth = width
        let newEffective = effectiveLayoutMode
        if oldEffective != newEffective {
            scheduleRebuild()
        }
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
    private let onPick: (TracerConfigEditor.ResolvedApi) -> Void

    private let entry: Entry
    private let spinner: Spinner
    private let status: Label
    private let addAllButton: Button
    private let listBox: ListBox
    private let scroll: ScrolledWindow

    private var results: [TracerConfigEditor.ResolvedApi] = []
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(
        engine: Engine?,
        sessionID: UUID,
        layout: Layout,
        onPick: @escaping (TracerConfigEditor.ResolvedApi) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.onPick = onPick

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
            widget.setSizeRequest(width: 360, height: 360)
            widget.marginStart = 10
            widget.marginEnd = 10
            widget.marginTop = 10
            widget.marginBottom = 10
        }

        if layout == .emptyState {
            let icon = Image(iconName: "edit-find-symbolic")
            icon.set(pixelSize: 48)
            icon.add(cssClass: "dim-label")
            widget.append(child: icon)

            let title = Label(str: "Start tracing functions")
            title.add(cssClass: "title-3")
            widget.append(child: title)

            let subtitleLabel = Label(str: "Search for functions in the attached process and add them as hooks.")
            subtitleLabel.add(cssClass: "dim-label")
            subtitleLabel.wrap = true
            subtitleLabel.justify = .center
            widget.append(child: subtitleLabel)
        }

        let attached = engine?.node(forSessionID: sessionID) != nil

        let queryRow = Box(orientation: .horizontal, spacing: 6)
        queryRow.hexpand = true
        entry = Entry()
        entry.hexpand = true
        entry.placeholderText = "Search APIs (e.g. open, objc_msgSend)\u{2026}"
        entry.sensitive = attached
        queryRow.append(child: entry)

        spinner = Spinner()
        spinner.spinning = false
        spinner.valign = .center
        queryRow.append(child: spinner)
        widget.append(child: queryRow)

        let statusRow = Box(orientation: .horizontal, spacing: 6)
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
            MainActor.assumeIsolated { anchor.scheduleSearch() }
        }
        entry.onActivate { [anchor = self] _ in
            MainActor.assumeIsolated { anchor.runSearchNow() }
        }

        addAllButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for api in self.results {
                    self.onPick(api)
                }
            }
        }

        if attached {
            _ = entry.grabFocus()
        }
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        let query = entry.text ?? ""
        if query.isEmpty {
            searchTask?.cancel()
            results = []
            rebuildResults()
            status.label = "Type a query to search."
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

    private func performSearch(query: String) {
        guard let node = engine?.node(forSessionID: sessionID) else {
            status.label = "Attach to a process to search APIs."
            return
        }
        searchTask?.cancel()
        spinner.spinning = true
        spinner.start()
        status.label = "Searching\u{2026}"
        searchTask = Task { @MainActor [anchor = self] in
            defer {
                anchor.spinner.spinning = false
                anchor.spinner.stop()
            }
            do {
                let raw = try await node.script.exports.resolveTargets([
                    "scope": "function",
                    "query": query,
                ])
                if Task.isCancelled { return }
                guard let arr = raw as? [[String: Any]] else {
                    anchor.results = []
                    anchor.rebuildResults()
                    anchor.status.label = "resolveTargets: unexpected response"
                    return
                }
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
                anchor.rebuildResults()
                anchor.status.label =
                    decoded.isEmpty ? "No results. Try another pattern." : "\(decoded.count) result\(decoded.count == 1 ? "" : "s")"
            } catch is CancellationError {
                return
            } catch {
                anchor.results = []
                anchor.rebuildResults()
                anchor.status.label = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    private func rebuildResults() {
        var child = listBox.firstChild
        while let current = child {
            child = current.nextSibling
            listBox.remove(child: current)
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

            let addButton = Button(label: "Add")
            addButton.add(cssClass: "flat")
            addButton.valign = .center
            let capturedIdx = idx
            addButton.onClicked { [anchor = self] _ in
                MainActor.assumeIsolated {
                    guard capturedIdx < anchor.results.count else { return }
                    anchor.onPick(anchor.results[capturedIdx])
                }
            }
            inner.append(child: addButton)

            row.set(child: inner)
            listBox.append(child: row)
        }
    }
}

// MARK: - Hooks list (right pane in SwiftUI expanded layout)

@MainActor
private final class HooksList {
    let widget: Box

    private let listBox: ListBox
    private let deleteSelectedButton: Button
    private var rowToHookID: [Int: UUID] = [:]
    private var hookIDToRow: [UUID: ListBoxRow] = [:]
    private let onSelect: (UUID?) -> Void

    init(
        hooks: [TracerConfig.Hook],
        selectedID: UUID?,
        onSelect: @escaping (UUID?) -> Void,
        onToggleEnabled: @escaping (UUID, Bool) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onDeleteSelected: @escaping (Set<UUID>) -> Void,
        onAddRequested: @escaping (WidgetRef) -> Void,
        onLayoutToggle: @escaping () -> Void,
        attached: Bool
    ) {
        self.onSelect = onSelect

        widget = Box(orientation: .vertical, spacing: 6)
        widget.hexpand = true
        widget.vexpand = true
        widget.marginStart = 8
        widget.marginEnd = 8
        widget.marginTop = 8
        widget.marginBottom = 8
        widget.setSizeRequest(width: 280, height: -1)

        let header = Box(orientation: .horizontal, spacing: 6)
        let title = Label(str: "Hooks")
        title.add(cssClass: "heading")
        title.halign = .start
        title.hexpand = true
        header.append(child: title)

        deleteSelectedButton = Button()
        let deleteIcon = Image(iconName: "user-trash-symbolic")
        deleteSelectedButton.set(child: deleteIcon)
        deleteSelectedButton.add(cssClass: "flat")
        deleteSelectedButton.add(cssClass: "error")
        deleteSelectedButton.tooltipText = "Delete selected hooks"
        deleteSelectedButton.visible = false
        header.append(child: deleteSelectedButton)

        let addButton = Button()
        let addIcon = Image(iconName: "list-add-symbolic")
        addButton.set(child: addIcon)
        addButton.add(cssClass: "flat")
        addButton.tooltipText = attached ? "Add hooks by searching functions" : "Attach to a process to search APIs."
        addButton.sensitive = attached
        addButton.onClicked { [anchor = addButton] _ in
            MainActor.assumeIsolated {
                guard let ref = WidgetRef(anchor.widget_ptr) else { return }
                onAddRequested(ref)
            }
        }
        header.append(child: addButton)

        let compactButton = Button()
        let compactIcon = Image(iconName: "view-paged-symbolic")
        compactButton.set(child: compactIcon)
        compactButton.add(cssClass: "flat")
        compactButton.tooltipText = "Hide hooks list"
        compactButton.onClicked { _ in
            MainActor.assumeIsolated { onLayoutToggle() }
        }
        header.append(child: compactButton)

        widget.append(child: header)

        listBox = ListBox()
        listBox.selectionMode = .multiple
        listBox.add(cssClass: "boxed-list")

        var rowToHookID: [Int: UUID] = [:]
        var hookIDToRow: [UUID: ListBoxRow] = [:]
        var initialRow: ListBoxRow?

        for (idx, hook) in hooks.enumerated() {
            let row = ListBoxRow()
            let inner = Box(orientation: .horizontal, spacing: 8)
            inner.marginStart = 10
            inner.marginEnd = 10
            inner.marginTop = 6
            inner.marginBottom = 6

            let textColumn = Box(orientation: .vertical, spacing: 2)
            textColumn.hexpand = true

            let nameRow = Box(orientation: .horizontal, spacing: 6)
            let titleLabel = Label(str: hook.displayName.isEmpty ? "(unnamed)" : hook.displayName)
            titleLabel.halign = .start
            if !hook.isEnabled {
                titleLabel.add(cssClass: "dim-label")
            }
            nameRow.append(child: titleLabel)

            if hook.itraceEnabled {
                let badge = Label(str: "IT")
                badge.add(cssClass: "caption")
                badge.add(cssClass: "luma-itrace-badge")
                nameRow.append(child: badge)
            }
            textColumn.append(child: nameRow)

            if let sub = subtitle(for: hook) {
                let subtitleLabel = Label(str: sub)
                subtitleLabel.halign = .start
                subtitleLabel.add(cssClass: "caption")
                subtitleLabel.add(cssClass: "dim-label")
                textColumn.append(child: subtitleLabel)
            }

            inner.append(child: textColumn)

            let toggle = Switch()
            toggle.active = hook.isEnabled
            toggle.valign = .center
            let hookID = hook.id
            toggle.onStateSet { _, state in
                MainActor.assumeIsolated {
                    onToggleEnabled(hookID, state)
                }
                return false
            }
            inner.append(child: toggle)

            row.set(child: inner)
            listBox.append(child: row)
            rowToHookID[idx] = hook.id
            hookIDToRow[hook.id] = row
            if hook.id == selectedID {
                initialRow = row
            }
        }
        self.rowToHookID = rowToHookID
        self.hookIDToRow = hookIDToRow

        listBox.onSelectedRowsChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let selectedIDs = self.collectSelectedIDs()
                let count = selectedIDs.count
                self.deleteSelectedButton.visible = count > 1
                if count > 1 {
                    self.deleteSelectedButton.tooltipText = "Delete \(count) selected hooks"
                }
                if count == 1, let id = selectedIDs.first {
                    onSelect(id)
                } else if count == 0 {
                    onSelect(nil)
                }
            }
        }

        deleteSelectedButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ids = self.collectSelectedIDs()
                guard ids.count > 1 else { return }
                onDeleteSelected(ids)
            }
        }

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: listBox)
        widget.append(child: scroll)

        if let initialRow {
            listBox.select(row: initialRow)
        }

        let gesture = GestureClick()
        gesture.button = 3
        gesture.onPressed { [weak self, weak listBox] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self, let listBox else { return }
                let selectedIDs = self.collectSelectedIDs()
                if selectedIDs.count > 1 {
                    onDeleteSelected(selectedIDs)
                } else if let row = listBox.getRowAt(y: Int(y)) {
                    let idx = Int(row.index)
                    if let hookID = self.rowToHookID[idx] {
                        onDelete(hookID)
                    }
                }
            }
        }
        listBox.install(controller: gesture)
    }

    func restoreSelection(id: UUID?) {
        guard let id, let row = hookIDToRow[id] else { return }
        listBox.select(row: row)
    }

    private func collectSelectedIDs() -> Set<UUID> {
        var ids = Set<UUID>()
        guard let rows = listBox.selectedRows else { return ids }
        for rowRef in rows {
            let idx = Int(rowRef.index)
            if let hookID = rowToHookID[idx] {
                ids.insert(hookID)
            }
        }
        return ids
    }

    private func subtitle(for hook: TracerConfig.Hook) -> String? {
        switch hook.addressAnchor {
        case .absolute:
            return hook.addressAnchor.displayString
        case .moduleOffset(let name, _),
            .moduleExport(let name, _),
            .swiftFunc(let name, _):
            return name
        case .objcMethod:
            return nil
        case .debugSymbol:
            return nil
        }
    }
}

// MARK: - Editor pane (left side in SwiftUI expanded layout)

@MainActor
final class EditorPane {
    let widget: Box

    private weak var engine: Engine?
    private let onSave: (TracerConfig.Hook) -> Void
    var onDirtyChanged: ((Bool) -> Void)?

    private var hook: TracerConfig.Hook?
    private var draftCode: String = ""
    private(set) var isDirty: Bool = false

    private let showToolbar: Bool
    private var toolbar: Box?
    private var titleLabel: Label?
    private var subtitleLabel: Label?
    private var enabledSwitch: Switch?
    private var itraceSwitch: Switch?
    private var dirtyIndicator: Image?
    let saveButton: Button?
    private let editorHost: Box
    private let placeholder: Label
    private let monaco: MonacoEditor
    private let loadingSpinner: Spinner

    init(
        engine: Engine?,
        hook: TracerConfig.Hook?,
        sharedEditor: MonacoEditor,
        showToolbar: Bool = true,
        onSave: @escaping (TracerConfig.Hook) -> Void
    ) {
        self.engine = engine
        self.hook = hook
        self.monaco = sharedEditor
        self.showToolbar = showToolbar
        self.onSave = onSave

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

            let itraceRow = Box(orientation: .horizontal, spacing: 6)
            let itraceSwitch = Switch()
            itraceSwitch.valign = .center
            itraceSwitch.tooltipText = "Capture instruction trace for each call"
            self.itraceSwitch = itraceSwitch
            itraceRow.append(child: itraceSwitch)
            let itraceLabel = Label(str: "ITrace")
            itraceRow.append(child: itraceLabel)
            toolbar.append(child: itraceRow)

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
            self.itraceSwitch = nil
            self.dirtyIndicator = nil
            self.saveButton = nil
        }

        editorHost = Box(orientation: .vertical, spacing: 0)
        editorHost.hexpand = true
        editorHost.vexpand = true
        editorHost.setSizeRequest(width: -1, height: 320)

        loadingSpinner = Spinner()
        loadingSpinner.halign = .center
        loadingSpinner.valign = .center
        loadingSpinner.hexpand = true
        loadingSpinner.vexpand = true

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

        if showToolbar {
            let toggleHandler: (SwitchRef, Bool) -> Bool = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.recomputeDirty() }
                return false
            }
            enabledSwitch?.onStateSet(handler: toggleHandler)
            itraceSwitch?.onStateSet(handler: toggleHandler)

            saveButton?.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.commit() }
            }
        }

        if sharedEditor.isReady {
            sharedEditor.reparent(into: editorHost)
        } else {
            loadingSpinner.spinning = true
            loadingSpinner.start()
            editorHost.append(child: loadingSpinner)
            sharedEditor.onReady = { [weak self] in
                guard let self else { return }
                self.editorHost.remove(child: self.loadingSpinner)
                self.loadingSpinner.spinning = false
                self.loadingSpinner.stop()
                self.monaco.reparent(into: self.editorHost)
            }
        }
        sharedEditor.setText(hook?.code ?? "")

        applyHookToUI()
    }

    func setHook(_ newHook: TracerConfig.Hook?) {
        self.hook = newHook
        applyHookToUI()
    }

    private func applyHookToUI() {
        if let hook {
            titleLabel?.label = hook.displayName.isEmpty ? "(unnamed)" : hook.displayName
            subtitleLabel?.label = hook.addressAnchor.displayString
            enabledSwitch?.active = hook.isEnabled
            itraceSwitch?.active = hook.itraceEnabled
            draftCode = hook.code
            monaco.setText(hook.code)
            isDirty = false
            saveButton?.sensitive = false
            dirtyIndicator?.visible = false
            onDirtyChanged?(false)
            toolbar?.visible = true
            editorHost.visible = true
            placeholder.visible = false
        } else {
            toolbar?.visible = false
            editorHost.visible = false
            placeholder.visible = true
        }
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
            isDirty =
                draftCode != hook.code
                || (enabledSwitch?.active ?? hook.isEnabled) != hook.isEnabled
                || (itraceSwitch?.active ?? hook.itraceEnabled) != hook.itraceEnabled
        } else {
            isDirty = draftCode != hook.code
        }
        saveButton?.sensitive = isDirty
        dirtyIndicator?.visible = isDirty
        onDirtyChanged?(isDirty)
    }

    func commit() {
        guard var hook else { return }
        hook.code = draftCode
        if showToolbar {
            hook.isEnabled = enabledSwitch?.active ?? hook.isEnabled
            hook.itraceEnabled = itraceSwitch?.active ?? hook.itraceEnabled
        }
        self.hook = hook
        isDirty = false
        saveButton?.sensitive = false
        dirtyIndicator?.visible = false
        onDirtyChanged?(false)
        onSave(hook)
    }
}
