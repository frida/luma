import Foundation
import Frida
import Gtk
import LumaCore

@MainActor
final class TargetPicker {
    typealias OnAttach = (_ device: Frida.Device, _ process: ProcessDetails) -> Void
    typealias OnSpawn = (_ device: Frida.Device, _ config: SpawnConfig) -> Void

    private let parent: Window
    private let engine: Engine
    private let onAttach: OnAttach
    private let onSpawn: OnSpawn
    private let reason: String?

    private let window: Window
    private let deviceList: ListBox
    private let processList: ListBox
    private let processStatus: Label
    private let processSearchEntry: SearchEntry
    private let attachButton: Button
    private let spawnButton: Button

    private let attachToggle: ToggleButton
    private let spawnToggle: ToggleButton

    private let modeStack: Box
    private let attachPane: Box
    private let spawnPane: Box

    private let submodeAppToggle: ToggleButton
    private let submodeProgramToggle: ToggleButton

    private let appList: ListBox
    private let appSearchEntry: SearchEntry
    private let appStatus: Label
    private let programPathEntry: Entry
    private let argumentsEntry: Entry
    private let workingDirEntry: Entry
    private let envEntry: Entry
    private let autoResumeSwitch: Switch
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
        parent: Window,
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

        window = Window()
        window.title = reason == nil ? "New Session" : "Re-Establish Session"
        window.setDefaultSize(width: 880, height: 540)
        window.modal = true
        window.setTransientFor(parent: parent)
        window.destroyWithParent = true

        deviceList = ListBox()
        processList = ListBox()
        processStatus = Label(str: "Select a device to list processes\u{2026}")
        processSearchEntry = SearchEntry()
        attachButton = Button(label: "Attach")
        spawnButton = Button(label: "Spawn & Attach")

        attachToggle = ToggleButton()
        attachToggle.label = "Attach"
        spawnToggle = ToggleButton()
        spawnToggle.label = "Spawn"

        submodeAppToggle = ToggleButton()
        submodeAppToggle.label = "Application"
        submodeProgramToggle = ToggleButton()
        submodeProgramToggle.label = "Program"

        appList = ListBox()
        appSearchEntry = SearchEntry()
        appStatus = Label(str: "Select a device to list applications\u{2026}")
        programPathEntry = Entry()
        programPathEntry.placeholderText = "Absolute program path, e.g. /usr/bin/foo"
        if let p = pickerState.lastSpawnProgramPath {
            programPathEntry.text = p
        }
        argumentsEntry = Entry()
        argumentsEntry.placeholderText = "Arguments (space-separated, optional)"
        workingDirEntry = Entry()
        workingDirEntry.placeholderText = "Working directory (optional)"
        envEntry = Entry()
        envEntry.placeholderText = "KEY=value KEY2=value2 (optional)"
        autoResumeSwitch = Switch()
        autoResumeSwitch.active = true
        autoResumeSwitch.valign = .center

        modeStack = Box(orientation: .vertical, spacing: 0)
        attachPane = Box(orientation: .vertical, spacing: 0)
        spawnPane = Box(orientation: .vertical, spacing: 0)
        spawnFormStack = Box(orientation: .vertical, spacing: 0)
        appFormBox = Box(orientation: .vertical, spacing: 0)
        programFormBox = Box(orientation: .vertical, spacing: 0)

        deviceList.selectionMode = .single
        deviceList.add(cssClass: "navigation-sidebar")
        processList.selectionMode = .single
        appList.selectionMode = .single
        attachButton.sensitive = false
        spawnButton.sensitive = false

        let header = HeaderBar()
        let cancelButton = Button(label: "Cancel")
        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        header.packStart(child: cancelButton)
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
        window.set(titlebar: WidgetRef(header))

        let modeRow = Box(orientation: .horizontal, spacing: 0)
        modeRow.halign = .center
        modeRow.marginTop = 10
        modeRow.marginBottom = 6
        modeRow.add(cssClass: "linked")
        spawnToggle.set(group: ToggleButtonRef(attachToggle.toggle_button_ptr))
        modeRow.append(child: attachToggle)
        modeRow.append(child: spawnToggle)

