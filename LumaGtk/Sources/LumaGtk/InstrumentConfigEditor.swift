import CGtk
import Foundation
import GLibObject
import Gtk
import LumaCore

@MainActor
final class InstrumentConfigEditor {
    let widget: Box

    private weak var engine: Engine?
    private var instrument: LumaCore.InstrumentInstance

    init(engine: Engine, instrument: LumaCore.InstrumentInstance) {
        self.engine = engine
        self.instrument = instrument

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        rebuild()
    }

    private func rebuild() {
        var child = widget.firstChild
        while let current = child {
            child = current.nextSibling
            widget.remove(child: current)
        }

        switch instrument.kind {
        case .tracer:
            buildTracer()
        case .hookPack:
            buildHookPack()
        case .codeShare:
            buildCodeShare()
        }
    }

    // MARK: - Tracer

    private var tracerSelectedHookID: UUID?

    private func buildTracer() {
        guard let config = try? TracerConfig.decode(from: instrument.configJSON) else {
            widget.append(child: errorLabel("Failed to decode tracer config"))
            return
        }

        if tracerSelectedHookID == nil || !config.hooks.contains(where: { $0.id == tracerSelectedHookID }) {
            tracerSelectedHookID = config.hooks.first?.id
        }

        let paned = Paned(orientation: .horizontal)
        paned.position = 240
        paned.hexpand = true
        paned.vexpand = true
        let hookList = buildTracerHookList(config: config)
        let hookEditor = buildTracerHookEditor(config: config)
        paned.startChild = WidgetRef(hookList)
        paned.endChild = WidgetRef(hookEditor)
        widget.append(child: paned)
    }

