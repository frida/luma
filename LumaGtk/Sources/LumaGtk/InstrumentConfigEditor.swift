import CGtk
import Foundation
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
        paned.startChild = WidgetRef(buildTracerHookList(config: config))
        paned.endChild = WidgetRef(buildTracerHookEditor(config: config))
        widget.append(child: paned)
    }

    private func buildTracerHookList(config: TracerConfig) -> Box {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

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

        let textView = TextView()
        textView.hexpand = true
        textView.vexpand = true
        textView.monospace = true
        textView.topMargin = 6
        textView.bottomMargin = 6
        textView.leftMargin = 6
        textView.rightMargin = 6
        hook.code.withCString { cstr in
            textView.buffer.set(text: cstr, len: -1)
        }
        let codeScroll = ScrolledWindow()
        codeScroll.hexpand = true
        codeScroll.vexpand = true
        codeScroll.setSizeRequest(width: -1, height: 220)
        codeScroll.set(child: textView)
        column.append(child: codeScroll)

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

        let updateDirty = { [weak self] in
            guard let self else { return }
            let codeNow = readText(from: textView)
            let nameNow = nameEntry.text ?? ""
            let dirty =
                codeNow != hook.code
                || nameNow != hook.displayName
                || enabledSwitch.active != hook.isEnabled
                || pinnedSwitch.active != hook.isPinned
                || itraceSwitch.active != hook.itraceEnabled
            saveButton.sensitive = dirty
            discardButton.sensitive = dirty
            _ = self
        }

        nameEntry.onChanged { _ in
            MainActor.assumeIsolated { updateDirty() }
        }
        textView.buffer?.onChanged { _ in
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
                    cfg.hooks[idx].code = readText(from: textView)
                    cfg.hooks[idx].isEnabled = enabledSwitch.active
                    cfg.hooks[idx].isPinned = pinnedSwitch.active
                    cfg.hooks[idx].itraceEnabled = itraceSwitch.active
                }
            }
        }

        discardButton.onClicked { _ in
            MainActor.assumeIsolated {
                nameEntry.text = hook.displayName
                hook.code.withCString { cstr in
                    textView.buffer?.set(text: cstr, len: -1)
                }
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
