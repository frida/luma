import Adw
import CLuma
import Foundation
import Frida
import Gtk
import LumaCore
import Pango

@MainActor
final class TargetPicker {
    private static var retained: [ObjectIdentifier: TargetPicker] = [:]

    typealias OnAttach = (_ device: Frida.Device, _ process: ProcessDetails) -> Void
    typealias OnSpawn = (_ device: Frida.Device, _ config: SpawnConfig) -> Void

    private let parent: Gtk.Window
    private let engine: Engine
    private let onAttach: OnAttach
    private let onSpawn: OnSpawn
    private let reason: String?

    private let dialog: Adw.Dialog
    private let deviceList: ListBox
    private let processList: ListBox
    private let processStatus: Label
    private let processLoading: Box
    private let processLoadingSpinner: Gtk.Spinner
    private let processLoadingLabel: Label
    private let processContent: Box
    private let processError: Box
    private let processErrorMessage: Label
    private let processEmpty: Box
    private let processSearchEntry: SearchEntry
    private let attachButton: Button
    private let spawnButton: Button

    private let attachToggle: ToggleButton
    private let spawnToggle: ToggleButton

    private let modeStack: Box
    private let modeHint: Label
    private let attachPane: Box
    private let spawnPane: Box
    private let noDevicePane: Box

    private let submodeAppToggle: ToggleButton
    private let submodeProgramToggle: ToggleButton

    private let appList: ListBox
    private let appSearchEntry: SearchEntry
    private let appStatus: Label
    private let appLoading: Box
    private let appLoadingSpinner: Gtk.Spinner
    private let appLoadingLabel: Label
    private let appContent: Box
    private let appError: Box
    private let appErrorMessage: Label
    private let appEmpty: Box
    private let programPathEntry: Entry
    private let programBrowseButton: Button
    private let programPathRow: Box

    private let appSubmodeForm: SpawnSubmodeForm
    private let programSubmodeForm: SpawnSubmodeForm
    private let spawnFormStack: Box
    private let appFormBox: Box
    private let programFormBox: Box

    private var devices: [Frida.Device] = []
    private var processes: [ProcessDetails] = []
    private var filteredProcesses: [ProcessDetails] = []
    private var applications: [ApplicationDetails] = []
    private var filteredApplications: [ApplicationDetails] = []
    private var snapshotTask: Task<Void, Never>?
    private var processFetchTask: Task<Void, Never>?
    private var appFetchTask: Task<Void, Never>?
    private var selectedDeviceID: String?
    private var selectedProcessIndex: Int?
    private var selectedApplicationIdentifier: String?

    private var pickerState: TargetPickerState
    private var pendingCertificateEntry: Entry?
    private weak var addRemoteSheet: Adw.Dialog?
    private var mode: Mode = .attach
    private var spawnSubmode: SpawnSubmode = .application

    enum Mode: String {
        case attach
        case spawn
    }

    enum SpawnSubmode: String {
        case application
        case program
    }

