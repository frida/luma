import Adw
import CGtk
import CLuma
import Foundation
import Gtk
import LumaCore

@MainActor
final class AddInstrumentDialog {
    typealias OnAdded = (LumaCore.InstrumentInstance) -> Void

    private let dialog: Adw.Dialog
    private let parentWindow: Gtk.Window
    private let descriptors: [LumaCore.InstrumentDescriptor]
    private let disabledDescriptorIDs: Set<String>
    private let incompatibilityReasons: [String: String]
    private let onAdded: OnAdded?
    private let engine: Engine
    private let sessionID: UUID

    private let listBox: ListBox
    private let addButton: Button
    private let detailContainer: Box

    private var selectedIndex: Int?
    private var pendingConfigJSON: Data = Data()
    private var tracerEditor: TracerConfigEditor?
    private var customFeatureEditors: [FeatureValueEditor] = []
    private var hookPackFeatureEditors: [FeatureValueEditor] = []
    private let sharedTracerMonaco: MonacoEditor
    private let sharedCodeShareMonaco: MonacoEditor
    private var rowKinds: [RowKind] = []

    private enum RowKind {
        case descriptor(Int)
        case header
        case newCustom
        case importHookPack
    }

    init(
        parent: Gtk.Window,
        engine: Engine,
        sessionID: UUID,
        descriptors: [LumaCore.InstrumentDescriptor],
        disabledDescriptorIDs: Set<String> = [],
        incompatibilityReasons: [String: String] = [:],
        tracerEditor: MonacoEditor,
        codeShareEditor: MonacoEditor,
        onAdded: OnAdded? = nil
    ) {
        self.descriptors = descriptors
        self.disabledDescriptorIDs = disabledDescriptorIDs
        self.incompatibilityReasons = incompatibilityReasons
        self.onAdded = onAdded
        self.engine = engine
        self.sessionID = sessionID
        self.parentWindow = parent
        self.sharedTracerMonaco = tracerEditor
        self.sharedCodeShareMonaco = codeShareEditor

        dialog = Adw.Dialog()
        dialog.set(title: "Add Instrument")
        dialog.set(contentWidth: 960)
        dialog.set(contentHeight: 720)

        listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")

        addButton = Button(label: "Add")
        addButton.add(cssClass: "suggested-action")
        addButton.sensitive = false

        detailContainer = Box(orientation: .vertical, spacing: 0)
        detailContainer.hexpand = true
        detailContainer.vexpand = true

        let header = Adw.HeaderBar()
        let browseButton = Button(label: "Browse CodeShare\u{2026}")
        browseButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.openCodeShareBrowser() }
        }
        header.packStart(child: browseButton)
        header.packEnd(child: addButton)

        let listScroll = ScrolledWindow()
        listScroll.hexpand = false
        listScroll.vexpand = true
        listScroll.setSizeRequest(width: 280, height: -1)
        listScroll.set(child: listBox)

        let detailScroll = ScrolledWindow()
        detailScroll.hexpand = true
        detailScroll.vexpand = true
        detailScroll.set(child: detailContainer)

        let paned = Paned(orientation: .horizontal)
        paned.position = 280
        paned.hexpand = true
        paned.vexpand = true
        paned.startChild = WidgetRef(listScroll)
        paned.endChild = WidgetRef(detailScroll)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: paned)
        dialog.set(child: toolbarView)
        dialog.set(defaultWidget: addButton)

        var sawCustom = false
        for (descriptorIndex, descriptor) in descriptors.enumerated() {
            if descriptor.kind == .custom, !sawCustom {
                listBox.append(child: makeCustomInstrumentsHeaderRow())
                rowKinds.append(.header)
                sawCustom = true
            }
            let row = makeDescriptorRow(
                descriptor: descriptor,
                alreadyAdded: disabledDescriptorIDs.contains(descriptor.id),
                incompatibilityReason: incompatibilityReasons[descriptor.id]
            )
            listBox.append(child: row)
            rowKinds.append(.descriptor(descriptorIndex))
        }

        if !sawCustom {
            listBox.append(child: makeCustomInstrumentsHeaderRow())
            rowKinds.append(.header)
        }

        let newCustomRow = makeActionRow(iconName: "list-add-symbolic", title: "New Custom Instrument\u{2026}")
        listBox.append(child: newCustomRow)
        rowKinds.append(.newCustom)

        let importHookPackRow = makeActionRow(iconName: "document-save-symbolic", title: "Import from Hookpack\u{2026}")
        listBox.append(child: importHookPackRow)
        rowKinds.append(.importHookPack)

        showPlaceholder(message: "Select an instrument to configure.")

        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let row else {
                    self.selectedIndex = nil
                    self.addButton.sensitive = false
                    self.addButton.label = "Add"
                    self.tracerEditor = nil
                    self.showPlaceholder(message: "Select an instrument to configure.")
                    return
                }
                let kind = self.rowKinds[Int(row.index)]
                switch kind {
                case .header:
                    return
                case .newCustom:
                    self.selectedIndex = nil
                    self.addButton.sensitive = true
                    self.addButton.label = "Add"
                    self.showNewCustomDetail()
                case .importHookPack:
                    self.selectedIndex = nil
                    self.addButton.sensitive = true
                    self.addButton.label = "Choose Folder\u{2026}"
                    self.showImportHookPackDetail()
                case .descriptor(let descriptorIndex):
                    self.selectedIndex = descriptorIndex
                    let descriptor = self.descriptors[descriptorIndex]
                    let reason = self.incompatibilityReasons[descriptor.id]
                    self.addButton.sensitive = reason == nil
                    self.addButton.label = "Add"
                    self.refreshDetail()
                }
            }
        }

        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
    }

    func present() {
        dialog.own(self)
        dialog.present(parent: parentWindow)
    }

    private func makeDescriptorRow(
        descriptor: LumaCore.InstrumentDescriptor,
        alreadyAdded: Bool,
        incompatibilityReason: String?
    ) -> ListBoxRow {
        let row = ListBoxRow()
        let rowBox = Box(orientation: .vertical, spacing: 2)
        rowBox.marginStart = 12
        rowBox.marginEnd = 12
        rowBox.marginTop = 6
        rowBox.marginBottom = 6
        rowBox.valign = .center

        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: InstrumentIconView.makeImage(for: descriptor.icon, pixelSize: 16))
        let label = Label(str: descriptor.displayName)
        label.halign = .start
        label.hexpand = true
        header.append(child: label)
        if let reason = incompatibilityReason {
            let warning = Gtk.Image(iconName: "dialog-warning-symbolic")
            warning.pixelSize = 12
            warning.tooltipText = reason
            header.append(child: warning)
        }
        rowBox.append(child: header)

        if alreadyAdded {
            let hint = Label(str: "Already added")
            hint.halign = .start
            hint.add(cssClass: "caption")
            hint.add(cssClass: "dim-label")
            hint.marginStart = 25
            rowBox.append(child: hint)
            row.sensitive = false
            row.selectable = false
        }
        row.set(child: rowBox)
        return row
    }

    private func makeCustomInstrumentsHeaderRow() -> ListBoxRow {
        let row = ListBoxRow()
        row.sensitive = false
        row.selectable = false
        let label = Label(str: "Custom Instruments")
        label.halign = .start
        label.add(cssClass: "caption-heading")
        label.add(cssClass: "dim-label")
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 14
        label.marginBottom = 4
        row.set(child: label)
        return row
    }

    private func makeActionRow(iconName: String, title: String) -> ListBoxRow {
        let row = ListBoxRow()
        let rowBox = Box(orientation: .horizontal, spacing: 8)
        rowBox.marginStart = 12
        rowBox.marginEnd = 12
        rowBox.marginTop = 6
        rowBox.marginBottom = 6
        rowBox.valign = .center
        let icon = Gtk.Image(iconName: iconName)
        icon.pixelSize = 16
        rowBox.append(child: icon)
        let label = Label(str: title)
        label.halign = .start
        label.hexpand = true
        rowBox.append(child: label)
        row.set(child: rowBox)
        return row
    }

    private func appendIncompatibilityBanner(reason: String) {
        let bar = Box(orientation: .horizontal, spacing: 8)
        bar.add(cssClass: "warning")
        bar.marginStart = 0
        bar.marginEnd = 0
        bar.marginTop = 0
        bar.marginBottom = 0
        let inner = Box(orientation: .horizontal, spacing: 8)
        inner.marginStart = 16
        inner.marginEnd = 16
        inner.marginTop = 10
        inner.marginBottom = 10
        let icon = Gtk.Image(iconName: "dialog-warning-symbolic")
        icon.pixelSize = 16
        inner.append(child: icon)
        let label = Label(str: reason)
        label.halign = .start
        label.wrap = true
        label.xalign = 0
        inner.append(child: label)
        bar.append(child: inner)
        detailContainer.append(child: bar)
    }

    private func close() {
        _ = dialog.close()
    }

    private func clearDetail() {
        tracerEditor = nil
        while let child = detailContainer.firstChild {
            detailContainer.remove(child: child)
        }
        detailContainer.marginStart = 0
        detailContainer.marginEnd = 0
        detailContainer.marginTop = 0
        detailContainer.marginBottom = 0
        detailContainer.spacing = 0
    }

    private func showPlaceholder(message: String) {
        clearDetail()
        let label = Label(str: message)
        label.halign = .center
        label.valign = .center
        label.hexpand = true
        label.vexpand = true
        label.add(cssClass: "dim-label")
        label.marginStart = 24
        label.marginEnd = 24
        label.marginTop = 24
        label.marginBottom = 24
        detailContainer.append(child: label)
    }

    private func refreshDetail() {
        guard let index = selectedIndex, index < descriptors.count else {
            showPlaceholder(message: "Select an instrument to configure.")
            return
        }
        let descriptor = descriptors[index]
        pendingConfigJSON = descriptor.makeInitialConfigJSON()

        clearDetail()

        if let reason = incompatibilityReasons[descriptor.id] {
            appendIncompatibilityBanner(reason: reason)
        }

        switch descriptor.kind {
        case .tracer:
            buildTracerEditor(descriptor: descriptor)
        case .hookPack:
            buildHookPackEditor(descriptor: descriptor)
        case .codeShare:
            buildCodeShareEditor(descriptor: descriptor)
        case .custom:
            buildCustomInstanceEditor(descriptor: descriptor)
        }
    }

    private func buildCustomInstanceEditor(descriptor: LumaCore.InstrumentDescriptor) {
        let outer = Box(orientation: .vertical, spacing: 8)
        outer.hexpand = true
        outer.marginStart = 24
        outer.marginEnd = 24
        outer.marginTop = 16
        outer.marginBottom = 16
        detailContainer.append(child: outer)

        guard let defID = UUID(uuidString: descriptor.sourceIdentifier),
            let def = engine.customInstruments.def(withId: defID),
            let config = try? CustomInstrumentConfig.decode(from: pendingConfigJSON)
        else {
            outer.append(child: errorLabel("Custom instrument not found"))
            return
        }

        let title = Label(str: def.name)
        title.halign = .start
        title.add(cssClass: "title-3")
        outer.append(child: title)

        let header = Label(str: "Features")
        header.halign = .start
        header.add(cssClass: "heading")
        header.marginTop = 8
        outer.append(child: header)

        customFeatureEditors.removeAll()

        if def.features.isEmpty {
            let dim = Label(str: "This custom instrument does not declare any features.")
            dim.add(cssClass: "dim-label")
            dim.halign = .start
            outer.append(child: dim)
        } else {
            for feature in def.features {
                outer.append(child: customFeatureRow(feature: feature, configCapture: config))
            }
        }

        pendingConfigJSON = config.encode()
    }

    private func hookPackFeatureRow(feature: CustomInstrumentDef.Feature, configCapture: HookPackConfig) -> Box {
        let row = Box(orientation: .vertical, spacing: 4)
        row.hexpand = true

        let initialEnabled = configCapture.features[feature.id]?.enabled ?? feature.enabledByDefault
        let initialValue = configCapture.features[feature.id]?.value ?? feature.schema.defaultValue
        let fid = feature.id

        if feature.optional {
            let header = Box(orientation: .horizontal, spacing: 8)
            header.hexpand = true
            let toggle = Switch()
            toggle.active = initialEnabled
            toggle.valign = .center
            header.append(child: toggle)
            let nameLabel = Label(str: feature.name)
            nameLabel.halign = .start
            nameLabel.hexpand = true
            header.append(child: nameLabel)
            row.append(child: header)

            toggle.onStateSet { [weak self] _, state in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    guard var cfg = try? HookPackConfig.decode(from: self.pendingConfigJSON) else { return false }
                    let existingValue = cfg.features[fid]?.value ?? feature.schema.defaultValue
                    cfg.features[fid] = FeatureState(enabled: state, value: existingValue)
                    self.pendingConfigJSON = cfg.encode()
                    return false
                }
            }

            if case .boolean = feature.schema {
                return row
            }
        } else {
            let nameLabel = Label(str: feature.name)
            nameLabel.halign = .start
            row.append(child: nameLabel)
        }

        let editor = FeatureValueEditor(schema: feature.schema, value: initialValue) { [weak self] newValue in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard var cfg = try? HookPackConfig.decode(from: self.pendingConfigJSON) else { return }
                let existingEnabled = cfg.features[fid]?.enabled ?? feature.enabledByDefault
                cfg.features[fid] = FeatureState(enabled: existingEnabled, value: newValue)
                self.pendingConfigJSON = cfg.encode()
            }
        }
        hookPackFeatureEditors.append(editor)
        editor.widget.marginStart = feature.optional ? 28 : 0
        row.append(child: editor.widget)
        return row
    }

    private func customFeatureRow(feature: CustomInstrumentDef.Feature, configCapture: CustomInstrumentConfig) -> Box {
        let row = Box(orientation: .vertical, spacing: 4)
        row.hexpand = true

        let initialEnabled = configCapture.features[feature.id]?.enabled ?? feature.enabledByDefault
        let initialValue = configCapture.features[feature.id]?.value ?? feature.schema.defaultValue
        let fid = feature.id

        if feature.optional {
            let header = Box(orientation: .horizontal, spacing: 8)
            header.hexpand = true
            let toggle = Switch()
            toggle.active = initialEnabled
            toggle.valign = .center
            header.append(child: toggle)
            let nameLabel = Label(str: feature.name)
            nameLabel.halign = .start
            nameLabel.hexpand = true
            header.append(child: nameLabel)
            row.append(child: header)

            toggle.onStateSet { [weak self] _, state in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    guard var cfg = try? CustomInstrumentConfig.decode(from: self.pendingConfigJSON) else { return false }
                    let existingValue = cfg.features[fid]?.value ?? feature.schema.defaultValue
                    cfg.features[fid] = FeatureState(enabled: state, value: existingValue)
                    self.pendingConfigJSON = cfg.encode()
                    return false
                }
            }

            if case .boolean = feature.schema {
                return row
            }
        } else {
            let nameLabel = Label(str: feature.name)
            nameLabel.halign = .start
            row.append(child: nameLabel)
        }

        let editor = FeatureValueEditor(schema: feature.schema, value: initialValue) { [weak self] newValue in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard var cfg = try? CustomInstrumentConfig.decode(from: self.pendingConfigJSON) else { return }
                let existingEnabled = cfg.features[fid]?.enabled ?? feature.enabledByDefault
                cfg.features[fid] = FeatureState(enabled: existingEnabled, value: newValue)
                self.pendingConfigJSON = cfg.encode()
            }
        }
        customFeatureEditors.append(editor)
        editor.widget.marginStart = feature.optional ? 28 : 0
        row.append(child: editor.widget)
        return row
    }

    private func showNewCustomDetail() {
        clearDetail()
        let box = Box(orientation: .vertical, spacing: 12)
        box.halign = .center
        box.valign = .center
        box.hexpand = true
        box.vexpand = true
        box.marginStart = 24
        box.marginEnd = 24
        box.marginTop = 24
        box.marginBottom = 24

        let title = Label(str: "Create a Custom Instrument")
        title.add(cssClass: "title-3")
        box.append(child: title)

        let hint = Label(str: "A custom instrument is a TypeScript snippet saved with the project. After creating you can rename it, choose an icon, and define toggleable features from the sidebar.")
        hint.add(cssClass: "dim-label")
        hint.wrap = true
        hint.justify = .center
        box.append(child: hint)
        detailContainer.append(child: box)
    }

    private func showImportHookPackDetail() {
        clearDetail()
        let box = Box(orientation: .vertical, spacing: 12)
        box.halign = .center
        box.valign = .center
        box.hexpand = true
        box.vexpand = true
        box.marginStart = 24
        box.marginEnd = 24
        box.marginTop = 24
        box.marginBottom = 24

        let title = Label(str: "Import from Hookpack")
        title.add(cssClass: "title-3")
        box.append(child: title)

        let hint = Label(str: "Pick a hookpack folder containing manifest.json and a TypeScript entry file. The hookpack is cloned into the project as a custom instrument with a fresh identity, so subsequent edits stay local.")
        hint.add(cssClass: "dim-label")
        hint.wrap = true
        hint.justify = .center
        box.append(child: hint)
        detailContainer.append(child: box)
    }

    private func buildTracerEditor(descriptor: LumaCore.InstrumentDescriptor) {
        guard let config = try? TracerConfig.decode(from: pendingConfigJSON) else {
            showPlaceholder(message: "Failed to decode tracer config.")
            return
        }
        let editor = TracerConfigEditor(
            engine: engine,
            sessionID: sessionID,
            config: config,
            tracerEditor: sharedTracerMonaco,
            isConfigOnly: true,
            apply: { [weak self] data in
                MainActor.assumeIsolated { self?.pendingConfigJSON = data }
            }
        )
        tracerEditor = editor
        detailContainer.append(child: editor.widget)
    }

    private func buildHookPackEditor(descriptor: LumaCore.InstrumentDescriptor) {
        let outer = Box(orientation: .vertical, spacing: 8)
        outer.hexpand = true
        outer.marginStart = 24
        outer.marginEnd = 24
        outer.marginTop = 16
        outer.marginBottom = 16
        detailContainer.append(child: outer)

        guard
            let config = try? HookPackConfig.decode(from: pendingConfigJSON),
            let pack = engine.hookPacks.pack(withId: descriptor.sourceIdentifier)
        else {
            outer.append(child: errorLabel("Failed to load hook pack"))
            return
        }

        let title = Label(str: pack.manifest.name)
        title.halign = .start
        title.add(cssClass: "title-3")
        outer.append(child: title)

        let idLabel = Label(str: pack.id)
        idLabel.halign = .start
        idLabel.add(cssClass: "caption")
        idLabel.add(cssClass: "dim-label")
        outer.append(child: idLabel)

        let header = Label(str: "Features")
        header.halign = .start
        header.add(cssClass: "heading")
        header.marginTop = 8
        outer.append(child: header)

        if pack.manifest.features.isEmpty {
            let dim = Label(str: "This hook-pack does not declare any features.")
            dim.add(cssClass: "dim-label")
            dim.halign = .start
            outer.append(child: dim)
            pendingConfigJSON = config.encode()
            return
        }

        hookPackFeatureEditors.removeAll()
        for feature in pack.manifest.features {
            outer.append(child: hookPackFeatureRow(feature: feature, configCapture: config))
        }

        pendingConfigJSON = config.encode()
    }

    private func buildCodeShareEditor(descriptor: LumaCore.InstrumentDescriptor) {
        guard let config = try? JSONDecoder().decode(CodeShareConfig.self, from: pendingConfigJSON) else {
            showPlaceholder(message: "Failed to decode codeshare config")
            return
        }

        if config.source.isEmpty {
            showCodeShareEmptyState()
            return
        }

        buildCodeShareForm(descriptor: descriptor, initialConfig: config)
    }

    private func showCodeShareEmptyState() {
        clearDetail()
        addButton.sensitive = false

        let box = Box(orientation: .vertical, spacing: 12)
        box.halign = .center
        box.valign = .center
        box.hexpand = true
        box.vexpand = true
        box.marginStart = 24
        box.marginEnd = 24
        box.marginTop = 24
        box.marginBottom = 24

        let icon = Image(iconName: "cloud-symbolic")
        icon.pixelSize = 48
        icon.add(cssClass: "dim-label")
        box.append(child: icon)

        let title = Label(str: "No snippet loaded")
        title.add(cssClass: "title-3")
        box.append(child: title)

        let hint = Label(str: "Browse CodeShare to pick a snippet to instrument.")
        hint.add(cssClass: "dim-label")
        hint.wrap = true
        hint.justify = .center
        box.append(child: hint)

        let browse = Button(label: "Browse CodeShare\u{2026}")
        browse.add(cssClass: "suggested-action")
        browse.halign = .center
        browse.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.openCodeShareBrowser() }
        }
        box.append(child: browse)

        detailContainer.append(child: box)
    }

    private func buildCodeShareForm(
        descriptor: LumaCore.InstrumentDescriptor,
        initialConfig: CodeShareConfig
    ) {
        var config = initialConfig
        detailContainer.marginStart = 24
        detailContainer.marginEnd = 24
        detailContainer.marginTop = 16
        detailContainer.marginBottom = 16
        detailContainer.spacing = 8

        let title = Label(str: config.name.isEmpty ? descriptor.displayName : config.name)
        title.halign = .start
        title.add(cssClass: "title-3")
        detailContainer.append(child: title)

        if let project = config.project {
            let sub = Label(str: "@\(project.owner)/\(project.slug)")
            sub.halign = .start
            sub.add(cssClass: "caption")
            sub.add(cssClass: "dim-label")
            detailContainer.append(child: sub)
        } else {
            let sub = Label(str: "Local snippet (not published)")
            sub.halign = .start
            sub.add(cssClass: "caption")
            sub.add(cssClass: "dim-label")
            detailContainer.append(child: sub)
        }

        let nameRow = Box(orientation: .horizontal, spacing: 8)
        nameRow.append(child: Label(str: "Name"))
        let nameEntry = Entry()
        nameEntry.text = config.name
        nameEntry.hexpand = true
        nameRow.append(child: nameEntry)
        detailContainer.append(child: nameRow)

        let descRow = Box(orientation: .horizontal, spacing: 8)
        descRow.append(child: Label(str: "Description"))
        let descEntry = Entry()
        descEntry.text = config.description
        descEntry.hexpand = true
        descRow.append(child: descEntry)
        detailContainer.append(child: descRow)

        let codeHeader = Label(str: "Source")
        codeHeader.halign = .start
        codeHeader.add(cssClass: "heading")
        codeHeader.marginTop = 8
        detailContainer.append(child: codeHeader)

        let editorContainer = Box(orientation: .vertical, spacing: 0)
        editorContainer.hexpand = true
        editorContainer.vexpand = true
        editorContainer.setSizeRequest(width: -1, height: 320)
        detailContainer.append(child: editorContainer)

        let editor = sharedCodeShareMonaco
        editor.setProfile(EditorProfile.fridaCodeShare())
        editor.setText(config.source)
        editor.installInto(editorContainer)

        var currentSource = config.source
        let sync: () -> Void = { [weak self] in
            guard let self else { return }
            config.name = nameEntry.text ?? ""
            config.description = descEntry.text ?? ""
            config.source = currentSource
            config.lastReviewedHash = config.currentSourceHash
            if let data = try? JSONEncoder().encode(config) {
                self.pendingConfigJSON = data
            }
        }
        nameEntry.onChanged { _ in MainActor.assumeIsolated { sync() } }
        descEntry.onChanged { _ in MainActor.assumeIsolated { sync() } }
        editor.onTextChanged = { text in
            MainActor.assumeIsolated {
                currentSource = text
                sync()
            }
        }

        sync()
    }

    private func errorLabel(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "error")
        label.halign = .start
        return label
    }

    private func commit() {
        if let row = listBox.selectedRow {
            switch rowKinds[Int(row.index)] {
            case .newCustom:
                commitNewCustom()
                return
            case .importHookPack:
                presentHookPackImportPicker()
                return
            case .header, .descriptor:
                break
            }
        }
        guard let index = selectedIndex, index < descriptors.count else { return }
        let descriptor = descriptors[index]
        let engine = self.engine
        let sessionID = self.sessionID
        let onAdded = self.onAdded
        let configJSON = pendingConfigJSON
        Task { @MainActor in
            let instance = await engine.addInstrument(
                kind: descriptor.kind,
                sourceIdentifier: descriptor.sourceIdentifier,
                configJSON: configJSON,
                sessionID: sessionID
            )
            if let instance {
                onAdded?(instance)
            }
        }
        close()
    }

    private func commitNewCustom() {
        let engine = self.engine
        let sessionID = self.sessionID
        let onAdded = self.onAdded
        Task { @MainActor in
            let def = engine.createCustomInstrument()
            let configJSON = CustomInstrumentConfig(
                defID: def.id,
                features: CustomInstrumentLibrary.initialFeatureStates(for: def)
            ).encode()
            let instance = await engine.addInstrument(
                kind: .custom,
                sourceIdentifier: def.id.uuidString,
                configJSON: configJSON,
                sessionID: sessionID
            )
            if let instance {
                onAdded?(instance)
            }
        }
        close()
    }

    private func presentHookPackImportPicker() {
        guard let parentPtr = parentWindow.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        "Choose hookpack folder".withCString { title in
            luma_folder_dialog_select(parentPtr, title, addInstrumentImportFolderThunk, context)
        }
    }

    fileprivate func handleImportFolder(_ path: String?) {
        guard let path else { return }
        let folderURL = URL(fileURLWithPath: path)
        let engine = self.engine
        let sessionID = self.sessionID
        let onAdded = self.onAdded
        do {
            let def = try engine.forkHookPackToCustomInstrument(folderURL: folderURL)
            Task { @MainActor in
                let configJSON = CustomInstrumentConfig(
                    defID: def.id,
                    features: CustomInstrumentLibrary.initialFeatureStates(for: def)
                ).encode()
                let instance = await engine.addInstrument(
                    kind: .custom,
                    sourceIdentifier: def.id.uuidString,
                    configJSON: configJSON,
                    sessionID: sessionID
                )
                if let instance {
                    onAdded?(instance)
                }
            }
            close()
        } catch {
            presentImportError(message: error.localizedDescription)
        }
    }

    private func presentImportError(message: String) {
        let alert = Adw.AlertDialog(heading: "Import failed", body: message)
        alert.addResponse(id: "ok", label: "OK")
        alert.setDefault(response: "ok")
        alert.setClose(response: "ok")
        alert.present(parent: parentWindow)
    }

    private func openCodeShareBrowser() {
        let parent = parentWindow
        let editor = sharedCodeShareMonaco
        close()
        CodeShareBrowser.present(from: parent, engine: engine, sessionID: sessionID, codeShareEditor: editor)
    }
}

private let addInstrumentImportFolderThunk: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let dialog = Unmanaged<AddInstrumentDialog>.fromOpaque(userData).takeRetainedValue()
    let path = pathPtr.map { String(cString: $0) }
    Task { @MainActor in
        dialog.handleImportFolder(path)
    }
}

