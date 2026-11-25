import Adw
import Gtk
import LumaCore

@MainActor
enum CustomInstrumentEditorChrome {
    static func header(
        onCancel: @escaping () -> Void, onSave: @escaping () -> Void, saveButton: Button = Button(label: "Save")
    ) -> Adw.HeaderBar {
        let header = Adw.HeaderBar()
        header.showStartTitleButtons = false
        header.showEndTitleButtons = false
        let cancelButton = Button(label: "Cancel")
        cancelButton.onClicked { _ in
            MainActor.assumeIsolated { onCancel() }
        }
        header.packStart(child: cancelButton)
        saveButton.add(cssClass: "suggested-action")
        saveButton.onClicked { _ in
            MainActor.assumeIsolated { onSave() }
        }
        header.packEnd(child: saveButton)
        return header
    }

    static func addToggle(_ label: String, isAdding: Bool) -> Button {
        let button = Button()
        button.halign = .start
        setAddToggle(button, label: label, isAdding: isAdding)
        return button
    }

    static func setAddToggle(_ button: Button, label: String, isAdding: Bool) {
        let content = Box(orientation: .horizontal, spacing: 6)
        content.append(child: Image(iconName: isAdding ? "object-select-symbolic" : "list-add-symbolic"))
        content.append(child: Label(str: isAdding ? "Done Adding" : label))
        button.set(child: content)
    }

    static func iconButton(_ iconName: String, tooltip: String) -> Button {
        let button = Button()
        button.set(iconName: iconName)
        button.add(cssClass: "flat")
        button.tooltipText = tooltip
        return button
    }
}

@MainActor
final class IDNameDraft {
    let row = Box(orientation: .horizontal, spacing: 6)
    private let idEntry = Entry()
    private let nameEntry = Entry()
    private let addButton = CustomInstrumentEditorChrome.iconButton("list-add-symbolic", tooltip: "Add")
    private let onAdd: (_ id: String, _ name: String) -> Bool
    private var nameAutoFilled = true
    private var isResetting = false

    init(onAdd: @escaping (_ id: String, _ name: String) -> Bool) {
        self.onAdd = onAdd
        idEntry.placeholderText = "id"
        idEntry.setSizeRequest(width: 140, height: -1)
        nameEntry.placeholderText = "Name"
        nameEntry.hexpand = true
        addButton.sensitive = false
        idEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleIDChanged() }
        }
        nameEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.handleNameChanged() }
        }
        idEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.add() }
        }
        nameEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.add() }
        }
        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.add() }
        }
        row.append(child: idEntry)
        row.append(child: nameEntry)
        row.append(child: addButton)
    }

    func focus() {
        _ = idEntry.grabFocus()
    }

    private var id: String { (idEntry.text ?? "").trimmingCharacters(in: .whitespaces) }
    private var name: String { (nameEntry.text ?? "").trimmingCharacters(in: .whitespaces) }

    private func handleIDChanged() {
        guard !isResetting else { return }
        let raw = idEntry.text ?? ""
        let sanitized = CamelCase.sanitized(raw)
        if sanitized != raw {
            idEntry.text = sanitized
            return
        }
        if nameAutoFilled {
            isResetting = true
            nameEntry.text = CamelCase.humanized(sanitized)
            isResetting = false
        }
        addButton.sensitive = !id.isEmpty && !name.isEmpty
    }

    private func handleNameChanged() {
        addButton.sensitive = !id.isEmpty && !name.isEmpty
        guard !isResetting else { return }
        if (nameEntry.text ?? "") != CamelCase.humanized(idEntry.text ?? "") {
            nameAutoFilled = false
        }
    }

    private func add() {
        guard !id.isEmpty, !name.isEmpty, onAdd(id, name) else { return }
        isResetting = true
        idEntry.text = ""
        nameEntry.text = ""
        isResetting = false
        nameAutoFilled = true
        addButton.sensitive = false
        focus()
    }
}
