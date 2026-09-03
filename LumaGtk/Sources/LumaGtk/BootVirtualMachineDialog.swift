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
    private let parameterGroup: Adw.PreferencesGroup
    private let failureLabel: Label
    private let bootButton: Button

    private let templates: [VirtualMachineTemplate]
    private var parameterRows: [String: ParameterRow] = [:]
    private var pendingFileParameter: String?

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
        let cancelButton = Button(label: "Cancel")
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

        parameterGroup = Adw.PreferencesGroup()
        parameterGroup.title = "Parameters"

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
        body.append(child: parameterGroup)
        body.append(child: failureLabel)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.child = WidgetRef(body)

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: header)
        column.append(child: scroll)
        dialog.set(child: column)

        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.dialog.close() }
        }
        bootButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.boot() }
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

        guard let template = selectedTemplate else {
            parameterGroup.visible = false
            return
        }

        nameRow.text = template.name
        parameterGroup.visible = !template.parameters.isEmpty

        for parameter in template.parameters {
            let row = makeRow(for: parameter)
            parameterRows[parameter.id] = row
            parameterGroup.add(child: row.widget)
        }
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
        guard let path, let parameterID = pendingFileParameter,
            let row = parameterRows[parameterID]?.widget as? Adw.EntryRow
        else { return }
        row.text = path
    }

    private func boot() {
        guard let template = selectedTemplate else { return }

        var parameters: [String: VirtualMachineParameterValue] = [:]
        for (id, row) in parameterRows {
            parameters[id] = row.value()
        }

        let typed = nameRow.text ?? ""
        let name = typed.isEmpty ? template.name : typed
        failureLabel.visible = false
        bootButton.sensitive = false

        Task { @MainActor in
            do {
                let machine = try await engine.virtualMachines.create(
                    template: template, name: name, parameters: parameters, agentPath: nil)
                if let device = engine.virtualMachines.device(for: machine) {
                    onBooted(device)
                }
                _ = dialog.close()
            } catch {
                failureLabel.label = error.localizedDescription
                failureLabel.visible = true
                bootButton.sensitive = true
            }
        }
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