        let paned = Paned(orientation: .horizontal)
        paned.position = 260
        let devicePane = buildDevicePane()
        paned.startChild = WidgetRef(devicePane)

        attachPane.append(child: buildProcessPane())
        spawnPane.append(child: buildSpawnPane())

        modeStack.hexpand = true
        modeStack.vexpand = true
        modeStack.append(child: attachPane)
        modeStack.append(child: spawnPane)
        paned.endChild = WidgetRef(modeStack)
        paned.hexpand = true
        paned.vexpand = true

        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true
        if let reason {
            let banner = Label(str: reason)
            banner.add(cssClass: "luma-banner")
            banner.add(cssClass: "luma-banner-warning")
            banner.halign = .start
            banner.marginStart = 16
            banner.marginEnd = 16
            banner.marginTop = 10
            banner.marginBottom = 10
            banner.wrap = true
            banner.hexpand = true
            column.append(child: banner)
        }
        column.append(child: modeRow)
        column.append(child: paned)
        window.set(child: column)

        deviceList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated { self?.handleDeviceRow(row) }
        }
        processList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated { self?.handleProcessRow(row) }
        }
        appList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated { self?.handleAppRow(row) }
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

        window.onCloseRequest { [weak self] _ in
            MainActor.assumeIsolated { self?.persistState() }
            return false
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
        applyMode()
    }

    func present() {
        window.present()
        snapshotTask = Task { @MainActor in
            renderDevices(await engine.deviceManager.currentDevices())
            for await snapshot in await engine.deviceManager.snapshots() {
                renderDevices(snapshot)
            }
        }
    }

    private func close() {
        persistState()
        snapshotTask?.cancel()
        processFetchTask?.cancel()
        appFetchTask?.cancel()
        window.destroy()
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

        processSearchEntry.placeholderText = "Filter by process name"
        processSearchEntry.marginStart = 12
        processSearchEntry.marginEnd = 12
        processSearchEntry.marginTop = 4
        processSearchEntry.marginBottom = 6

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: processList)

        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true
        column.append(child: processStatus)
        column.append(child: processSearchEntry)
        column.append(child: scroll)
        return column
    }

    private func buildSpawnPane() -> Box {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

        let submodeRow = Box(orientation: .horizontal, spacing: 0)
        submodeRow.halign = .center
        submodeRow.marginTop = 8
        submodeRow.marginBottom = 8
        submodeRow.add(cssClass: "linked")
        submodeRow.append(child: submodeAppToggle)
        submodeRow.append(child: submodeProgramToggle)
        column.append(child: submodeRow)

        // App form
        appStatus.halign = .start
        appStatus.marginStart = 12
        appStatus.marginEnd = 12
        appStatus.marginTop = 4
        appStatus.marginBottom = 4
        appSearchEntry.placeholderText = "Filter by name or identifier"
        appSearchEntry.marginStart = 12
        appSearchEntry.marginEnd = 12
        appSearchEntry.marginBottom = 6
        let appScroll = ScrolledWindow()
        appScroll.hexpand = true
        appScroll.vexpand = true
        appScroll.set(child: appList)
        appFormBox.append(child: appStatus)
        appFormBox.append(child: appSearchEntry)
        appFormBox.append(child: appScroll)
        appFormBox.hexpand = true
        appFormBox.vexpand = true

        // Program form
        let programNote = Label(str: "Provide an absolute path on the target device.")
        programNote.halign = .start
        programNote.add(cssClass: "dim-label")
        programNote.marginStart = 12
        programNote.marginEnd = 12
        programNote.marginTop = 4
        programNote.marginBottom = 4
        programPathEntry.marginStart = 12
        programPathEntry.marginEnd = 12
        programPathEntry.marginBottom = 6
        programFormBox.append(child: programNote)
        programFormBox.append(child: programPathEntry)
        programFormBox.hexpand = true
        programFormBox.vexpand = true

        spawnFormStack.hexpand = true
        spawnFormStack.vexpand = true
        spawnFormStack.append(child: appFormBox)
        spawnFormStack.append(child: programFormBox)
        column.append(child: spawnFormStack)

        // Spawn options + Advanced
        let argsRow = Box(orientation: .horizontal, spacing: 8)
        argsRow.marginStart = 12
        argsRow.marginEnd = 12
        argsRow.marginTop = 6
        argsRow.marginBottom = 4
        let argsLabel = Label(str: "Arguments")
        argsLabel.halign = .start
        argsLabel.setSizeRequest(width: 110, height: -1)
        argsRow.append(child: argsLabel)
        argumentsEntry.hexpand = true
        argsRow.append(child: argumentsEntry)
        column.append(child: argsRow)

        let advBody = Box(orientation: .vertical, spacing: 6)
        advBody.marginStart = 12
        advBody.marginEnd = 12
        advBody.marginTop = 6
        advBody.marginBottom = 6

        let envRow = Box(orientation: .horizontal, spacing: 8)
        let envLabel = Label(str: "Environment")
        envLabel.halign = .start
        envLabel.setSizeRequest(width: 110, height: -1)
        envRow.append(child: envLabel)
        envEntry.hexpand = true
        envRow.append(child: envEntry)
        advBody.append(child: envRow)

        let cwdRow = Box(orientation: .horizontal, spacing: 8)
        let cwdLabel = Label(str: "Working dir")
        cwdLabel.halign = .start
        cwdLabel.setSizeRequest(width: 110, height: -1)
        cwdRow.append(child: cwdLabel)
        workingDirEntry.hexpand = true
        cwdRow.append(child: workingDirEntry)
        advBody.append(child: cwdRow)

        let resumeRow = Box(orientation: .horizontal, spacing: 8)
        let resumeLabel = Label(str: "Auto resume")
        resumeLabel.halign = .start
        resumeLabel.setSizeRequest(width: 110, height: -1)
        resumeRow.append(child: resumeLabel)
        resumeRow.append(child: autoResumeSwitch)
        advBody.append(child: resumeRow)

        let advExpander = Expander(label: "Advanced")
        advExpander.set(child: advBody)
        advExpander.marginStart = 12
        advExpander.marginEnd = 12
        advExpander.marginBottom = 8
        column.append(child: advExpander)

        return column
    }

    // MARK: - Mode

    private func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        applyMode()
    }

    private func applyMode() {
        attachPane.visible = (mode == .attach)
        spawnPane.visible = (mode == .spawn)
        attachButton.visible = (mode == .attach)
        spawnButton.visible = (mode == .spawn)
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
            let row = ListBoxRow()
            let hbox = Box(orientation: .horizontal, spacing: 8)
            hbox.marginStart = 12
            hbox.marginEnd = 12
            hbox.marginTop = 6
            hbox.marginBottom = 6
            let kindIcon: String
            switch device.kind {
            case .local: kindIcon = "computer-symbolic"
            case .usb: kindIcon = "drive-harddisk-usb-symbolic"
            case .remote: kindIcon = "network-wired-symbolic"
            }
            let icon = Image(iconName: kindIcon)
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
            deviceList.append(child: row)
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

    private func handleDeviceRow(_ row: ListBoxRowRef?) {
        guard let row else {
            selectedDeviceID = nil
            return
        }
        let index = Int(row.index)
        guard index >= 0, index < devices.count else { return }
        let device = devices[index]
        selectedDeviceID = device.id
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
        processStatus.setText(str: "Loading processes for \(device.name)\u{2026}")

        processFetchTask?.cancel()
        let capturedID = device.id
        processFetchTask = Task { @MainActor in
            do {
                let result = try await device.enumerateProcesses()
                guard !Task.isCancelled, self.selectedDeviceID == capturedID else { return }
                self.renderProcesses(result, for: device)
            } catch {
                guard !Task.isCancelled, self.selectedDeviceID == capturedID else { return }
                self.processStatus.setText(str: "Failed to enumerate processes: \(error)")
            }
        }
    }

    private func renderProcesses(_ snapshot: [ProcessDetails], for device: Frida.Device) {
        let sorted = snapshot.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        processes = sorted
        applyProcessFilter(query: processSearchEntry.text)
        processStatus.setText(str: "\(device.name) — \(sorted.count) processes")

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
            let label = Label(str: "\(proc.name)  ·  pid \(proc.pid)")
            label.halign = .start
            label.marginStart = 12
            label.marginEnd = 12
            label.marginTop = 4
            label.marginBottom = 4
            row.set(child: label)
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
        appStatus.setText(str: "Loading applications for \(device.name)\u{2026}")

        appFetchTask?.cancel()
        let capturedID = device.id
        appFetchTask = Task { @MainActor in
            do {
                let result = try await device.enumerateApplications()
                guard !Task.isCancelled, self.selectedDeviceID == capturedID else { return }
                self.renderApplications(result, for: device)
            } catch {
                guard !Task.isCancelled, self.selectedDeviceID == capturedID else { return }
                self.appStatus.setText(str: "Failed to enumerate applications: \(error)")
            }
        }
    }

    private func renderApplications(_ snapshot: [ApplicationDetails], for device: Frida.Device) {
        let sorted = snapshot.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        applications = sorted
        appStatus.setText(str: "\(device.name) — \(sorted.count) applications")
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
            let textBox = Box(orientation: .vertical, spacing: 0)
            textBox.marginStart = 12
            textBox.marginEnd = 12
            textBox.marginTop = 4
            textBox.marginBottom = 4
            let nameLabel = Label(str: app.name)
            nameLabel.halign = .start
            let idLabel = Label(str: app.identifier)
            idLabel.halign = .start
            idLabel.add(cssClass: "dim-label")
            idLabel.add(cssClass: "caption")
            textBox.append(child: nameLabel)
            textBox.append(child: idLabel)
            row.set(child: textBox)
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
        window.destroy()
    }

    private func commitSpawn() {
        guard let device = currentDevice() else { return }
        let target: SpawnConfig.Target
        switch spawnSubmode {
        case .application:
            guard let identifier = selectedApplicationIdentifier,
                let app = applications.first(where: { $0.identifier == identifier })
            else { return }
            target = .application(identifier: app.identifier, name: app.name)
        case .program:
            let path = programPathEntry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            target = .program(path: path)
        }
        let arguments = argumentsEntry.text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var environment: [String: String] = [:]
        for token in envEntry.text.split(whereSeparator: { $0.isWhitespace }) {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            environment[key] = String(pair[1])
        }
        let cwd = workingDirEntry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = SpawnConfig(
            target: target,
            arguments: arguments,
            environment: environment,
            workingDirectory: cwd.isEmpty ? nil : cwd,
            stdio: .inherit,
            autoResume: autoResumeSwitch.active
        )
        persistState()
        onSpawn(device, config)
        snapshotTask?.cancel()
        processFetchTask?.cancel()
        appFetchTask?.cancel()
        window.destroy()
    }

    // MARK: - Add Remote sheet

    private func presentAddRemoteSheet() {
        let sheet = Window()
        sheet.title = "Add Remote Device"
        sheet.setDefaultSize(width: 460, height: -1)
        sheet.modal = true
        sheet.setTransientFor(parent: window)
        sheet.destroyWithParent = true

        let header = HeaderBar()
        let cancelButton = Button(label: "Cancel")
        cancelButton.onClicked { [weak sheet] _ in
            MainActor.assumeIsolated { sheet?.destroy() }
        }
        header.packStart(child: cancelButton)
        let connectButton = Button(label: "Connect")
        connectButton.add(cssClass: "suggested-action")
        header.packEnd(child: connectButton)
        sheet.set(titlebar: WidgetRef(header))

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
        body.append(child: labeledRow("Certificate", entry: certificateEntry))

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

        sheet.set(child: body)

        connectButton.onClicked { [weak self, weak sheet] _ in
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
                        sheet?.destroy()
                    } catch {
                        errorLabel.setText(str: "\(error)")
                        errorLabel.visible = true
                        connectButton.sensitive = true
                    }
                }
            }
        }

        sheet.present()
    }

    private func labeledRow(_ title: String, entry: Entry) -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        let label = Label(str: title)
        label.halign = .start
        label.setSizeRequest(width: 100, height: -1)
        row.append(child: label)
        entry.hexpand = true
        row.append(child: entry)
        return row
    }
}
