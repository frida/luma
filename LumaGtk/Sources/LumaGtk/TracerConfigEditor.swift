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

    private var config: TracerConfig
    private var selectedHookID: UUID?

    private let contentSlot: Box
    private var hooksList: HooksList?
    private var editorPane: EditorPane?
    private var emptyStateSearch: EmptyStateSearch?

    init(
        engine: Engine,
        sessionID: UUID,
        config: TracerConfig,
        apply: @escaping (Data) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.config = config
        self.apply = apply
        self.selectedHookID = config.hooks.first?.id

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        contentSlot = Box(orientation: .vertical, spacing: 0)
        contentSlot.hexpand = true
        contentSlot.vexpand = true
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

        if config.hooks.isEmpty {
            let search = EmptyStateSearch(
                engine: engine,
                sessionID: sessionID,
                onPick: { [weak self] api in
                    self?.appendHook(for: api)
                }
            )
            emptyStateSearch = search
            contentSlot.append(child: search.widget)
            return
        }

        let paned = Paned(orientation: .horizontal)
        paned.position = 720
        paned.hexpand = true
        paned.vexpand = true

        let editorPane = EditorPane(
            engine: engine,
            hook: selectedHook,
            onSave: { [weak self] updated in
                self?.saveHook(updated)
            }
        )
        self.editorPane = editorPane

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
            attached: engine?.node(forSessionID: sessionID) != nil
        )
        self.hooksList = hooksList

        paned.startChild = WidgetRef(editorPane.widget)
        paned.endChild = WidgetRef(hooksList.widget)
        contentSlot.append(child: paned)
    }

    private var selectedHook: TracerConfig.Hook? {
        guard let id = selectedHookID else { return nil }
        return config.hooks.first(where: { $0.id == id })
    }

    private func handleSelect(_ id: UUID?) {
        guard id != selectedHookID else { return }
        selectedHookID = id
        editorPane?.setHook(selectedHook)
    }

    private func toggleEnabled(id: UUID, enabled: Bool) {
        guard let idx = config.hooks.firstIndex(where: { $0.id == id }) else { return }
        config.hooks[idx].isEnabled = enabled
        emit()
    }

    private func saveHook(_ updated: TracerConfig.Hook) {
        guard let idx = config.hooks.firstIndex(where: { $0.id == updated.id }) else { return }
        config.hooks[idx] = updated
        emit()
    }

    private func deleteHook(id: UUID) {
        config.hooks.removeAll { $0.id == id }
        if selectedHookID == id {
            selectedHookID = config.hooks.first?.id
        }
        emit()
        rebuildContent()
    }

    private func emit() {
        apply(config.encode())
    }

    fileprivate struct ResolvedApi {
        let moduleName: String
        let symbolName: String
        let address: UInt64
    }

    fileprivate func appendHook(for api: ResolvedApi) {
        let stub = defaultTracerNativeStub.replacingOccurrences(
            of: "CALL(args[0]",
            with: "\(api.symbolName)(args[0]"
        )
        let hook = TracerConfig.Hook(
            displayName: api.symbolName,
            addressAnchor: .moduleExport(name: api.moduleName, export: api.symbolName),
            isEnabled: true,
            code: stub
        )
        config.hooks.append(hook)
        selectedHookID = hook.id
        emit()
        rebuildContent()
    }
}

@MainActor
private final class EmptyStateSearch {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let onPick: (TracerConfigEditor.ResolvedApi) -> Void

    private let entry: Entry
    private let spinner: Spinner
    private let status: Label
    private let listBox: ListBox
    private let scroll: ScrolledWindow

