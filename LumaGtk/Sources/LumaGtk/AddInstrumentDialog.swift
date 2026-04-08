import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class AddInstrumentDialog {
    typealias OnAdded = (LumaCore.InstrumentInstance) -> Void

    private let window: Window
    private let parentWindow: Window
    private let descriptors: [LumaCore.InstrumentDescriptor]
    private let disabledDescriptorIDs: Set<String>
    private let onAdded: OnAdded?
    private let engine: Engine
    private let sessionID: UUID

    private let listBox: ListBox
    private let addButton: Button
    private let detailContainer: Box

    private var selectedIndex: Int?
    private var pendingConfigJSON: Data = Data()
    private var tracerEditor: TracerConfigEditor?
    private var monacoEditor: MonacoEditor?

    init(
        parent: Window,
        engine: Engine,
        sessionID: UUID,
        descriptors: [LumaCore.InstrumentDescriptor],
        disabledDescriptorIDs: Set<String> = [],
        onAdded: OnAdded? = nil
    ) {
        self.descriptors = descriptors
        self.disabledDescriptorIDs = disabledDescriptorIDs
        self.onAdded = onAdded
        self.engine = engine
        self.sessionID = sessionID
        self.parentWindow = parent

        window = Window()
        window.title = "Add Instrument"
        window.setDefaultSize(width: 960, height: 720)
        window.modal = true
        window.setTransientFor(parent: parent)
        window.destroyWithParent = true

        listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")

        addButton = Button(label: "Add")
        addButton.add(cssClass: "suggested-action")
        addButton.sensitive = false

        detailContainer = Box(orientation: .vertical, spacing: 0)
        detailContainer.hexpand = true
        detailContainer.vexpand = true

        let header = HeaderBar()
        let cancelButton = Button(label: "Cancel")
        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        header.packStart(child: cancelButton)
        let browseButton = Button(label: "Browse CodeShare\u{2026}")
        browseButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.openCodeShareBrowser() }
        }
        header.packStart(child: browseButton)
        header.packEnd(child: addButton)
        window.set(titlebar: WidgetRef(header))

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
        window.set(child: paned)

        for descriptor in descriptors {
            let row = ListBoxRow()
            let isDisabled = disabledDescriptorIDs.contains(descriptor.id)
            let rowBox = Box(orientation: .vertical, spacing: 2)
            rowBox.marginStart = 12
            rowBox.marginEnd = 12
            rowBox.marginTop = 8
            rowBox.marginBottom = 8
            let label = Label(str: descriptor.displayName)
            label.halign = .start
            rowBox.append(child: label)
            if isDisabled {
                let hint = Label(str: "Already added")
                hint.halign = .start
                hint.add(cssClass: "caption")
                hint.add(cssClass: "dim-label")
                rowBox.append(child: hint)
            }
            row.set(child: rowBox)
            if isDisabled {
                row.sensitive = false
                row.selectable = false
            }
            listBox.append(child: row)
        }

        showPlaceholder(message: "Select an instrument to configure.")

        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let row {
                    self.selectedIndex = Int(row.index)
                    self.addButton.sensitive = true
                    self.refreshDetail()
                } else {
                    self.selectedIndex = nil
                    self.addButton.sensitive = false
                    self.tracerEditor = nil
                    self.showPlaceholder(message: "Select an instrument to configure.")
                }
            }
        }

        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
    }

    func present() {
        Self.retain(dialog: self, window: window)
        installEscapeShortcut(on: window)
        window.present()
    }

    private static var retained: [ObjectIdentifier: AddInstrumentDialog] = [:]

    private static func retain(dialog: AddInstrumentDialog, window: Window) {
        let key = ObjectIdentifier(window)
        retained[key] = dialog
        let handler: (WindowRef) -> Bool = { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
            return false
        }
        window.onCloseRequest(handler: handler)
    }

    private func close() {
        window.destroy()
    }

    private func clearDetail() {
        tracerEditor = nil
        monacoEditor = nil
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

        switch descriptor.kind {
        case .tracer:
            buildTracerEditor(descriptor: descriptor)
        case .hookPack:
            buildHookPackEditor(descriptor: descriptor)
        case .codeShare:
            buildCodeShareEditor(descriptor: descriptor)
        }
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
            var config = try? JSONDecoder().decode(HookPackConfig.self, from: pendingConfigJSON),
            let pack = engine.hookPacks.pack(withId: descriptor.sourceIdentifier)
        else {
            outer.append(child: errorLabel("Failed to load hook pack"))
            return
        }

        let title = Label(str: pack.manifest.name)
        title.halign = .start
        title.add(cssClass: "title-3")
        outer.append(child: title)

        let idLabel = Label(str: pack.manifest.id)
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
            let dim = Label(str: "This hook-pack does not define any configurable features.")
            dim.add(cssClass: "dim-label")
            dim.halign = .start
            outer.append(child: dim)
            try? pendingConfigJSON = JSONEncoder().encode(config)
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
                    guard let self else { return }
                    if state {
                        if config.features[featureID] == nil {
                            config.features[featureID] = FeatureConfig()
                        }
                    } else {
                        config.features.removeValue(forKey: featureID)
                    }
                    if let data = try? JSONEncoder().encode(config) {
                        self.pendingConfigJSON = data
                    }
                }
                return false
            }

            outer.append(child: row)
        }

        if let data = try? JSONEncoder().encode(config) {
            pendingConfigJSON = data
        }
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

        var monacoProfile = MonacoEditorProfile(languageId: "javascript", theme: .dark, fontSize: 13)
        monacoProfile.jsCompilerOptions = MonacoTypings.fridaCompilerOptions
        if let gum = MonacoTypings.fridaGum { monacoProfile.jsExtraLibs.append(gum) }
        let editor = MonacoEditor(profile: monacoProfile, initialText: config.source)
        monacoEditor = editor
        editorContainer.append(child: editor.widget)

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
            onAdded?(instance)
        }
        close()
    }

    private func openCodeShareBrowser() {
        let parent = parentWindow
        close()
        CodeShareBrowser.present(from: parent, engine: engine, sessionID: sessionID)
    }
}

