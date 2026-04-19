import Adw
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
    private var tracerEditor: TracerConfigEditor?
    private let sharedTracerMonaco: MonacoEditor

    init(engine: Engine, instrument: LumaCore.InstrumentInstance, tracerEditor: MonacoEditor) {
        self.engine = engine
        self.instrument = instrument
        self.sharedTracerMonaco = tracerEditor

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

    private func buildTracer() {
        guard let engine, let config = try? TracerConfig.decode(from: instrument.configJSON) else {
            widget.append(child: errorLabel("Failed to decode tracer config"))
            return
        }

        if let existing = tracerEditor {
            existing.update(config: config)
            widget.append(child: existing.widget)
            return
        }

        let editor = TracerConfigEditor(
            engine: engine,
            sessionID: instrument.sessionID,
            config: config,
            tracerEditor: sharedTracerMonaco,
            apply: { [weak self] data in
                self?.apply(configJSON: data)
            }
        )
        tracerEditor = editor
        widget.append(child: editor.widget)
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
            let image = Image(file: iconPath)
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
            column.append(child: makeBanner("⚠ Not yet reviewed. Please audit this script before enabling."))
        } else if config.lastReviewedHash != current {
            column.append(child: makeBanner("✎ Locally modified since last review."))
        } else if let synced = config.lastSyncedHash, synced != current {
            column.append(child: makeBanner("↻ Differs from last synced version on CodeShare."))
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
        textView.buffer?.set(text: config.source, len: -1)
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
            // Tracer keeps its own state in TracerConfigEditor; rebuilding would
            // tear down the live Monaco editor. Other instrument kinds rebuild.
            if self.instrument.kind != .tracer {
                self.rebuild()
            }
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

    private func makeBanner(_ text: String) -> Adw.Banner {
        let banner = Adw.Banner(title: text)
        banner.revealed = true
        return banner
    }

    func selectTracerHook(id: UUID) {
        guard instrument.kind == .tracer else { return }
        tracerEditor?.selectHook(id: id)
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