    init(
        parent: Gtk.Window,
        engine: Engine,
        reason: String? = nil,
        onAttach: @escaping OnAttach,
        onSpawn: @escaping OnSpawn
    ) {
        self.parent = parent
        self.engine = engine
        self.reason = reason
        self.onAttach = onAttach
        self.onSpawn = onSpawn

        self.pickerState = (try? engine.store.fetchTargetPickerState()) ?? TargetPickerState()
        if let raw = pickerState.lastModeRaw, let m = Mode(rawValue: raw) {
            mode = m
        }
        if let raw = pickerState.lastSpawnSubmodeRaw, let s = SpawnSubmode(rawValue: raw) {
            spawnSubmode = s
        }
        selectedDeviceID = pickerState.lastSelectedDeviceID
        selectedApplicationIdentifier = pickerState.lastSpawnApplicationID

        dialog = Adw.Dialog()
        dialog.set(title: reason == nil ? "New Session" : "Re-Establish Session")
        dialog.set(contentWidth: 880)
        dialog.set(contentHeight: 540)

        deviceList = ListBox()
        processList = ListBox()
        processStatus = Label(str: "Select a device to list processes\u{2026}")
        processLoading = Box(orientation: .vertical, spacing: 8)
        processLoadingSpinner = Gtk.Spinner()
        processLoadingLabel = Label(str: "Enumerating processes\u{2026}")
        processContent = Box(orientation: .vertical, spacing: 0)
        processError = Box(orientation: .vertical, spacing: 8)
        processErrorMessage = Label(str: "")
        processEmpty = Box(orientation: .vertical, spacing: 8)
        processSearchEntry = SearchEntry()
        attachButton = Button(label: "Attach")
        spawnButton = Button(label: "Spawn & Attach")

        attachToggle = ToggleButton()
        attachToggle.label = "Attach"
        spawnToggle = ToggleButton()
        spawnToggle.label = "Spawn"
        modeHint = Label(str: "")

        submodeAppToggle = ToggleButton()
        submodeAppToggle.label = "Application"
        submodeProgramToggle = ToggleButton()
        submodeProgramToggle.label = "Program"

        appList = ListBox()
        appSearchEntry = SearchEntry()
        appStatus = Label(str: "Select a device to list applications\u{2026}")
        appLoading = Box(orientation: .vertical, spacing: 8)
        appLoadingSpinner = Gtk.Spinner()
        appLoadingLabel = Label(str: "Enumerating applications\u{2026}")
        appContent = Box(orientation: .vertical, spacing: 0)
        appError = Box(orientation: .vertical, spacing: 8)
        appErrorMessage = Label(str: "")
        appEmpty = Box(orientation: .vertical, spacing: 8)
        programPathEntry = Entry()
        programPathEntry.placeholderText = "Absolute program path, e.g. /usr/bin/foo"
        programPathEntry.hexpand = true
        if let p = pickerState.lastSpawnProgramPath {
            programPathEntry.text = p
        }
        programBrowseButton = Button(label: "Browse\u{2026}")
        programBrowseButton.visible = false
        programPathRow = Box(orientation: .horizontal, spacing: 6)
        programPathRow.append(child: programPathEntry)
        programPathRow.append(child: programBrowseButton)

        appSubmodeForm = SpawnSubmodeForm()
        programSubmodeForm = SpawnSubmodeForm()

        modeStack = Box(orientation: .vertical, spacing: 0)
        attachPane = Box(orientation: .vertical, spacing: 0)
        spawnPane = Box(orientation: .vertical, spacing: 0)
        noDevicePane = Box(orientation: .vertical, spacing: 0)
        spawnFormStack = Box(orientation: .vertical, spacing: 0)
        appFormBox = Box(orientation: .vertical, spacing: 0)
        programFormBox = Box(orientation: .vertical, spacing: 0)

        deviceList.selectionMode = .single
        deviceList.add(cssClass: "navigation-sidebar")
        processList.selectionMode = .single
        appList.selectionMode = .single
        attachButton.sensitive = false
        spawnButton.sensitive = false

        let header = Adw.HeaderBar()
        attachButton.add(cssClass: "suggested-action")
        attachButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commitAttach() }
        }
        spawnButton.add(cssClass: "suggested-action")
        spawnButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commitSpawn() }
        }
        header.packEnd(child: attachButton)
        header.packEnd(child: spawnButton)

        let modeToggles = Box(orientation: .horizontal, spacing: 0)
        modeToggles.add(cssClass: "linked")
        spawnToggle.set(group: ToggleButtonRef(attachToggle.toggle_button_ptr))
        modeToggles.append(child: spawnToggle)
        modeToggles.append(child: attachToggle)

        modeHint.add(cssClass: "caption")
        modeHint.add(cssClass: "dim-label")
        modeHint.halign = .end
        modeHint.valign = .center
        modeHint.hexpand = true
        modeHint.xalign = 1
        modeHint.ellipsize = EllipsizeMode.end

        let modeHeader = Box(orientation: .horizontal, spacing: 12)
        modeHeader.marginStart = 12
        modeHeader.marginEnd = 12
        modeHeader.marginTop = 8
        modeHeader.marginBottom = 4
        modeHeader.append(child: modeToggles)
        modeHeader.append(child: modeHint)

        let paned = Paned(orientation: .horizontal)
        paned.position = 260
        let devicePane = buildDevicePane()
        paned.startChild = WidgetRef(devicePane)

        attachPane.append(child: buildProcessPane())
        spawnPane.append(child: buildSpawnPane())
        noDevicePane.append(child: buildNoDevicePane())

        modeStack.hexpand = true
        modeStack.vexpand = true
        modeStack.append(child: attachPane)
        modeStack.append(child: spawnPane)
        modeStack.append(child: noDevicePane)

        let rightPane = Box(orientation: .vertical, spacing: 0)
        rightPane.hexpand = true
        rightPane.vexpand = true
        rightPane.append(child: modeHeader)
        rightPane.append(child: Separator(orientation: .horizontal))
        rightPane.append(child: modeStack)
        paned.endChild = WidgetRef(rightPane)
        paned.hexpand = true
        paned.vexpand = true

        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true
        if let reason {
            let banner = reason.withCString { Adw.Banner(title: $0) }
            banner.revealed = true
            column.append(child: banner)
        }
        column.append(child: paned)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: column)
        dialog.set(child: toolbarView)

        deviceList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated { self?.handleDeviceRow(row) }
        }
        processList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated { self?.handleProcessRow(row) }
        }
        processList.onRowActivated { [weak self] _, _ in
            MainActor.assumeIsolated { self?.commitAttach() }
        }
        appList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated { self?.handleAppRow(row) }
        }
        appList.onRowActivated { [weak self] _, _ in
            MainActor.assumeIsolated { self?.commitSpawn() }
        }
        processSearchEntry.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.applyProcessFilter(query: entry.text)
            }
        }
        appSearchEntry.onSearchChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.applyAppFilter(query: entry.text)
            }
        }
        attachToggle.onToggled { [weak self] btn in
            MainActor.assumeIsolated {
                guard btn.active else { return }
                self?.setMode(.attach)
            }
        }
        spawnToggle.onToggled { [weak self] btn in
            MainActor.assumeIsolated {
                guard btn.active else { return }
                self?.setMode(.spawn)
            }
        }
        submodeProgramToggle.set(group: ToggleButtonRef(submodeAppToggle.toggle_button_ptr))
        submodeAppToggle.onToggled { [weak self] btn in
            MainActor.assumeIsolated {
                guard btn.active else { return }
                self?.setSpawnSubmode(.application)
            }
        }
        submodeProgramToggle.onToggled { [weak self] btn in
            MainActor.assumeIsolated {
                guard btn.active else { return }
                self?.setSpawnSubmode(.program)
            }
        }
        programPathEntry.onChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.pickerState.lastSpawnProgramPath = entry.text
                self?.refreshSpawnButtonSensitivity()
            }
        }
        programBrowseButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.presentProgramBrowseDialog()
            }
        }

        let key = ObjectIdentifier(dialog)
        TargetPicker.retained[key] = self
        dialog.onClosed { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistState()
                TargetPicker.retained[key] = nil
            }
        }

        if mode == .attach {
            attachToggle.active = true
        } else {
            spawnToggle.active = true
        }
        if spawnSubmode == .application {
            submodeAppToggle.active = true
        } else {
            submodeProgramToggle.active = true
        }
        applySpawnSubmode()
        applyMode()
    }

    func present() {
        dialog.present(parent: parent)
        snapshotTask = Task { @MainActor in
            renderDevices(await engine.deviceManager.currentDevices())
            for await change in await engine.deviceManager.changes() {
                switch change {
                case .appeared(let device):
                    devices.append(device)
                    deviceList.append(child: makeDeviceRow(device))
                    if devices.count == 1, let row = deviceList.getRowAt(index: 0) {
                        deviceList.select(row: row)
                    }
                case .disappeared(let device):
                    if let idx = devices.firstIndex(where: { $0.id == device.id }) {
                        devices.remove(at: idx)
                        if let row = deviceList.getRowAt(index: idx) {
                            deviceList.remove(child: row)
                        }
                    }
                }
            }
        }
    }

    private func close() {
        persistState()
        snapshotTask?.cancel()
        processFetchTask?.cancel()
        appFetchTask?.cancel()
        _ = dialog.close()
    }

    private func presentProgramBrowseDialog() {
        guard let parentPtr = parent.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        "Select program".withCString { title in
            luma_file_dialog_open(parentPtr, title, targetPickerProgramPathThunk, context)
        }
    }

    fileprivate func handleProgramPath(_ path: String) {
        programPathEntry.text = path
        pickerState.lastSpawnProgramPath = path
        refreshSpawnButtonSensitivity()
    }

    private func persistState() {
        pickerState.lastModeRaw = mode.rawValue
        pickerState.lastSpawnSubmodeRaw = spawnSubmode.rawValue
        pickerState.lastSelectedDeviceID = selectedDeviceID
        pickerState.lastSpawnApplicationID = selectedApplicationIdentifier
        pickerState.lastSpawnProgramPath = programPathEntry.text
        if let idx = selectedProcessIndex, idx < processes.count {
            pickerState.lastSelectedProcessName = processes[idx].name
        }
        try? engine.store.save(pickerState)
    }

    // MARK: - Build

    private func buildDevicePane() -> Box {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

        let header = Box(orientation: .horizontal, spacing: 6)
        header.marginStart = 8
        header.marginEnd = 8
        header.marginTop = 6
        header.marginBottom = 6
        let title = Label(str: "Devices")
        title.halign = .start
        title.hexpand = true
        title.add(cssClass: "dim-label")
        header.append(child: title)
        let addRemoteButton = Button(label: "Add Remote\u{2026}")
        addRemoteButton.add(cssClass: "flat")
        addRemoteButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.presentAddRemoteSheet() }
        }
        header.append(child: addRemoteButton)
        column.append(child: header)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: deviceList)
        column.append(child: scroll)
        return column
    }

    private func buildProcessPane() -> Box {
        processStatus.halign = .start
        processStatus.marginStart = 12
        processStatus.marginEnd = 12
        processStatus.marginTop = 8
        processStatus.marginBottom = 4
        processStatus.add(cssClass: "dim-label")
        processStatus.add(cssClass: "caption")
        processStatus.wrap = true
        processStatus.visible = false

        processSearchEntry.placeholderText = "Filter by process name"
        processSearchEntry.marginStart = 12
        processSearchEntry.marginEnd = 12
        processSearchEntry.marginTop = 8
        processSearchEntry.marginBottom = 6

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: processList)

        processContent.hexpand = true
        processContent.vexpand = true
        processContent.append(child: processStatus)
        processContent.append(child: processSearchEntry)
        processContent.append(child: scroll)

        processLoadingSpinner.setSizeRequest(width: 24, height: 24)
        processLoadingLabel.add(cssClass: "dim-label")
        processLoadingLabel.add(cssClass: "caption")
        processLoading.halign = .center
        processLoading.valign = .center
        processLoading.hexpand = true
        processLoading.vexpand = true
        processLoading.append(child: processLoadingSpinner)
        processLoading.append(child: processLoadingLabel)
        processLoading.visible = false

        configureErrorPane(processError, message: processErrorMessage, title: "Failed to Enumerate Processes")
        configureEmptyPane(
            processEmpty,
            icon: "view-list-symbolic",
            title: "No Processes",
            message: "No processes were returned by this device."
        )

        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true
        column.append(child: processContent)
        column.append(child: processLoading)
        column.append(child: processError)
        column.append(child: processEmpty)
        return column
    }

    private func configureEmptyPane(_ pane: Box, icon iconName: String, title: String, message: String) {
        pane.halign = .center
        pane.valign = .center
        pane.hexpand = true
        pane.vexpand = true
        pane.visible = false

        let icon = Image(iconName: iconName)
        icon.set(pixelSize: 36)
        icon.add(cssClass: "dim-label")
        pane.append(child: icon)

        let headline = Label(str: title)
        headline.add(cssClass: "title-4")
        pane.append(child: headline)

        let body = Label(str: message)
        body.halign = .center
        body.justify = .center
        body.wrap = true
        body.add(cssClass: "caption")
        body.add(cssClass: "dim-label")
        body.marginStart = 24
        body.marginEnd = 24
        pane.append(child: body)
    }

    private func configureErrorPane(_ pane: Box, message: Label, title: String) {
        pane.halign = .center
        pane.valign = .center
        pane.hexpand = true
        pane.vexpand = true
        pane.visible = false

        let icon = Image(iconName: "dialog-warning-symbolic")
        icon.set(pixelSize: 36)
        icon.add(cssClass: "warning")
        pane.append(child: icon)

        let headline = Label(str: title)
        headline.add(cssClass: "title-4")
        pane.append(child: headline)

        message.halign = .center
        message.justify = .center
        message.wrap = true
        message.add(cssClass: "caption")
        message.add(cssClass: "dim-label")
        message.marginStart = 24
        message.marginEnd = 24
        pane.append(child: message)
    }

    private func buildSpawnPane() -> Box {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

        column.append(child: buildSpawnHeader())
        column.append(child: Separator(orientation: .horizontal))

        // App form (list at top + shared sections below)
        appStatus.halign = .start
        appStatus.marginStart = 12
        appStatus.marginEnd = 12
        appStatus.marginTop = 8
        appStatus.marginBottom = 4
        appStatus.add(cssClass: "dim-label")
        appStatus.add(cssClass: "caption")
        appStatus.wrap = true
        appStatus.visible = false
        appSearchEntry.placeholderText = "Filter by name or identifier"
        appSearchEntry.marginStart = 12
        appSearchEntry.marginEnd = 12
        appSearchEntry.marginTop = 8
        appSearchEntry.marginBottom = 6
        let appScroll = ScrolledWindow()
        appScroll.hexpand = true
        appScroll.vexpand = true
        appScroll.set(child: appList)
        appContent.hexpand = true
        appContent.vexpand = true
        appContent.append(child: appStatus)
        appContent.append(child: appSearchEntry)
        appContent.append(child: appScroll)

        appLoadingSpinner.setSizeRequest(width: 24, height: 24)
        appLoadingLabel.add(cssClass: "dim-label")
        appLoadingLabel.add(cssClass: "caption")
        appLoading.halign = .center
        appLoading.valign = .center
        appLoading.hexpand = true
        appLoading.vexpand = true
        appLoading.append(child: appLoadingSpinner)
        appLoading.append(child: appLoadingLabel)
        appLoading.visible = false

        configureErrorPane(appError, message: appErrorMessage, title: "Failed to Enumerate Applications")
        configureEmptyPane(
            appEmpty,
            icon: "view-grid-symbolic",
            title: "No Applications",
            message: "This device did not report any launchable applications. On some platforms application spawning is not supported; use Program instead."
        )

        appFormBox.append(child: appContent)
        appFormBox.append(child: appLoading)
        appFormBox.append(child: appError)
        appFormBox.append(child: appEmpty)
        appFormBox.append(child: buildSpawnSubmodeSections(for: appSubmodeForm, isAppMode: true))
        appFormBox.hexpand = true
        appFormBox.vexpand = true

        programFormBox.append(child: buildSpawnSubmodeSections(for: programSubmodeForm, isAppMode: false))
        programFormBox.hexpand = true
        programFormBox.vexpand = false
        programFormBox.valign = .start

        spawnFormStack.hexpand = true
        spawnFormStack.vexpand = true
        spawnFormStack.append(child: appFormBox)
        spawnFormStack.append(child: programFormBox)
        column.append(child: spawnFormStack)

        return column
    }

    private func buildSpawnSubmodeSections(for form: SpawnSubmodeForm, isAppMode: Bool) -> Box {
        let container = Box(orientation: .vertical, spacing: 0)
        container.marginStart = 12
        container.marginEnd = 12
        container.marginTop = 8
        container.marginBottom = 12

        if !isAppMode {
            container.append(child: buildSection(
                title: "Program",
                content: { $0.append(child: self.programPathRow) },
                hint: "Provide an absolute path on the target device, e.g. /usr/bin/foo."
            ))
        }

        let optional = Box(orientation: .vertical, spacing: 0)

        let argsTitle = isAppMode ? "Launch Arguments" : "Arguments"
        let argsHint = isAppMode
            ? "Arguments can be passed to apps too, but are not supported on all targets."
            : "Space-separated arguments. Shell-style quoting may be supported in a future version."
        optional.append(child: buildSection(
            title: argsTitle,
            content: { $0.append(child: form.argumentsEntry) },
            hint: argsHint
        ))

        let envBody = Box(orientation: .vertical, spacing: 4)
        envBody.append(child: form.envListBox)
        let addEnvButton = Button(label: "Add Variable")
        addEnvButton.halign = .start
        addEnvButton.add(cssClass: "flat")
        addEnvButton.onClicked { [weak form] _ in
            MainActor.assumeIsolated { form?.appendEnvRow() }
        }
        envBody.append(child: addEnvButton)
        optional.append(child: buildSection(
            title: "Environment",
            content: { $0.append(child: envBody) },
            hint: "Environment variables are added on top of the default environment."
        ))

        optional.append(child: buildSection(
            title: "Working Directory",
            content: { $0.append(child: form.workingDirEntry) },
            hint: "Use an absolute path on the target device, e.g. /var/mobile."
        ))

        let executionBody = Box(orientation: .vertical, spacing: 8)
        let stdioRow = Box(orientation: .horizontal, spacing: 8)
        let stdioLabel = Label(str: "Stdio")
        stdioLabel.halign = .start
        stdioLabel.valign = .center
        stdioLabel.setSizeRequest(width: 80, height: -1)
        stdioRow.append(child: stdioLabel)
        let stdioToggles = Box(orientation: .horizontal, spacing: 0)
        stdioToggles.add(cssClass: "linked")
        stdioToggles.append(child: form.stdioInheritToggle)
        stdioToggles.append(child: form.stdioPipeToggle)
        stdioRow.append(child: stdioToggles)
        executionBody.append(child: stdioRow)

        let resumeColumn = Box(orientation: .vertical, spacing: 4)
        let resumeRow = Box(orientation: .horizontal, spacing: 8)
        resumeRow.append(child: form.autoResumeSwitch)
        let resumeLabel = Label(str: "Automatically resume after instruments load")
        resumeLabel.halign = .start
        resumeRow.append(child: resumeLabel)
        resumeColumn.append(child: resumeRow)
        let resumeHint = Label(str: "When turned off, the process will remain paused after spawn until you resume it from Luma.")
        resumeHint.halign = .start
        resumeHint.add(cssClass: "caption")
        resumeHint.add(cssClass: "dim-label")
        resumeHint.wrap = true
        resumeColumn.append(child: resumeHint)
        executionBody.append(child: resumeColumn)

        optional.append(child: buildSection(
            title: "Execution",
            content: { $0.append(child: executionBody) }
        ))

        if isAppMode {
            let advanced = Expander(label: "Advanced")
            advanced.marginTop = 4
            advanced.add(cssClass: "luma-spawn-expander")
            advanced.set(child: optional)
            container.append(child: advanced)
        } else {
            container.append(child: optional)
        }

        return container
    }

    private func buildNoDevicePane() -> Box {
        let box = Box(orientation: .vertical, spacing: 8)
        box.halign = .center
        box.valign = .center
        box.hexpand = true
        box.vexpand = true
        box.add(cssClass: "luma-empty-state")

        let icon = Image(iconName: "computer-symbolic")
        icon.set(pixelSize: 48)
        icon.add(cssClass: "dim-label")
        box.append(child: icon)

        let title = Label(str: "Select a Device")
        title.add(cssClass: "title-3")
        box.append(child: title)

        let subtitle = Label(str: "Choose a device on the left to start a new session.")
        subtitle.add(cssClass: "dim-label")
        subtitle.wrap = true
        subtitle.justify = .center
        box.append(child: subtitle)

        return box
    }

    private func buildSpawnHeader() -> Box {
        let row = Box(orientation: .horizontal, spacing: 0)
        row.marginStart = 12
        row.marginEnd = 12
        row.marginTop = 10
        row.marginBottom = 8

        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        row.append(child: spacer)

        let submodeToggles = Box(orientation: .horizontal, spacing: 0)
        submodeToggles.add(cssClass: "linked")
        submodeToggles.valign = .center
        submodeToggles.append(child: submodeAppToggle)
        submodeToggles.append(child: submodeProgramToggle)
        row.append(child: submodeToggles)

        return row
    }

    private func buildSection(
        title: String,
        content: (Box) -> Void,
        hint: String? = nil
    ) -> Box {
        let section = Box(orientation: .vertical, spacing: 4)
        section.marginTop = 4
        section.marginBottom = 12

        let heading = Label(str: title.uppercased())
        heading.halign = .start
        heading.marginStart = 4
        heading.marginBottom = 2
        heading.add(cssClass: "caption-heading")
        heading.add(cssClass: "dim-label")
        section.append(child: heading)

        let body = Box(orientation: .vertical, spacing: 6)
        body.add(cssClass: "luma-section-body")
        content(body)
        section.append(child: body)

        if let hint {
            let hintLabel = Label(str: hint)
            hintLabel.halign = .start
            hintLabel.marginStart = 4
            hintLabel.marginTop = 4
            hintLabel.add(cssClass: "caption")
            hintLabel.add(cssClass: "dim-label")
            hintLabel.wrap = true
            section.append(child: hintLabel)
        }

        return section
    }

    // MARK: - Mode

    private func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        applyMode()
    }

    private func applyMode() {
        let hasDevice = currentDevice() != nil
        attachPane.visible = hasDevice && (mode == .attach)
        spawnPane.visible = hasDevice && (mode == .spawn)
        noDevicePane.visible = !hasDevice
        attachButton.visible = (mode == .attach)
        spawnButton.visible = (mode == .spawn)
        modeHint.label = mode == .spawn
            ? "Spawn a new app or program under Luma."
            : "Attach to an already-running process on this device."
        if mode == .spawn, let device = currentDevice() {
            loadApplications(for: device)
        }
        refreshSpawnButtonSensitivity()
    }

    private func setSpawnSubmode(_ sub: SpawnSubmode) {
        guard spawnSubmode != sub else { return }
        spawnSubmode = sub
        applySpawnSubmode()
        refreshSpawnButtonSensitivity()
    }

    private func applySpawnSubmode() {
        appFormBox.visible = (spawnSubmode == .application)
        programFormBox.visible = (spawnSubmode == .program)
        spawnFormStack.vexpand = (spawnSubmode == .application)
    }

    private func refreshSpawnButtonSensitivity() {
        guard mode == .spawn else {
            spawnButton.sensitive = false
            return
        }
        guard currentDevice() != nil else {
            spawnButton.sensitive = false
            return
        }
        switch spawnSubmode {
        case .application:
            spawnButton.sensitive = (selectedApplicationIdentifier != nil)
        case .program:
            spawnButton.sensitive = !programPathEntry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Devices

    private func currentDevice() -> Frida.Device? {
        guard let id = selectedDeviceID else { return nil }
        return devices.first(where: { $0.id == id })
    }

    private func renderDevices(_ snapshot: [Frida.Device]) {
        devices = snapshot
        deviceList.removeAll()
        for device in snapshot {
            deviceList.append(child: makeDeviceRow(device))
        }
        let preferredID =
            selectedDeviceID
            ?? pickerState.lastSelectedDeviceID
            ?? snapshot.first(where: { $0.kind == .local })?.id
            ?? snapshot.first?.id
        if let target = preferredID,
            let index = snapshot.firstIndex(where: { $0.id == target }),
            let row = deviceList.getRowAt(index: index)
        {
            deviceList.select(row: row)
        }
    }

    private func makeDeviceRow(_ device: Frida.Device) -> ListBoxRow {
        let row = ListBoxRow()
        let hbox = Box(orientation: .horizontal, spacing: 8)
        hbox.marginStart = 12
        hbox.marginEnd = 12
        hbox.marginTop = 6
        hbox.marginBottom = 6
        let icon: Gtk.Image
        if let fridaIcon = device.icon, let img = IconPixbuf.makeImage(from: fridaIcon, pixelSize: 24) {
            icon = img
        } else {
            let kindIcon: String
            switch device.kind {
            case .local: kindIcon = "computer-symbolic"
            case .usb: kindIcon = "drive-harddisk-usb-symbolic"
            case .remote: kindIcon = "network-wired-symbolic"
            }
            icon = Gtk.Image(iconName: kindIcon)
        }
        hbox.append(child: icon)
        let textBox = Box(orientation: .vertical, spacing: 0)
        let nameLabel = Label(str: device.name)
        nameLabel.halign = .start
        let idLabel = Label(str: device.id)
        idLabel.halign = .start
        idLabel.add(cssClass: "dim-label")
        idLabel.add(cssClass: "caption")
        textBox.append(child: nameLabel)
        textBox.append(child: idLabel)
        hbox.append(child: textBox)
        row.set(child: hbox)
        return row
    }

    private func handleDeviceRow(_ row: ListBoxRowRef?) {
        guard let row else {
            selectedDeviceID = nil
            programBrowseButton.visible = false
            applyMode()
            return
        }
        let index = Int(row.index)
        guard index >= 0, index < devices.count else { return }
        let device = devices[index]
        selectedDeviceID = device.id
        programBrowseButton.visible = (device.id == "local")
        applyMode()
        loadProcesses(for: device)
        if mode == .spawn {
            loadApplications(for: device)
        }
        refreshSpawnButtonSensitivity()
    }

    // MARK: - Processes

    private func loadProcesses(for device: Frida.Device) {
        processList.removeAll()
        processes = []
        filteredProcesses = []
        selectedProcessIndex = nil
        attachButton.sensitive = false
        setProcessState(.loading, deviceName: device.name)

        processFetchTask?.cancel()
        let capturedID = device.id
        processFetchTask = Task { @MainActor in
            do {
                let result = try await device.enumerateProcesses(scope: .full)
                guard !Task.isCancelled, self.selectedDeviceID == capturedID else { return }
                self.setProcessState(result.isEmpty ? .empty : .content, deviceName: device.name)
                self.renderProcesses(result, for: device)
            } catch {
                guard !Task.isCancelled, self.selectedDeviceID == capturedID else { return }
                self.processErrorMessage.setText(str: error.localizedDescription)
                self.setProcessState(.error, deviceName: device.name)
            }
        }
    }

    private enum ListPaneState {
        case content
        case loading
        case error
        case empty
    }

    private func setProcessState(_ state: ListPaneState, deviceName: String) {
        processLoadingLabel.setText(str: "Enumerating processes on \(deviceName)\u{2026}")
        processLoadingSpinner.spinning = (state == .loading)
        if state == .loading { processLoadingSpinner.start() } else { processLoadingSpinner.stop() }
        processContent.visible = (state == .content)
        processLoading.visible = (state == .loading)
        processError.visible = (state == .error)
        processEmpty.visible = (state == .empty)
    }

    private func renderProcesses(_ snapshot: [ProcessDetails], for device: Frida.Device) {
        let sorted = snapshot.sorted {
            let aHasIcon = !$0.icons.isEmpty
            let bHasIcon = !$1.icons.isEmpty
            if aHasIcon != bHasIcon {
                return aHasIcon
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        processes = sorted
        applyProcessFilter(query: processSearchEntry.text)
        processStatus.visible = false

        if let savedName = pickerState.lastSelectedProcessName,
            let idx = filteredProcesses.firstIndex(where: { $0.name == savedName }),
            let row = processList.getRowAt(index: idx)
        {
            processList.select(row: row)
        }
    }

    private func applyProcessFilter(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            filteredProcesses = processes
        } else {
            filteredProcesses = processes.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
            }
        }
        processList.removeAll()
        for proc in filteredProcesses {
            let row = ListBoxRow()
            let hbox = Box(orientation: .horizontal, spacing: 8)
            hbox.marginStart = 12
            hbox.marginEnd = 12
            hbox.marginTop = 4
            hbox.marginBottom = 4
            if let fridaIcon = proc.icons.last, let img = IconPixbuf.makeImage(from: fridaIcon, pixelSize: 24) {
                hbox.append(child: img)
            }
            let textBox = Box(orientation: .vertical, spacing: 0)
            textBox.valign = .center
            let nameLabel = Label(str: proc.name)
            nameLabel.halign = .start
            nameLabel.ellipsize = EllipsizeMode.end
            let pidLabel = Label(str: "PID \(proc.pid)")
            pidLabel.halign = .start
            pidLabel.add(cssClass: "dim-label")
            pidLabel.add(cssClass: "caption")
            textBox.append(child: nameLabel)
            textBox.append(child: pidLabel)
            hbox.append(child: textBox)
            row.set(child: hbox)
            processList.append(child: row)
        }
        selectedProcessIndex = nil
        attachButton.sensitive = false
    }

    private func handleProcessRow(_ row: ListBoxRowRef?) {
        guard let row else {
            selectedProcessIndex = nil
            attachButton.sensitive = false
            return
        }
        let index = Int(row.index)
        guard index >= 0, index < filteredProcesses.count else { return }
        selectedProcessIndex = index
        attachButton.sensitive = true
    }

    // MARK: - Applications

    private func loadApplications(for device: Frida.Device) {
        appList.removeAll()
        applications = []
        filteredApplications = []
        setAppState(.loading, deviceName: device.name)

        appFetchTask?.cancel()
        let capturedID = device.id
        appFetchTask = Task { @MainActor in
            do {
                let result = try await device.enumerateApplications(scope: .full)
                guard !Task.isCancelled, self.selectedDeviceID == capturedID else { return }
                self.setAppState(result.isEmpty ? .empty : .content, deviceName: device.name)
                self.renderApplications(result, for: device)
            } catch {
                guard !Task.isCancelled, self.selectedDeviceID == capturedID else { return }
                self.appErrorMessage.setText(str: error.localizedDescription)
                self.setAppState(.error, deviceName: device.name)
            }
        }
    }

    private func setAppState(_ state: ListPaneState, deviceName: String) {
        appLoadingLabel.setText(str: "Enumerating applications on \(deviceName)\u{2026}")
        appLoadingSpinner.spinning = (state == .loading)
        if state == .loading { appLoadingSpinner.start() } else { appLoadingSpinner.stop() }
        appContent.visible = (state == .content)
        appLoading.visible = (state == .loading)
        appError.visible = (state == .error)
        appEmpty.visible = (state == .empty)
    }

    private func renderApplications(_ snapshot: [ApplicationDetails], for device: Frida.Device) {
        let sorted = snapshot.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        applications = sorted
        appStatus.visible = false
        applyAppFilter(query: appSearchEntry.text)

        if let saved = selectedApplicationIdentifier ?? pickerState.lastSpawnApplicationID,
            let idx = filteredApplications.firstIndex(where: { $0.identifier == saved }),
            let row = appList.getRowAt(index: idx)
        {
            appList.select(row: row)
        }
    }

    private func applyAppFilter(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            filteredApplications = applications
        } else {
            filteredApplications = applications.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.identifier.localizedCaseInsensitiveContains(trimmed)
            }
        }
        appList.removeAll()
        for app in filteredApplications {
            let row = ListBoxRow()
            let hbox = Box(orientation: .horizontal, spacing: 8)
            hbox.marginStart = 12
            hbox.marginEnd = 12
            hbox.marginTop = 4
            hbox.marginBottom = 4
            if let fridaIcon = app.icons.last, let img = IconPixbuf.makeImage(from: fridaIcon, pixelSize: 24) {
                hbox.append(child: img)
            }
            let textBox = Box(orientation: .vertical, spacing: 0)
            textBox.hexpand = true
            textBox.valign = .center
            let nameLabel = Label(str: app.name)
            nameLabel.halign = .start
            nameLabel.ellipsize = EllipsizeMode.end
            let idLabel = Label(str: app.identifier)
            idLabel.halign = .start
            idLabel.ellipsize = EllipsizeMode.end
            idLabel.add(cssClass: "dim-label")
            idLabel.add(cssClass: "caption")
            textBox.append(child: nameLabel)
            textBox.append(child: idLabel)
            hbox.append(child: textBox)
            if let pid = app.pid {
                let badge = Label(str: "Running (PID \(pid))")
                badge.add(cssClass: "caption")
                badge.add(cssClass: "luma-pid-badge")
                badge.valign = .center
                hbox.append(child: badge)
            }
            row.set(child: hbox)
            appList.append(child: row)
        }
    }

    private func handleAppRow(_ row: ListBoxRowRef?) {
        guard let row else {
            selectedApplicationIdentifier = nil
            refreshSpawnButtonSensitivity()
            return
        }
        let index = Int(row.index)
        guard index >= 0, index < filteredApplications.count else { return }
        selectedApplicationIdentifier = filteredApplications[index].identifier
        refreshSpawnButtonSensitivity()
    }

    // MARK: - Commit

    private func commitAttach() {
        guard let device = currentDevice(),
            let processIndex = selectedProcessIndex,
            processIndex < filteredProcesses.count
        else { return }
        let process = filteredProcesses[processIndex]
        pickerState.lastSelectedProcessName = process.name
        persistState()
        onAttach(device, process)
        snapshotTask?.cancel()
        processFetchTask?.cancel()
        appFetchTask?.cancel()
        _ = dialog.close()
    }

    private func commitSpawn() {
        guard let device = currentDevice() else { return }
        let target: SpawnConfig.Target
        let form: SpawnSubmodeForm
        switch spawnSubmode {
        case .application:
            guard let identifier = selectedApplicationIdentifier,
                let app = applications.first(where: { $0.identifier == identifier })
            else { return }
            target = .application(identifier: app.identifier, name: app.name)
            form = appSubmodeForm
        case .program:
            let path = programPathEntry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            target = .program(path: path)
            form = programSubmodeForm
        }
        let config = SpawnConfig(
            target: target,
            arguments: form.arguments(),
            environment: form.environment(),
            workingDirectory: form.workingDirectory(),
            stdio: form.stdio(),
            autoResume: form.autoResume()
        )
        persistState()
        onSpawn(device, config)
        snapshotTask?.cancel()
        processFetchTask?.cancel()
        appFetchTask?.cancel()
        _ = dialog.close()
    }

    // MARK: - Add Remote sheet

    private func presentAddRemoteSheet() {
        let sheet = Adw.Dialog()
        sheet.set(title: "Add Remote Device")
        sheet.set(contentWidth: 460)

        let header = Adw.HeaderBar()
        let connectButton = Button(label: "Connect")
        connectButton.add(cssClass: "suggested-action")
        header.packEnd(child: connectButton)

        let body = Box(orientation: .vertical, spacing: 8)
        body.marginStart = 16
        body.marginEnd = 16
        body.marginTop = 12
        body.marginBottom = 12

        let intro = Label(str: "Enter the address of a frida-server or portal.")
        intro.halign = .start
        intro.add(cssClass: "dim-label")
        body.append(child: intro)

        let addressEntry = Entry()
        addressEntry.placeholderText = "hostname:port"
        body.append(child: labeledRow("Address", entry: addressEntry))

        let certificateEntry = Entry()
        certificateEntry.placeholderText = "PEM file path (optional)"
        let certificateBrowseButton = Button(label: "Browse\u{2026}")
        certificateBrowseButton.onClicked { [weak self, weak certificateEntry] _ in
            MainActor.assumeIsolated {
                guard let self, let certificateEntry else { return }
                self.presentCertificateBrowseDialog(into: certificateEntry)
            }
        }
        body.append(child: labeledRow("Certificate", entry: certificateEntry, trailing: certificateBrowseButton))
        self.addRemoteSheet = sheet

        let advBody = Box(orientation: .vertical, spacing: 8)
        let originEntry = Entry()
        originEntry.placeholderText = "Origin (optional)"
        advBody.append(child: labeledRow("Origin", entry: originEntry))
        let tokenEntry = Entry()
        tokenEntry.placeholderText = "Token (optional)"
        advBody.append(child: labeledRow("Token", entry: tokenEntry))
        let keepaliveEntry = Entry()
        keepaliveEntry.placeholderText = "Keepalive seconds (optional)"
        advBody.append(child: labeledRow("Keepalive", entry: keepaliveEntry))

        let advExpander = Expander(label: "Advanced Options")
        advExpander.set(child: advBody)
        body.append(child: advExpander)

        let errorLabel = Label(str: "")
        errorLabel.halign = .start
        errorLabel.wrap = true
        errorLabel.visible = false
        errorLabel.add(cssClass: "error")
        body.append(child: errorLabel)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: body)
        sheet.set(child: toolbarView)
        sheet.set(defaultWidget: connectButton)

        connectButton.onClicked { [weak self, sheet] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let address = addressEntry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !address.isEmpty else {
                    errorLabel.setText(str: "Address is required.")
                    errorLabel.visible = true
                    return
                }
                let certificate = certificateEntry.text.isEmpty ? nil : certificateEntry.text
                let origin = originEntry.text.isEmpty ? nil : originEntry.text
                let token = tokenEntry.text.isEmpty ? nil : tokenEntry.text
                let keepalive: Int? = {
                    let trimmed = keepaliveEntry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return nil }
                    return Int(trimmed)
                }()
                connectButton.sensitive = false
                Task { @MainActor in
                    do {
                        _ = try await self.engine.deviceManager.addRemoteDevice(
                            address: address,
                            certificate: certificate,
                            origin: origin,
                            token: token,
                            keepaliveInterval: keepalive
                        )
                        let config = LumaCore.RemoteDeviceConfig(
                            address: address,
                            certificate: certificate,
                            origin: origin,
                            token: token,
                            keepaliveInterval: keepalive
                        )
                        try? self.engine.store.save(config)
                        _ = sheet.close()
                    } catch {
                        errorLabel.setText(str: "\(error)")
                        errorLabel.visible = true
                        connectButton.sensitive = true
                    }
                }
            }
        }

        sheet.present(parent: dialog)
    }

    private func labeledRow(_ title: String, entry: Entry, trailing: Button? = nil) -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        let label = Label(str: title)
        label.halign = .start
        label.setSizeRequest(width: 100, height: -1)
        row.append(child: label)
        entry.hexpand = true
        row.append(child: entry)
        if let trailing {
            row.append(child: trailing)
        }
        return row
    }

    private func presentCertificateBrowseDialog(into entry: Entry) {
        guard let parentPtr = parent.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        pendingCertificateEntry = entry
        let context = Unmanaged.passRetained(self).toOpaque()
        "Select certificate".withCString { title in
            luma_file_dialog_open(parentPtr, title, targetPickerCertificatePathThunk, context)
        }
    }

    fileprivate func handleCertificatePath(_ path: String) {
        pendingCertificateEntry?.text = path
        pendingCertificateEntry = nil
    }

    fileprivate func clearPendingCertificateEntry() {
        pendingCertificateEntry = nil
    }
}

