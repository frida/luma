import Gtk
import LumaCore

@MainActor
final class CustomInstrumentTemplatesPanel {
    let widget: Box
    let editor: Box
    var onTargetChanged: () -> Void = {}
    var onTemplatesChanged: () -> Void = {}
    private(set) var target: Int?

    private let read: () -> [InstrumentChildTemplate]
    private let write: ([InstrumentChildTemplate]) -> Void
    private let targets = ListBox()
    private var addDraft: IDNameDraft?
    private let idEntry = Entry()
    private let nameEntry = Entry()
    private let iconButton = MenuButton()
    private let iconGrid = InstrumentIconConceptGrid()
    private let moveUpButton = CustomInstrumentEditorChrome.iconButton("go-up-symbolic", tooltip: "Move Up")
    private let moveDownButton = CustomInstrumentEditorChrome.iconButton("go-down-symbolic", tooltip: "Move Down")
    private let removeButton = CustomInstrumentEditorChrome.iconButton("user-trash-symbolic", tooltip: "Remove Kind of Child")
    private var isShowing = false

    init(read: @escaping () -> [InstrumentChildTemplate], write: @escaping ([InstrumentChildTemplate]) -> Void) {
        self.read = read
        self.write = write
        widget = Box(orientation: .vertical, spacing: 8)
        editor = Box(orientation: .vertical, spacing: 8)

        widget.marginStart = 12
        widget.marginEnd = 4
        widget.marginTop = 16
        widget.marginBottom = 16
        widget.setSizeRequest(width: 300, height: -1)
        let heading = Label(str: "Designing")
        heading.add(cssClass: "heading")
        heading.halign = .start
        widget.append(child: heading)
        targets.add(cssClass: "boxed-list")
        targets.selectionMode = .browse
        targets.setAccessibleLabel("What is being designed")
        targets.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, !self.isShowing, let row else { return }
                self.choose(Int(row.index))
            }
        }
        widget.append(child: targets)
        let addHeading = Label(str: "Add a kind of child")
        addHeading.add(cssClass: "caption-heading")
        addHeading.halign = .start
        widget.append(child: addHeading)
        let draft = IDNameDraft { [weak self] id, name in
            self?.addTemplate(id: id, name: name) ?? false
        }
        addDraft = draft
        widget.append(child: draft.row)

        makeEditor()
        rebuild()
    }

    func rebuild() {
        isShowing = true
        defer { isShowing = false }
        while let row = targets.firstChild {
            targets.remove(child: row)
        }
        let templates = read()
        targets.append(child: Self.targetRow(title: "Page", detail: nil))
        for template in templates {
            targets.append(child: Self.targetRow(title: template.name, detail: template.id))
        }
        if let row = targets.getRowAt(index: (target ?? -1) + 1) {
            targets.select(row: row)
        }
        showEditor(templates)
    }

    private func makeEditor() {
        editor.append(child: Self.fieldRow("Id", idEntry))
        editor.append(child: Self.fieldRow("Name", nameEntry))
        nameEntry.placeholderText = "Plural, such as Bins"
        idEntry.onChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.edit { $0.id = entry.text ?? "" }
            }
        }
        nameEntry.onChanged { [weak self] entry in
            MainActor.assumeIsolated {
                self?.edit { $0.name = entry.text ?? "" }
            }
        }

        let popover = Popover()
        popover.set(child: iconGrid.widget)
        iconButton.set(popover: popover)
        iconButton.tooltipText = "Icon"
        iconGrid.onChoose = { [weak self] id in
            self?.edit { $0.symbol = id }
        }
        let buttons = Box(orientation: .horizontal, spacing: 4)
        buttons.append(child: Self.fieldRow("Icon", iconButton))
        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        buttons.append(child: spacer)
        for (button, action) in [(moveUpButton, -1), (moveDownButton, 1)] {
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.move(by: action) }
            }
            buttons.append(child: button)
        }
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.removeTemplate() }
        }
        buttons.append(child: removeButton)
        editor.append(child: buttons)
    }

    private func choose(_ index: Int) {
        let chosen: Int? = index == 0 ? nil : index - 1
        guard chosen != target else { return }
        target = chosen
        showEditor(read())
        onTargetChanged()
    }

    private func showEditor(_ templates: [InstrumentChildTemplate]) {
        guard let target, templates.indices.contains(target) else {
            editor.visible = false
            return
        }
        isShowing = true
        defer { isShowing = false }
        let template = templates[target]
        editor.visible = true
        if idEntry.text != template.id {
            idEntry.text = template.id
        }
        if nameEntry.text != template.name {
            nameEntry.text = template.name
        }
        iconButton.set(child: InstrumentIconView.makeImage(for: .symbolic(template.symbol ?? ""), pixelSize: 16))
        iconGrid.show(template.symbol)
        moveUpButton.sensitive = target > 0
        moveDownButton.sensitive = target < templates.count - 1
    }

    private func edit(_ change: (inout InstrumentChildTemplate) -> Void) {
        guard !isShowing, let target else { return }
        var templates = read()
        change(&templates[target])
        write(templates)
        refreshRow(target, templates[target])
        showEditor(templates)
        onTemplatesChanged()
    }

    private func refreshRow(_ index: Int, _ template: InstrumentChildTemplate) {
        isShowing = true
        defer { isShowing = false }
        guard let row = targets.getRowAt(index: index + 1) else { return }
        row.set(child: Self.targetLine(title: template.name, detail: template.id))
    }

    private func addTemplate(id: String, name: String) -> Bool {
        var templates = read()
        guard !templates.contains(where: { $0.id == id }) else { return false }
        templates.append(InstrumentChildTemplate(id: id, name: name, widgets: []))
        write(templates)
        target = templates.count - 1
        rebuild()
        onTargetChanged()
        onTemplatesChanged()
        return true
    }

    private func move(by offset: Int) {
        guard let target else { return }
        var templates = read()
        templates.swapAt(target, target + offset)
        write(templates)
        self.target = target + offset
        rebuild()
        onTemplatesChanged()
    }

    private func removeTemplate() {
        guard let target else { return }
        var templates = read()
        templates.remove(at: target)
        write(templates)
        self.target = nil
        rebuild()
        onTargetChanged()
        onTemplatesChanged()
    }

    private static func targetRow(title: String, detail: String?) -> ListBoxRow {
        let row = ListBoxRow()
        row.set(child: targetLine(title: title, detail: detail))
        return row
    }

    private static func targetLine(title: String, detail: String?) -> Box {
        let line = Box(orientation: .vertical, spacing: 0)
        line.marginStart = 8
        line.marginEnd = 8
        line.marginTop = 6
        line.marginBottom = 6
        let titleLabel = Label(str: title.isEmpty ? "Untitled" : title)
        titleLabel.xalign = 0
        titleLabel.ellipsize = .end
        line.append(child: titleLabel)
        if let detail {
            let detailLabel = Label(str: detail)
            detailLabel.add(cssClass: "dim-label")
            detailLabel.add(cssClass: "caption")
            detailLabel.xalign = 0
            detailLabel.ellipsize = .end
            line.append(child: detailLabel)
        }
        return line
    }

    private static func fieldRow(_ title: String, _ field: Widget) -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        let label = Label(str: title)
        label.halign = .start
        label.setSizeRequest(width: 96, height: -1)
        row.append(child: label)
        field.hexpand = !(field is MenuButton)
        row.append(child: field)
        return row
    }
}