    private var results: [TracerConfigEditor.ResolvedApi] = []
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(
        engine: Engine?,
        sessionID: UUID,
        onPick: @escaping (TracerConfigEditor.ResolvedApi) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.onPick = onPick

        widget = Box(orientation: .vertical, spacing: 12)
        widget.hexpand = true
        widget.vexpand = true
        widget.valign = .center
        widget.halign = .center
        widget.setSizeRequest(width: 480, height: -1)
        widget.marginStart = 24
        widget.marginEnd = 24
        widget.marginTop = 24
        widget.marginBottom = 24

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

        status = Label(str: attached ? "Type a query to search." : "Attach to a process to search APIs.")
        status.add(cssClass: "dim-label")
        status.add(cssClass: "caption")
        status.halign = .start
        widget.append(child: status)

        listBox = ListBox()
        listBox.selectionMode = .none
        listBox.add(cssClass: "boxed-list")

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setSizeRequest(width: -1, height: 280)
        scroll.set(child: listBox)
        scroll.visible = false
        widget.append(child: scroll)

        entry.onChanged { [anchor = self] _ in
            MainActor.assumeIsolated { anchor.scheduleSearch() }
        }
        entry.onActivate { [anchor = self] _ in
            MainActor.assumeIsolated { anchor.runSearchNow() }
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
                let raw = try await node.script.exports.resolveApis(query)
                if Task.isCancelled { return }
                guard let arr = raw as? [[String: Any]] else {
                    anchor.results = []
                    anchor.rebuildResults()
                    anchor.status.label = "resolveApis: unexpected response"
                    return
                }
                var decoded: [TracerConfigEditor.ResolvedApi] = []
                decoded.reserveCapacity(arr.count)
                for obj in arr {
                    guard let moduleName = obj["moduleName"] as? String,
                        let symbolName = obj["symbolName"] as? String,
                        let addressStr = obj["address"] as? String,
                        let address = try? parseAgentHexAddress(addressStr)
                    else { continue }
                    decoded.append(
                        TracerConfigEditor.ResolvedApi(
                            moduleName: moduleName,
                            symbolName: symbolName,
                            address: address
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

        for (idx, api) in results.enumerated() {
            let row = ListBoxRow()
            let inner = Box(orientation: .horizontal, spacing: 8)
            inner.marginStart = 10
            inner.marginEnd = 10
            inner.marginTop = 6
            inner.marginBottom = 6

            let textColumn = Box(orientation: .vertical, spacing: 2)
            textColumn.hexpand = true

            let title = Label(str: api.symbolName)
            title.halign = .start
            textColumn.append(child: title)

            let subtitle = Label(str: "\(api.moduleName)  •  " + String(format: "0x%llx", api.address))
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

    init(
        hooks: [TracerConfig.Hook],
        selectedID: UUID?,
        onSelect: @escaping (UUID?) -> Void,
        onToggleEnabled: @escaping (UUID, Bool) -> Void,
        onDelete: @escaping (UUID) -> Void,
        attached: Bool
    ) {
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

        let addButton = Button()
        let addIcon = Image(iconName: "list-add-symbolic")
        addButton.set(child: addIcon)
        addButton.add(cssClass: "flat")
        addButton.tooltipText = attached ? "Add hooks by searching functions" : "Attach to a process to search APIs."
        addButton.sensitive = attached
        header.append(child: addButton)
        widget.append(child: header)

        let listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "boxed-list")

        var rowToHookID: [Int: UUID] = [:]
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
            if hook.id == selectedID {
                initialRow = row
            }
        }

        listBox.onRowSelected { _, row in
            MainActor.assumeIsolated {
                guard let row else {
                    onSelect(nil)
                    return
                }
                let idx = Int(row.index)
                onSelect(rowToHookID[idx])
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

        // Right-click to delete the hovered row.
        let gesture = GestureClick()
        gesture.button = 3
        gesture.onPressed { [weak listBox] _, _, x, y in
            MainActor.assumeIsolated {
                guard let listBox else { return }
                guard let row = listBox.getRowAt(y: Int(y)) else { return }
                let idx = Int(row.index)
                guard let hookID = rowToHookID[idx] else { return }
                onDelete(hookID)
            }
        }
        listBox.install(controller: gesture)
    }

    private func subtitle(for hook: TracerConfig.Hook) -> String? {
        switch hook.addressAnchor {
        case .absolute:
            return hook.addressAnchor.displayString
        case .moduleOffset(let name, _),
            .moduleExport(let name, _):
            return name
        }
    }
}

// MARK: - Editor pane (left side in SwiftUI expanded layout)

@MainActor
private final class EditorPane {
    static let tracerDeclarations = #"""
        declare function defineHandler(h: Handler): void;

        type Handler = FunctionHandlers | InstructionHandler;

        interface FunctionHandlers {
            onEnter?: EnterHandler;
            onLeave?: LeaveHandler;
        }

        type EnterHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
        type LeaveHandler = (this: InvocationContext, log: LogHandler, retval: InvocationReturnValue) => any;
        type InstructionHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
        type LogHandler = (...args: any[]) => void;
        """#

    let widget: Box

    private weak var engine: Engine?
    private let onSave: (TracerConfig.Hook) -> Void

    private var hook: TracerConfig.Hook?
    private var draftCode: String = ""
    private var isDirty: Bool = false

    private let toolbar: Box
    private let titleLabel: Label
    private let subtitleLabel: Label
    private let enabledSwitch: Switch
    private let itraceSwitch: Switch
    private let dirtyIndicator: Image
    private let saveButton: Button
    private let editorHost: Box
    private let placeholder: Label
    private let monaco: MonacoEditor

    init(engine: Engine?, hook: TracerConfig.Hook?, onSave: @escaping (TracerConfig.Hook) -> Void) {
        self.engine = engine
        self.hook = hook
        self.onSave = onSave

        widget = Box(orientation: .vertical, spacing: 8)
        widget.hexpand = true
        widget.vexpand = true
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12

        toolbar = Box(orientation: .horizontal, spacing: 8)
        toolbar.hexpand = true

        let titleColumn = Box(orientation: .vertical, spacing: 0)
        titleColumn.hexpand = true
        titleLabel = Label(str: "")
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-4")
        titleColumn.append(child: titleLabel)
        subtitleLabel = Label(str: "")
        subtitleLabel.halign = .start
        subtitleLabel.add(cssClass: "caption")
        subtitleLabel.add(cssClass: "dim-label")
        subtitleLabel.add(cssClass: "monospace")
        titleColumn.append(child: subtitleLabel)
        toolbar.append(child: titleColumn)

        let enabledRow = Box(orientation: .horizontal, spacing: 6)
        enabledSwitch = Switch()
        enabledSwitch.valign = .center
        enabledRow.append(child: enabledSwitch)
        let enabledLabel = Label(str: "Enabled")
        enabledRow.append(child: enabledLabel)
        toolbar.append(child: enabledRow)

        let itraceRow = Box(orientation: .horizontal, spacing: 6)
        itraceSwitch = Switch()
        itraceSwitch.valign = .center
        itraceSwitch.tooltipText = "Capture instruction trace for each call"
        itraceRow.append(child: itraceSwitch)
        let itraceLabel = Label(str: "ITrace")
        itraceRow.append(child: itraceLabel)
        toolbar.append(child: itraceRow)

        dirtyIndicator = Image(iconName: "media-record-symbolic")
        dirtyIndicator.tooltipText = "Unsaved changes"
        dirtyIndicator.visible = false
        toolbar.append(child: dirtyIndicator)

        saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.sensitive = false
        saveButton.tooltipText = "Save current hook script"
        toolbar.append(child: saveButton)

        widget.append(child: toolbar)

        editorHost = Box(orientation: .vertical, spacing: 0)
        editorHost.hexpand = true
        editorHost.vexpand = true
        editorHost.setSizeRequest(width: -1, height: 320)

        var profile = MonacoEditorProfile(languageId: "typescript", theme: .dark, fontSize: 13)
        profile.tsCompilerOptions = MonacoTypings.fridaCompilerOptions
        if let gum = MonacoTypings.fridaGum { profile.tsExtraLibs.append(gum) }
        profile.tsExtraLibs.append(
            MonacoExtraLib(Self.tracerDeclarations, filePath: "@types/frida-luma/tracer.d.ts")
        )
        let installedPackages = (try? engine?.store.fetchPackagesState().packages) ?? []
        if let aliasLib = MonacoPackageAliasTypings.makeLib(packages: installedPackages) {
            profile.tsExtraLibs.append(MonacoExtraLib(aliasLib.content, filePath: aliasLib.filePath))
        }
        let monacoEditor = MonacoEditor(profile: profile, initialText: hook?.code ?? "")
        monaco = monacoEditor
        monacoEditor.widget.hexpand = true
        monacoEditor.widget.vexpand = true
        if let engine {
            Task { @MainActor in
                await engine.rebuildMonacoFSSnapshotIfNeeded()
                monacoEditor.setFSSnapshot(engine.monacoFSSnapshot)
            }
        }
        editorHost.append(child: monaco.widget)
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

        let toggleHandler: (SwitchRef, Bool) -> Bool = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.recomputeDirty() }
            return false
        }
        enabledSwitch.onStateSet(handler: toggleHandler)
        itraceSwitch.onStateSet(handler: toggleHandler)

        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }

        applyHookToUI()
    }

    func setHook(_ newHook: TracerConfig.Hook?) {
        self.hook = newHook
        applyHookToUI()
    }

    private func applyHookToUI() {
        if let hook {
            titleLabel.label = hook.displayName.isEmpty ? "(unnamed)" : hook.displayName
            subtitleLabel.label = hook.addressAnchor.displayString
            enabledSwitch.active = hook.isEnabled
            itraceSwitch.active = hook.itraceEnabled
            draftCode = hook.code
            monaco.setText(hook.code)
            isDirty = false
            saveButton.sensitive = false
            dirtyIndicator.visible = false
            toolbar.visible = true
            editorHost.visible = true
            placeholder.visible = false
        } else {
            toolbar.visible = false
            editorHost.visible = false
            placeholder.visible = true
        }
    }

    private func recomputeDirty() {
        guard let hook else {
            isDirty = false
            saveButton.sensitive = false
            dirtyIndicator.visible = false
            return
        }
        isDirty =
            draftCode != hook.code
            || enabledSwitch.active != hook.isEnabled
            || itraceSwitch.active != hook.itraceEnabled
        saveButton.sensitive = isDirty
        dirtyIndicator.visible = isDirty
    }

    private func commit() {
        guard var hook else { return }
        hook.code = draftCode
        hook.isEnabled = enabledSwitch.active
        hook.itraceEnabled = itraceSwitch.active
        self.hook = hook
        isDirty = false
        saveButton.sensitive = false
        dirtyIndicator.visible = false
        onSave(hook)
    }
}
