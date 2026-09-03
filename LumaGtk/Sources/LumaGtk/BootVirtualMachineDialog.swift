import Adw
import CGtk
import CLuma
import Foundation
import Frida
import GLibObject
import Gtk
import LumaCore

@MainActor
final class BootVirtualMachineDialog {
    private let parent: Gtk.Window
    private let engine: Engine
    private let onBooted: (Device) -> Void

    private let dialog: Adw.Dialog
    private let templateRow: Adw.ComboRow
    private let nameRow: Adw.EntryRow
    private let starterGroup: Adw.PreferencesGroup
    private let parameterGroup: Adw.PreferencesGroup
    private let agentGroup: Adw.PreferencesGroup
    private let failureLabel: Label
    private let cancelButton: Button
    private let bootButton: Button
    private let scroll: ScrolledWindow

    private let templates: [VirtualMachineTemplate]
    private var parameterRows: [String: ParameterRow] = [:]
    private var starterRow: Adw.ActionRow?
    private var agentRow: Adw.ActionRow?
    private var agentPath: String?
    private var pendingFileParameter: String?
    private var machine: (any VirtualMachine)?
    private var screen: VirtualMachineScreen?

    init(parent: Gtk.Window, engine: Engine, onBooted: @escaping (Device) -> Void) {
        self.parent = parent
        self.engine = engine
        self.onBooted = onBooted

        templates = engine.virtualMachines.templates.filter {
            engine.virtualMachines.availability(for: $0).isAvailable
        }

        dialog = Adw.Dialog()
        dialog.set(title: "Boot Virtual Machine")
        dialog.set(contentWidth: 520)
        dialog.set(contentHeight: 640)

        let header = Adw.HeaderBar()
        cancelButton = Button(label: "Cancel")
        header.packStart(child: cancelButton)
        bootButton = Button(label: "Boot")
        bootButton.add(cssClass: "suggested-action")
        header.packEnd(child: bootButton)

        let machineGroup = Adw.PreferencesGroup()
        machineGroup.title = "Machine"

        templateRow = Adw.ComboRow()
        templateRow.title = "Template"
        templateRow.set(model: makeStringList(templates.map(\.name)))
        machineGroup.add(child: templateRow)

        nameRow = Adw.EntryRow()
        nameRow.title = "Name"
        machineGroup.add(child: nameRow)

        starterGroup = Adw.PreferencesGroup()

        parameterGroup = Adw.PreferencesGroup()
        parameterGroup.title = "Parameters"

        agentGroup = Adw.PreferencesGroup()
        agentGroup.title = "Barebone Agent"

        failureLabel = Label(str: "")
        failureLabel.add(cssClass: "error")
        failureLabel.wrap = true
        failureLabel.xalign = 0
        failureLabel.visible = false

        let body = Box(orientation: .vertical, spacing: 18)
        body.marginStart = 18
        body.marginEnd = 18
        body.marginTop = 12
        body.marginBottom = 18
        body.append(child: machineGroup)
        body.append(child: starterGroup)
        body.append(child: parameterGroup)
        body.append(child: agentGroup)
        body.append(child: failureLabel)

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.child = WidgetRef(body)

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: header)
        column.append(child: scroll)
        dialog.set(child: column)

        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        bootButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let machine = self.machine {
                    self.markReady(machine)
                } else {
                    self.boot()
                }
            }
        }
        templateRow.onNotifySelected { [weak self] _, _ in
            MainActor.assumeIsolated { self?.adoptTemplate() }
        }

        adoptTemplate()
    }

    func present() {
        dialog.own(self)
        dialog.present(parent: parent)
    }

    private var selectedTemplate: VirtualMachineTemplate? {
        let index = Int(templateRow.selected)
        return templates.indices.contains(index) ? templates[index] : nil
    }

    private func adoptTemplate() {
        for row in parameterRows.values {
            parameterGroup.remove(child: row.widget)
        }
        parameterRows.removeAll()
        agentPath = nil

        guard let template = selectedTemplate else {
            starterGroup.visible = false
            parameterGroup.visible = false
            agentGroup.visible = false
            return
        }

        nameRow.text = template.name
        parameterGroup.visible = !template.parameters.isEmpty

        for parameter in template.parameters {
            let row = makeRow(for: parameter)
            parameterRows[parameter.id] = row
            parameterGroup.add(child: row.widget)
        }

        if let archRow = parameterRows[VirtualMachineTemplate.architectureParameterID]?.widget as? Adw.ComboRow {
            archRow.onNotifySelected { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshVariantSections() }
            }
        }
        refreshVariantSections()
    }

    private func refreshVariantSections() {
        guard let template = selectedTemplate else { return }
        let variant = template.variant(for: currentParameterValues())
        rebuildStarterRow(variant.starterImages)
        rebuildAgentRow(variant.agentFlavor)
    }

    private func rebuildStarterRow(_ images: StarterImages?) {
        if let starterRow {
            starterGroup.remove(child: starterRow)
            self.starterRow = nil
        }
        guard let images else {
            starterGroup.visible = false
            return
        }

        let row = Adw.ActionRow()
        row.title = "Starter files"
        row.subtitle = starterDescription(images)

        let download = Button(label: "Download")
        download.valign = .center
        download.tooltipText = "Download \(images.name) and fill these in"
        download.sensitive = engine.virtualMachines.starterImages.state(for: images) != .downloading
        download.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.downloadStarterImages(images) }
        }
        row.addSuffix(widget: download)

        starterGroup.add(child: row)
        starterGroup.visible = true
        starterRow = row
    }

    private func starterDescription(_ images: StarterImages) -> String {
        switch engine.virtualMachines.starterImages.state(for: images) {
        case .ready, .missing:
            return images.name
        case .downloading:
            return "Downloading\u{2026}"
        case .failed(let reason):
            return reason
        }
    }

    private func downloadStarterImages(_ images: StarterImages) {
        Task { @MainActor in
            do {
                let paths = try await engine.virtualMachines.starterImages.download(images)
                for (parameterID, url) in paths {
                    (parameterRows[parameterID]?.widget as? Adw.EntryRow)?.text = url.path
                }
            } catch {
                showFailure(error.localizedDescription)
            }
            self.refreshVariantSections()
        }
        refreshVariantSections()
    }

    private func rebuildAgentRow(_ flavor: BareboneAgentFlavor?) {
        if let agentRow {
            agentGroup.remove(child: agentRow)
            self.agentRow = nil
        }
        guard let flavor else {
            agentGroup.visible = false
            return
        }

        let row = Adw.ActionRow()
        row.title = flavor.name
        row.subtitle = agentDescription(flavor)

        let state = engine.virtualMachines.agents.state(for: flavor)
        if agentPath == nil, state != .ready {
            let download = Button(label: "Download")
            download.valign = .center
            download.tooltipText =
                "Download the \(flavor.name) agent published with Frida \(BareboneAgentLibrary.version)"
            download.sensitive = (state != .downloading)
            download.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.downloadAgent(flavor) }
            }
            row.addSuffix(widget: download)
        }

        let choose = Button(label: "Choose\u{2026}")
        choose.valign = .center
        choose.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.browseForAgent() }
        }
        row.addSuffix(widget: choose)

        agentGroup.add(child: row)
        agentGroup.visible = true
        agentRow = row
    }

    private func agentDescription(_ flavor: BareboneAgentFlavor) -> String {
        if let agentPath {
            return agentPath
        }
        switch engine.virtualMachines.agents.state(for: flavor) {
        case .ready:
            return "Downloaded \(flavor.name)"
        case .downloading:
            return "Downloading\u{2026}"
        case .missing:
            return "Not downloaded yet"
        case .failed(let reason):
            return reason
        }
    }

    private func downloadAgent(_ flavor: BareboneAgentFlavor) {
        Task { @MainActor in
            do {
                _ = try await engine.virtualMachines.agents.download(flavor)
            } catch {
                showFailure(error.localizedDescription)
            }
            self.refreshVariantSections()
        }
        refreshVariantSections()
    }

    private func browseForAgent() {
        guard let parentPtr = parent.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        pendingFileParameter = Self.agentImport
        let context = Unmanaged.passRetained(self).toOpaque()
        "Select Agent".withCString { title in
            luma_file_dialog_open(parentPtr, title, bootVirtualMachineFileThunk, context)
        }
    }

    private static let agentImport = "barebone-agent"

    private func currentParameterValues() -> [String: VirtualMachineParameterValue] {
        var values: [String: VirtualMachineParameterValue] = [:]
        for (id, row) in parameterRows {
            values[id] = row.value()
        }
        return values
    }

    private func makeRow(for parameter: VirtualMachineParameter) -> ParameterRow {
        switch parameter.kind {
        case .text(let initial):
            let row = Adw.EntryRow()
            row.title = parameter.name
            row.text = initial
            return ParameterRow(widget: row) { .text(row.text ?? "") }

        case .number(let initial, let minimum, let maximum, let unit):
            let row = Adw.SpinRow(range: Double(minimum), max: Double(maximum), step: 1)
            row.title = unit.map { "\(parameter.name) (\($0))" } ?? parameter.name
            row.value = Double(initial)
            return ParameterRow(widget: row) { .number(Int(row.value)) }

        case .choice(let options, let initial):
            let row = Adw.ComboRow()
            row.title = parameter.name
            row.set(model: makeStringList(options.map(\.name)))
            row.selected = options.firstIndex { $0.id == initial } ?? 0
            return ParameterRow(widget: row) {
                let index = Int(row.selected)
                return .text(options.indices.contains(index) ? options[index].id : initial)
            }

        case .toggle(let initial):
            let row = Adw.SwitchRow()
            row.title = parameter.name
            row.active = initial
            return ParameterRow(widget: row) { .toggle(row.active) }

        case .filePath(let extensions):
            let row = Adw.EntryRow()
            row.title = parameter.name
            if !extensions.isEmpty {
                row.tooltipText = extensions.map { ".\($0)" }.joined(separator: " ")
            }
            let browse = Button(label: "Browse\u{2026}")
            browse.add(cssClass: "flat")
            browse.valign = .center
            browse.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.browse(for: parameter.id, named: parameter.name) }
            }
            row.addSuffix(widget: browse)
            return ParameterRow(widget: row) { .text(row.text ?? "") }
        }
    }

    private func browse(for parameterID: String, named name: String) {
        guard let parentPtr = parent.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        pendingFileParameter = parameterID
        let context = Unmanaged.passRetained(self).toOpaque()
        "Select \(name)".withCString { title in
            luma_file_dialog_open(parentPtr, title, bootVirtualMachineFileThunk, context)
        }
    }

    fileprivate func adoptFilePath(_ path: String?) {
        defer { pendingFileParameter = nil }
        guard let path, let parameterID = pendingFileParameter else { return }
        if parameterID == Self.agentImport {
            agentPath = path
            refreshVariantSections()
            return
        }
        (parameterRows[parameterID]?.widget as? Adw.EntryRow)?.text = path
    }

    private func boot() {
        guard let template = selectedTemplate else { return }

        let typed = nameRow.text ?? ""
        let name = typed.isEmpty ? template.name : typed
        failureLabel.visible = false
        bootButton.sensitive = false

        Task { @MainActor in
            do {
                let machine = try await engine.virtualMachines.create(
                    template: template,
                    name: name,
                    parameters: currentParameterValues(),
                    agentPath: agentPath.map { URL(fileURLWithPath: $0) })
                self.machine = machine
                self.showBootedView(machine)
                engine.setSidePanel(.virtualMachines)
            } catch {
                showFailure(error.localizedDescription)
                bootButton.sensitive = true
            }
        }
    }

    private func showBootedView(_ machine: any VirtualMachine) {
        cancelButton.label = "Later"
        bootButton.label = "Mark Ready"
        bootButton.sensitive = true

        let content = Box(orientation: .vertical, spacing: 8)
        content.marginStart = 18
        content.marginEnd = 18
        content.marginTop = 12
        content.marginBottom = 18

        if case .frames(let source)? = machine.display {
            let screen = VirtualMachineScreen(source: source)
            screen.widget.vexpand = true
            content.append(child: screen.widget)
            self.screen = screen
        }

        let hint = Label(str: "Drive the machine to the state you want to come back to, then mark it ready.")
        hint.add(cssClass: "dim-label")
        hint.wrap = true
        hint.xalign = 0
        content.append(child: hint)

        failureLabel.unparent()
        content.append(child: failureLabel)

        scroll.child = WidgetRef(content)
    }

    private func markReady(_ machine: any VirtualMachine) {
        failureLabel.visible = false
        bootButton.sensitive = false

        Task { @MainActor in
            do {
                try await engine.virtualMachines.markReady(machine)
                self.finish()
            } catch {
                showFailure(error.localizedDescription)
                bootButton.sensitive = true
            }
        }
    }

    private func finish() {
        if let machine, let device = engine.virtualMachines.device(for: machine) {
            onBooted(device)
        }
        _ = dialog.close()
    }

    private func showFailure(_ message: String) {
        failureLabel.label = message
        failureLabel.visible = true
    }
}

@MainActor
private struct ParameterRow {
    let widget: Widget
    let value: () -> VirtualMachineParameterValue
}

private let bootVirtualMachineFileThunk: @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    let path: String? = pathPtr.map { String(cString: $0) }
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let dialog = Unmanaged<BootVirtualMachineDialog>.fromOpaque(ptr).takeRetainedValue()
        dialog.adoptFilePath(path)
    }
}

@MainActor
private func makeStringList(_ labels: [String]) -> StringList {
    let list = StringList(strings: nil)
    for label in labels {
        list.append(string: label)
    }
    return list
}