private let targetPickerProgramPathThunk: @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    let pathString: String? = pathPtr.map { String(cString: $0) }
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let picker = Unmanaged<TargetPicker>.fromOpaque(ptr).takeRetainedValue()
        if let pathString {
            picker.handleProgramPath(pathString)
        }
    }
}

private let targetPickerCertificatePathThunk: @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    let pathString: String? = pathPtr.map { String(cString: $0) }
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let picker = Unmanaged<TargetPicker>.fromOpaque(ptr).takeRetainedValue()
        if let pathString {
            picker.handleCertificatePath(pathString)
        } else {
            picker.clearPendingCertificateEntry()
        }
    }
}

@MainActor
private final class SpawnSubmodeForm {
    let argumentsEntry: Entry
    let workingDirEntry: Entry
    let envListBox: Box
    let stdioInheritToggle: ToggleButton
    let stdioPipeToggle: ToggleButton
    let autoResumeSwitch: Switch

    private var envRowWidgets: [(row: Box, key: Entry, value: Entry)] = []
    private var envPairs: [(String, String)] = []

    init() {
        argumentsEntry = Entry()
        argumentsEntry.placeholderText = "Arguments (optional)"
        argumentsEntry.hexpand = true
        workingDirEntry = Entry()
        workingDirEntry.placeholderText = "Working directory (optional)"
        workingDirEntry.hexpand = true
        envListBox = Box(orientation: .vertical, spacing: 4)
        envListBox.hexpand = true
        stdioInheritToggle = ToggleButton()
        stdioInheritToggle.label = "Inherit"
        stdioPipeToggle = ToggleButton()
        stdioPipeToggle.label = "Pipe to Luma"
        stdioPipeToggle.set(group: ToggleButtonRef(stdioInheritToggle.toggle_button_ptr))
        stdioPipeToggle.active = true
        autoResumeSwitch = Switch()
        autoResumeSwitch.active = true
        autoResumeSwitch.valign = .center
    }

