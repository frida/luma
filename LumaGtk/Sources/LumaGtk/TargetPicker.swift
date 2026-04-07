import Foundation
import Frida
import Gtk
import LumaCore

@MainActor
final class TargetPicker {
    typealias OnAttach = (_ device: Frida.Device, _ process: ProcessDetails) -> Void

    private let parent: Window
    private let engine: Engine
    private let onAttach: OnAttach
    private let reason: String?

    private let window: Window
    private let deviceList: ListBox
    private let processList: ListBox
    private let processStatus: Label
    private let attachButton: Button

    private var devices: [Frida.Device] = []
    private var processes: [ProcessDetails] = []
    private var snapshotTask: Task<Void, Never>?
    private var processFetchTask: Task<Void, Never>?
    private var selectedDeviceID: String?
    private var selectedProcessIndex: Int?

    init(
        parent: Window,
        engine: Engine,
        reason: String? = nil,
        onAttach: @escaping OnAttach
    ) {
        self.parent = parent
        self.engine = engine
        self.reason = reason
        self.onAttach = onAttach

        window = Window()
        window.title = reason == nil ? "New Session" : "Re-Establish Session"
        window.setDefaultSize(width: 720, height: 480)
        window.modal = true
        window.transientFor = WindowRef(parent)
        window.destroyWithParent = true

        deviceList = ListBox()
        processList = ListBox()
        processStatus = Label(str: "Select a device to list processes\u{2026}")
        attachButton = Button(label: "Attach")

        deviceList.selectionMode = .single
        deviceList.add(cssClass: "navigation-sidebar")
        processList.selectionMode = .single
        attachButton.sensitive = false

        let header = HeaderBar()
        let cancelButton = Button(label: "Cancel")
        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        }
        header.packStart(child: cancelButton)
        attachButton.add(cssClass: "suggested-action")
        attachButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.commit()
            }
        }
        header.packEnd(child: attachButton)
        window.set(titlebar: WidgetRef(header))

        let paned = Paned(orientation: .horizontal)
        paned.position = 240
        let devicePane = buildDevicePane()
        let processPane = buildProcessPane()
        paned.startChild = WidgetRef(devicePane)
        paned.endChild = WidgetRef(processPane)
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
        column.append(child: paned)
        window.set(child: column)

        deviceList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                self?.handleDeviceRow(row)
            }
        }
        processList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                self?.handleProcessRow(row)
            }
        }
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
        snapshotTask?.cancel()
        processFetchTask?.cancel()
        window.destroy()
    }

    // MARK: - Build

    private func buildDevicePane() -> ScrolledWindow {
        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: deviceList)
        return scroll
    }

    private func buildProcessPane() -> Box {
        processStatus.halign = .start
        processStatus.marginStart = 12
        processStatus.marginEnd = 12
        processStatus.marginTop = 12
        processStatus.marginBottom = 6

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: processList)

        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true
        column.append(child: processStatus)
        column.append(child: scroll)
        return column
    }

    // MARK: - Devices

    private func renderDevices(_ snapshot: [Frida.Device]) {
        devices = snapshot
        deviceList.removeAll()
        for device in snapshot {
            let row = ListBoxRow()
            let label = Label(str: "\(device.name) (\(device.id))")
            label.halign = .start
            label.marginStart = 12
            label.marginEnd = 12
            label.marginTop = 6
            label.marginBottom = 6
            row.set(child: label)
            deviceList.append(child: row)
        }
        if let selected = selectedDeviceID,
            let index = snapshot.firstIndex(where: { $0.id == selected }),
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
    }

    // MARK: - Processes

    private func loadProcesses(for device: Frida.Device) {
        processList.removeAll()
        processes = []
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
        processList.removeAll()
        for proc in sorted {
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
        processStatus.setText(str: "\(device.name) — \(sorted.count) processes")
    }

    private func handleProcessRow(_ row: ListBoxRowRef?) {
        guard let row else {
            selectedProcessIndex = nil
            attachButton.sensitive = false
            return
        }
        let index = Int(row.index)
        guard index >= 0, index < processes.count else { return }
        selectedProcessIndex = index
        attachButton.sensitive = true
    }

    private func commit() {
        guard let deviceID = selectedDeviceID,
            let device = devices.first(where: { $0.id == deviceID }),
            let processIndex = selectedProcessIndex,
            processIndex < processes.count
        else { return }
        let process = processes[processIndex]
        onAttach(device, process)
        close()
    }
}