    private func buildTracerHookList(config: TracerConfig) -> Box {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

        let toolbar = Box(orientation: .horizontal, spacing: 6)
        toolbar.marginStart = 6
        toolbar.marginEnd = 6
        toolbar.marginTop = 6
        toolbar.marginBottom = 6

        let addButton = Button(label: "Add Hook\u{2026}")
        addButton.add(cssClass: "flat")
        let attached = engine?.node(forSessionID: instrument.sessionID) != nil
        addButton.sensitive = attached
        if !attached {
            addButton.tooltipText = "Attach to a process to search APIs."
        }
        addButton.onClicked { [weak self, weak addButton] _ in
            MainActor.assumeIsolated {
                guard let self, let addButton else { return }
                self.presentApiSearchPopover(anchor: addButton)
            }
        }
        toolbar.append(child: addButton)
        column.append(child: toolbar)

        let listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")

        var rowToHookID: [Int: UUID] = [:]
        var indexToSelect: Int?
        for (idx, hook) in config.hooks.enumerated() {
            let row = ListBoxRow()
            let inner = Box(orientation: .vertical, spacing: 2)
            inner.marginStart = 12
            inner.marginEnd = 12
            inner.marginTop = 6
            inner.marginBottom = 6

            let title = Label(str: hook.displayName.isEmpty ? "(unnamed)" : hook.displayName)
            title.halign = .start
            title.hexpand = true
            if !hook.isEnabled {
                title.add(cssClass: "dim-label")
            }
            inner.append(child: title)

            let subtitle = Label(str: hook.addressAnchor.displayString)
            subtitle.halign = .start
            subtitle.add(cssClass: "caption")
            subtitle.add(cssClass: "dim-label")
            inner.append(child: subtitle)

            row.set(child: inner)
            listBox.append(child: row)
            rowToHookID[idx] = hook.id
            if hook.id == tracerSelectedHookID {
                indexToSelect = idx
            }
        }

        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let idx = Int(row.index)
                guard let hookID = rowToHookID[idx], hookID != self.tracerSelectedHookID else { return }
                self.tracerSelectedHookID = hookID
                self.rebuild()
            }
        }

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: listBox)
        column.append(child: scroll)

        if let indexToSelect, let row = listBox.getRowAt(index: indexToSelect) {
            listBox.select(row: row)
        }

        return column
    }

    private func buildTracerHookEditor(config: TracerConfig) -> Box {
        let column = Box(orientation: .vertical, spacing: 8)
        column.hexpand = true
        column.vexpand = true
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 12
        column.marginBottom = 12

        guard let hookID = tracerSelectedHookID,
            let hook = config.hooks.first(where: { $0.id == hookID })
        else {
            let placeholder = Label(str: "Select a hook to edit, or add a new one.")
            placeholder.add(cssClass: "dim-label")
            placeholder.hexpand = true
            placeholder.vexpand = true
            column.append(child: placeholder)
            return column
        }

        let nameRow = Box(orientation: .horizontal, spacing: 8)
        let nameLabel = Label(str: "Name")
        nameLabel.add(cssClass: "heading")
        nameRow.append(child: nameLabel)
        let nameEntry = Entry()
        nameEntry.text = hook.displayName
        nameEntry.hexpand = true
        nameRow.append(child: nameEntry)
        column.append(child: nameRow)

        let anchor = Label(str: "Anchor: \(hook.addressAnchor.displayString)")
        anchor.halign = .start
        anchor.add(cssClass: "dim-label")
        anchor.add(cssClass: "monospace")
        column.append(child: anchor)

        let toggles = Box(orientation: .horizontal, spacing: 16)

        let enabledRow = Box(orientation: .horizontal, spacing: 6)
        let enabledSwitch = Switch()
        enabledSwitch.active = hook.isEnabled
        enabledSwitch.valign = .center
        enabledRow.append(child: enabledSwitch)
        enabledRow.append(child: Label(str: "Enabled"))
        toggles.append(child: enabledRow)

        let pinnedRow = Box(orientation: .horizontal, spacing: 6)
        let pinnedSwitch = Switch()
        pinnedSwitch.active = hook.isPinned
        pinnedSwitch.valign = .center
        pinnedRow.append(child: pinnedSwitch)
        pinnedRow.append(child: Label(str: "Pinned"))
        toggles.append(child: pinnedRow)

        let itraceRow = Box(orientation: .horizontal, spacing: 6)
        let itraceSwitch = Switch()
        itraceSwitch.active = hook.itraceEnabled
        itraceSwitch.valign = .center
        itraceRow.append(child: itraceSwitch)
        itraceRow.append(child: Label(str: "ITrace"))
        toggles.append(child: itraceRow)

        column.append(child: toggles)

        let codeHeader = Label(str: "Code")
        codeHeader.halign = .start
        codeHeader.add(cssClass: "heading")
        column.append(child: codeHeader)

        var profile = MonacoEditorProfile(languageId: "typescript", theme: .dark, fontSize: 13)
        if let gum = MonacoTypings.fridaGum { profile.tsExtraLibs.append(gum) }
        let installedPackages = (try? engine?.store.fetchPackagesState().packages) ?? []
        if let aliasLib = MonacoPackageAliasTypings.makeLib(packages: installedPackages) {
            profile.tsExtraLibs.append(MonacoExtraLib(aliasLib.content, filePath: aliasLib.filePath))
        }
        let editor = MonacoEditor(profile: profile, initialText: hook.code)
        if let engine {
            Task { @MainActor in
                await engine.rebuildMonacoFSSnapshotIfNeeded()
                editor.setFSSnapshot(engine.monacoFSSnapshot)
            }
        }
        var currentCode = hook.code

        let editorHost = Box(orientation: .vertical, spacing: 0)
        editorHost.hexpand = true
        editorHost.vexpand = true
        editorHost.setSizeRequest(width: -1, height: 280)
        editorHost.append(child: editor.widget)
        column.append(child: editorHost)

        let actions = Box(orientation: .horizontal, spacing: 8)
        let spacer = Label(str: "")
        spacer.hexpand = true
        actions.append(child: spacer)

        let removeButton = Button(label: "Remove Hook")
        removeButton.add(cssClass: "destructive-action")
        actions.append(child: removeButton)

        let discardButton = Button(label: "Discard")
        discardButton.sensitive = false
        actions.append(child: discardButton)

        let saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.sensitive = false
        actions.append(child: saveButton)

        column.append(child: actions)

        let updateDirty = {
            let nameNow = nameEntry.text ?? ""
            let dirty =
                currentCode != hook.code
                || nameNow != hook.displayName
                || enabledSwitch.active != hook.isEnabled
                || pinnedSwitch.active != hook.isPinned
                || itraceSwitch.active != hook.itraceEnabled
            saveButton.sensitive = dirty
            discardButton.sensitive = dirty
        }

        editor.onTextChanged = { text in
            currentCode = text
            updateDirty()
        }

        nameEntry.onChanged { _ in
            MainActor.assumeIsolated { updateDirty() }
        }
        let toggleHandler: (SwitchRef, Bool) -> Bool = { _, _ in
            MainActor.assumeIsolated { updateDirty() }
            return false
        }
        enabledSwitch.onStateSet(handler: toggleHandler)
        pinnedSwitch.onStateSet(handler: toggleHandler)
        itraceSwitch.onStateSet(handler: toggleHandler)

        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mutateTracer { cfg in
                    guard let idx = cfg.hooks.firstIndex(where: { $0.id == hookID }) else { return }
                    cfg.hooks[idx].displayName = nameEntry.text ?? ""
                    cfg.hooks[idx].code = currentCode
                    cfg.hooks[idx].isEnabled = enabledSwitch.active
                    cfg.hooks[idx].isPinned = pinnedSwitch.active
                    cfg.hooks[idx].itraceEnabled = itraceSwitch.active
                }
            }
        }

        discardButton.onClicked { _ in
            MainActor.assumeIsolated {
                nameEntry.text = hook.displayName
                editor.setText(hook.code)
                currentCode = hook.code
                enabledSwitch.active = hook.isEnabled
                pinnedSwitch.active = hook.isPinned
                itraceSwitch.active = hook.itraceEnabled
                updateDirty()
            }
        }

        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tracerSelectedHookID = nil
                self.mutateTracer { cfg in
                    cfg.hooks.removeAll { $0.id == hookID }
                }
            }
        }

        return column
    }

    private func mutateTracer(_ body: (inout TracerConfig) -> Void) {
        guard var config = try? TracerConfig.decode(from: instrument.configJSON) else { return }
        body(&config)
        apply(configJSON: config.encode())
    }

    // MARK: - Tracer API search

    private struct ResolvedApi {
        let moduleName: String
        let symbolName: String
        let address: UInt64
    }

    private func presentApiSearchPopover(anchor: Widget) {
        guard let engine, engine.node(forSessionID: instrument.sessionID) != nil else { return }

        let popover = Popover()
        popover.autohide = true

        let box = Box(orientation: .vertical, spacing: 6)
        box.marginStart = 8
        box.marginEnd = 8
        box.marginTop = 8
        box.marginBottom = 8
        box.setSizeRequest(width: 360, height: 360)

        let queryRow = Box(orientation: .horizontal, spacing: 6)
        let entry = Entry()
        entry.hexpand = true
        entry.placeholderText = "e.g. exports:*!CFRetain"
        queryRow.append(child: entry)

        let searchButton = Button(label: "Search")
        searchButton.add(cssClass: "suggested-action")
        queryRow.append(child: searchButton)

        let spinner = Spinner()
        spinner.spinning = false
        spinner.valign = .center
        queryRow.append(child: spinner)

        box.append(child: queryRow)

        let listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "boxed-list")

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: listBox)
        box.append(child: scroll)

        let status = Label(str: "Enter a query and press Search.")
        status.add(cssClass: "dim-label")
        status.add(cssClass: "caption")
        status.halign = .start
        box.append(child: status)

        let actions = Box(orientation: .horizontal, spacing: 6)
        let spacer = Label(str: "")
        spacer.hexpand = true
        actions.append(child: spacer)

        let addAllButton = Button(label: "Add All")
        addAllButton.sensitive = false
        actions.append(child: addAllButton)

        let addSelectedButton = Button(label: "Add")
        addSelectedButton.add(cssClass: "suggested-action")
        addSelectedButton.sensitive = false
        actions.append(child: addSelectedButton)

        box.append(child: actions)

        var results: [ResolvedApi] = []

        let rebuildList: () -> Void = {
            var child = listBox.firstChild
            while let current = child {
                child = current.nextSibling
                listBox.remove(child: current)
            }
            for api in results {
                let row = ListBoxRow()
                let inner = Box(orientation: .vertical, spacing: 2)
                inner.marginStart = 10
                inner.marginEnd = 10
                inner.marginTop = 4
                inner.marginBottom = 4

                let title = Label(str: "\(api.moduleName)!\(api.symbolName)")
                title.halign = .start
                inner.append(child: title)

                let subtitle = Label(str: String(format: "0x%llx", api.address))
                subtitle.halign = .start
                subtitle.add(cssClass: "caption")
                subtitle.add(cssClass: "dim-label")
                subtitle.add(cssClass: "monospace")
                inner.append(child: subtitle)

                row.set(child: inner)
                listBox.append(child: row)
            }
            addAllButton.sensitive = !results.isEmpty
            addSelectedButton.sensitive = false
            if !results.isEmpty, let first = listBox.getRowAt(index: 0) {
                listBox.select(row: first)
                addSelectedButton.sensitive = true
            }
        }

        listBox.onRowSelected { _, row in
            MainActor.assumeIsolated {
                addSelectedButton.sensitive = row != nil
            }
        }

        let runSearch: () -> Void = { [weak self] in
            guard let self else { return }
            let query = entry.text ?? ""
            guard !query.isEmpty else { return }
            guard let node = self.engine?.node(forSessionID: self.instrument.sessionID) else {
                status.label = "Not attached."
                return
            }
            spinner.spinning = true
            spinner.start()
            searchButton.sensitive = false
            status.label = "Searching\u{2026}"
            Task { @MainActor in
                defer {
                    spinner.spinning = false
                    searchButton.sensitive = true
                }
                do {
                    let raw = try await node.script.exports.resolveApis(query)
                    guard let arr = raw as? [[String: Any]] else {
                        results = []
                        rebuildList()
                        status.label = "resolveApis: unexpected response"
                        return
                    }
                    var decoded: [ResolvedApi] = []
                    decoded.reserveCapacity(arr.count)
                    for obj in arr {
                        guard let moduleName = obj["moduleName"] as? String,
                            let symbolName = obj["symbolName"] as? String,
                            let addressStr = obj["address"] as? String,
                            let address = try? parseAgentHexAddress(addressStr)
                        else { continue }
                        decoded.append(ResolvedApi(moduleName: moduleName, symbolName: symbolName, address: address))
                    }
                    results = decoded
                    rebuildList()
                    status.label = decoded.isEmpty ? "No results." : "\(decoded.count) result\(decoded.count == 1 ? "" : "s")"
                } catch {
                    results = []
                    rebuildList()
                    status.label = "Search failed: \(error.localizedDescription)"
                }
            }
        }

        searchButton.onClicked { _ in
            MainActor.assumeIsolated { runSearch() }
        }
        entry.onActivate { _ in
            MainActor.assumeIsolated { runSearch() }
        }

        addSelectedButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                guard let self, let row = listBox.selectedRow else { return }
                let idx = Int(row.index)
                guard idx >= 0, idx < results.count else { return }
                self.appendTracerHook(for: results[idx])
                popover?.popdown()
            }
        }

        addAllButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mutateTracer { cfg in
                    for api in results {
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
                        cfg.hooks.append(hook)
                    }
                }
                popover?.popdown()
            }
        }

        popover.set(child: WidgetRef(box.widget_ptr))
        popover.set(parent: WidgetRef(anchor))
        popover.popup()
        _ = entry.grabFocus()
    }

    private func appendTracerHook(for api: ResolvedApi) {
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
        mutateTracer { cfg in
            cfg.hooks.append(hook)
        }
    }

    // MARK: - Hook pack

    private func buildHookPack() {
        let outer = Box(orientation: .vertical, spacing: 8)
        outer.hexpand = true
        outer.marginStart = 24
        outer.marginEnd = 24
        outer.marginTop = 8
        outer.marginBottom = 12
        widget.append(child: outer)

        guard
            let config = try? JSONDecoder().decode(HookPackConfig.self, from: instrument.configJSON),
            let pack = engine?.hookPacks.pack(withId: instrument.sourceIdentifier)
        else {
            outer.append(child: errorLabel("Failed to load hook pack"))
            return
        }

        let packHeader = Box(orientation: .horizontal, spacing: 12)
        packHeader.hexpand = true

        if let iconFile = pack.manifest.icon?.file {
            let iconPath = pack.folderURL.appendingPathComponent(iconFile).path
            let image = iconPath.withCString { Image(file: $0) }
            image.set(pixelSize: 32)
            image.valign = .center
            packHeader.append(child: image)
        }

        let titleColumn = Box(orientation: .vertical, spacing: 0)
        titleColumn.hexpand = true
        titleColumn.valign = .center

        let nameLabel = Label(str: pack.manifest.name)
        nameLabel.halign = .start
        nameLabel.add(cssClass: "title-3")
        titleColumn.append(child: nameLabel)

        let idLabel = Label(str: pack.manifest.id)
        idLabel.halign = .start
        idLabel.add(cssClass: "caption")
        idLabel.add(cssClass: "dim-label")
        titleColumn.append(child: idLabel)

        packHeader.append(child: titleColumn)
        outer.append(child: packHeader)

        let header = Label(str: "Features")
        header.halign = .start
        header.add(cssClass: "heading")
        outer.append(child: header)

        if pack.manifest.features.isEmpty {
            outer.append(child: dimLabel("This hook-pack does not define any configurable features."))
            return
        }

        for feature in pack.manifest.features {
            let row = Box(orientation: .horizontal, spacing: 8)
            row.hexpand = true

            let toggle = Switch()
            toggle.active = config.features[feature.id] != nil
            toggle.valign = .center
            row.append(child: toggle)

            let name = Label(str: feature.name)
            name.halign = .start
            name.hexpand = true
            row.append(child: name)

            let featureID = feature.id
            toggle.onStateSet { [weak self] _, state in
                MainActor.assumeIsolated {
                    self?.mutateHookPack { cfg in
                        if state {
                            if cfg.features[featureID] == nil {
                                cfg.features[featureID] = FeatureConfig()
                            }
                        } else {
                            cfg.features.removeValue(forKey: featureID)
                        }
                    }
                }
                return false
            }

            outer.append(child: row)
        }
    }

    private func mutateHookPack(_ body: (inout HookPackConfig) -> Void) {
        guard var config = try? JSONDecoder().decode(HookPackConfig.self, from: instrument.configJSON) else { return }
        body(&config)
        guard let data = try? JSONEncoder().encode(config) else { return }
        apply(configJSON: data)
    }

    // MARK: - CodeShare

    private func buildCodeShare() {
        let column = Box(orientation: .vertical, spacing: 8)
        column.hexpand = true
        column.vexpand = true
        column.marginStart = 24
        column.marginEnd = 24
        column.marginTop = 8
        column.marginBottom = 12
        widget.append(child: column)

        guard let config = try? JSONDecoder().decode(CodeShareConfig.self, from: instrument.configJSON) else {
            column.append(child: errorLabel("Failed to decode codeshare config"))
            return
        }

        let title = Label(str: config.name.isEmpty ? "Code Share" : config.name)
        title.add(cssClass: "title-3")
        title.halign = .start
        column.append(child: title)

        if let project = config.project {
            let sub = Label(str: "@\(project.owner)/\(project.slug)")
            sub.add(cssClass: "dim-label")
            sub.add(cssClass: "caption")
            sub.halign = .start
            column.append(child: sub)
        } else {
            let sub = Label(str: "Local snippet (not published)")
            sub.add(cssClass: "dim-label")
            sub.add(cssClass: "caption")
            sub.halign = .start
            column.append(child: sub)
        }

        let current = config.currentSourceHash
        if config.lastReviewedHash == nil {
            let banner = Label(str: "⚠ Not yet reviewed. Please audit this script before enabling.")
            banner.halign = .start
            banner.add(cssClass: "luma-banner")
            banner.add(cssClass: "luma-banner-warning")
            banner.wrap = true
            column.append(child: banner)
        } else if config.lastReviewedHash != current {
            let banner = Label(str: "✎ Locally modified since last review.")
            banner.halign = .start
            banner.add(cssClass: "luma-banner")
            banner.add(cssClass: "luma-banner-warning")
            banner.wrap = true
            column.append(child: banner)
        } else if let synced = config.lastSyncedHash, synced != current {
            let banner = Label(str: "↻ Differs from last synced version on CodeShare.")
            banner.halign = .start
            banner.add(cssClass: "luma-banner")
            banner.wrap = true
            column.append(child: banner)
        }

        let nameRow = Box(orientation: .horizontal, spacing: 8)
        nameRow.append(child: Label(str: "Name"))
        let nameEntry = Entry()
        nameEntry.text = config.name
        nameEntry.hexpand = true
        nameRow.append(child: nameEntry)
        column.append(child: nameRow)

        let descRow = Box(orientation: .horizontal, spacing: 8)
        descRow.append(child: Label(str: "Description"))
        let descEntry = Entry()
        descEntry.text = config.description
        descEntry.hexpand = true
        descRow.append(child: descEntry)
        column.append(child: descRow)

        let codeHeader = Label(str: "Source")
        codeHeader.halign = .start
        codeHeader.add(cssClass: "heading")
        column.append(child: codeHeader)

        let textView = TextView()
        textView.hexpand = true
        textView.vexpand = true
        textView.monospace = true
        textView.topMargin = 6
        textView.bottomMargin = 6
        textView.leftMargin = 6
        textView.rightMargin = 6
        config.source.withCString { cstr in
            textView.buffer?.set(text: cstr, len: -1)
        }
        let codeScroll = ScrolledWindow()
        codeScroll.hexpand = true
        codeScroll.vexpand = true
        codeScroll.setSizeRequest(width: -1, height: 280)
        codeScroll.set(child: textView)
        column.append(child: codeScroll)

        let actions = Box(orientation: .horizontal, spacing: 8)
        let spacer = Label(str: "")
        spacer.hexpand = true
        actions.append(child: spacer)

        let saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.sensitive = false
        actions.append(child: saveButton)
        column.append(child: actions)

        let updateDirty = {
            let dirty =
                (nameEntry.text ?? "") != config.name
                || (descEntry.text ?? "") != config.description
                || readText(from: textView) != config.source
            saveButton.sensitive = dirty
        }
        nameEntry.onChanged { _ in MainActor.assumeIsolated { updateDirty() } }
        descEntry.onChanged { _ in MainActor.assumeIsolated { updateDirty() } }
        textView.buffer?.onChanged { _ in MainActor.assumeIsolated { updateDirty() } }

        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var updated = config
                updated.name = nameEntry.text ?? ""
                updated.description = descEntry.text ?? ""
                updated.source = readText(from: textView)
                updated.lastReviewedHash = updated.currentSourceHash
                guard let data = try? JSONEncoder().encode(updated) else { return }
                self.apply(configJSON: data)
            }
        }
    }

    // MARK: - Apply

    private func apply(configJSON: Data) {
        guard let engine else { return }
        let snapshot = instrument
        Task { @MainActor in
            await engine.applyInstrumentConfig(snapshot, configJSON: configJSON)
            if let updated = try? engine.store.fetchInstruments(sessionID: snapshot.sessionID)
                .first(where: { $0.id == snapshot.id })
            {
                self.instrument = updated
            } else {
                self.instrument.configJSON = configJSON
            }
            self.rebuild()
        }
    }

    private func dimLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "dim-label")
        label.halign = .start
        return label
    }

    private func errorLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "error")
        label.halign = .start
        return label
    }

    func selectTracerHook(id: UUID) {
        guard instrument.kind == .tracer,
            let config = try? TracerConfig.decode(from: instrument.configJSON),
            config.hooks.contains(where: { $0.id == id })
        else { return }
        tracerSelectedHookID = id
        rebuild()
    }
}

@MainActor
private func readText(from textView: TextView) -> String {
    guard let buffer = textView.buffer else { return "" }
    let startPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
    let endPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
    defer {
        startPtr.deallocate()
        endPtr.deallocate()
    }
    let start = TextIter(startPtr)
    let end = TextIter(endPtr)
    buffer.getStart(iter: start)
    buffer.getEnd(iter: end)
    return buffer.getText(start: start, end: end, includeHiddenChars: true) ?? ""
}