    func arguments() -> [String] {
        argumentsEntry.text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    func environment() -> [String: String] {
        var out: [String: String] = [:]
        for (rawKey, value) in envPairs {
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out[key] = value
        }
        return out
    }

    func workingDirectory() -> String? {
        let trimmed = workingDirEntry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func stdio() -> Frida.Stdio {
        stdioPipeToggle.active ? .pipe : .inherit
    }

    func autoResume() -> Bool {
        autoResumeSwitch.active
    }

    func appendEnvRow(key: String = "", value: String = "") {
        let index = envPairs.count
        envPairs.append((key, value))

        let row = Box(orientation: .horizontal, spacing: 6)
        let keyEntry = Entry()
        keyEntry.placeholderText = "KEY"
        keyEntry.text = key
        keyEntry.hexpand = true
        let valueEntry = Entry()
        valueEntry.placeholderText = "value"
        valueEntry.text = value
        valueEntry.hexpand = true
        let removeButton = Button()
        removeButton.set(iconName: "list-remove-symbolic")
        removeButton.add(cssClass: "flat")
        row.append(child: keyEntry)
        row.append(child: valueEntry)
        row.append(child: removeButton)

        keyEntry.onChanged { [weak self, weak row] entry in
            MainActor.assumeIsolated {
                guard let self, let rowRef = row else { return }
                if let i = self.envRowWidgets.firstIndex(where: { $0.row === rowRef }) {
                    self.envPairs[i].0 = entry.text
                }
            }
        }
        valueEntry.onChanged { [weak self, weak row] entry in
            MainActor.assumeIsolated {
                guard let self, let rowRef = row else { return }
                if let i = self.envRowWidgets.firstIndex(where: { $0.row === rowRef }) {
                    self.envPairs[i].1 = entry.text
                }
            }
        }
        removeButton.onClicked { [weak self, weak row] _ in
            MainActor.assumeIsolated {
                guard let self, let rowRef = row else { return }
                if let i = self.envRowWidgets.firstIndex(where: { $0.row === rowRef }) {
                    self.envPairs.remove(at: i)
                    self.envListBox.remove(child: rowRef)
                    self.envRowWidgets.remove(at: i)
                }
            }
        }

        envListBox.append(child: row)
        envRowWidgets.insert((row: row, key: keyEntry, value: valueEntry), at: index)
    }
}
