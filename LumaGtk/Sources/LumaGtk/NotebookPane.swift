import Adw
import CGtk
import Foundation
import Gtk
import LumaCore
@MainActor
final class NotebookPane {
    let widget: Box

    private weak var engine: Engine?
    private let overlay: Overlay
    private let scroll: ScrolledWindow
    private let contentBox: Box
    private let emptyState: Box
    private let entriesBox: Box
    private let newNoteButton: Button
    private let timeFormatter: DateFormatter

    private var editingEntries: Set<UUID> = []
    private var autoEditedEntries: Set<UUID> = []
    private var draftEntries: Set<UUID> = []
    private var jsValueKeepers: [JSInspectValueWidget] = []
    private var entryRows: [UUID: Widget] = [:]
    private let emptyStateActionHolder = ActionHolder()

    init(engine: Engine) {
        self.engine = engine

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        contentBox = Box(orientation: .vertical, spacing: 0)
        contentBox.hexpand = true
        contentBox.vexpand = true

        entriesBox = Box(orientation: .vertical, spacing: 12)
        entriesBox.marginStart = 16
        entriesBox.marginEnd = 16
        entriesBox.marginTop = 12
        entriesBox.marginBottom = 16
        entriesBox.hexpand = true

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: entriesBox)

        emptyState = NotebookPane.makeWalkthroughEmptyState(
            onNewNote: { [emptyStateActionHolder] in
                emptyStateActionHolder.action?()
            }
        )
        emptyState.hexpand = true
        emptyState.vexpand = true

        contentBox.append(child: emptyState)
        contentBox.append(child: scroll)
        scroll.visible = false

        overlay = Overlay()
        overlay.hexpand = true
        overlay.vexpand = true
        overlay.set(child: WidgetRef(contentBox))

        newNoteButton = Button(label: "+  New Note")
        newNoteButton.add(cssClass: "suggested-action")
        newNoteButton.add(cssClass: "pill")
        newNoteButton.halign = .end
        newNoteButton.valign = .end
        newNoteButton.marginEnd = 20
        newNoteButton.marginBottom = 20
        newNoteButton.visible = false
        overlay.addOverlay(widget: newNoteButton)

        widget.append(child: overlay)

        newNoteButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.addUserNote()
            }
        }

        emptyStateActionHolder.action = { [weak self] in
            self?.addUserNote()
        }

        populateEntries()
    }

    // MARK: - Change handling

    func handleNotebookChange(_ change: LumaCore.NotebookChange) {
        switch change {
        case .added(let entry):
            let row = makeRow(for: entry)
            entryRows[entry.id] = row
            insertEntryRow(row, for: entry)
        case .snapshot:
            rebuildEntries()
        case .updated(let entry):
            if let existing = entryRows[entry.id] {
                let parent = entriesBox
                let next = existing.nextSibling
                parent.remove(child: existing)
                let row = makeRow(for: entry)
                entryRows[entry.id] = row
                gtk_box_insert_child_after(parent.box_ptr, row.widget_ptr, next?.prevSibling?.widget_ptr)
            }
        case .removed(let id):
            if let row = entryRows.removeValue(forKey: id) {
                entriesBox.remove(child: row)
            }
            editingEntries.remove(id)
            autoEditedEntries.remove(id)
            draftEntries.remove(id)
        case .reordered:
            rebuildEntries()
        }
        updateVisibility()
    }

    private func populateEntries() {
        guard let engine else { return }
        for entry in engine.notebookEntries.sorted(by: { $0.timestamp < $1.timestamp }) {
            let row = makeRow(for: entry)
            entryRows[entry.id] = row
            entriesBox.append(child: row)
        }
        updateVisibility()
    }

    private func rebuildEntries() {
        guard let engine else { return }
        clearWindowFocus()
        clearChildren(of: entriesBox)
        jsValueKeepers.removeAll()
        entryRows.removeAll()
        for entry in engine.notebookEntries.sorted(by: { $0.timestamp < $1.timestamp }) {
            let row = makeRow(for: entry)
            entryRows[entry.id] = row
            entriesBox.append(child: row)
        }
        updateVisibility()
    }

    private func insertEntryRow(_ row: Widget, for entry: LumaCore.NotebookEntry) {
        guard let engine else {
            entriesBox.append(child: row)
            return
        }
        let sorted = engine.notebookEntries.sorted { $0.timestamp < $1.timestamp }
        guard let targetIdx = sorted.firstIndex(where: { $0.id == entry.id }) else {
            entriesBox.append(child: row)
            return
        }
        if let nextEntry = sorted.dropFirst(targetIdx + 1).first(where: { entryRows[$0.id] != nil }),
            let sibling = entryRows[nextEntry.id]
        {
            gtk_box_insert_child_after(entriesBox.box_ptr, row.widget_ptr, sibling.prevSibling?.widget_ptr)
        } else {
            entriesBox.append(child: row)
        }
    }

    private func updateVisibility() {
        let hasEntries = !entryRows.isEmpty
        let anyEditing = !editingEntries.isEmpty
        emptyState.visible = !hasEntries
        scroll.visible = hasEntries
        newNoteButton.visible = hasEntries && !anyEditing
    }

    // MARK: - Actions

    private func addUserNote(after other: LumaCore.NotebookEntry? = nil) {
        guard let engine else { return }
        let note = LumaCore.NotebookEntry(
            title: "Note",
            details: "",
            binaryData: nil,
            processName: other?.processName,
            isUserNote: true
        )
        editingEntries.insert(note.id)
        autoEditedEntries.insert(note.id)
        draftEntries.insert(note.id)
        engine.addNotebookEntry(note, after: other)
    }

    private func deleteEntry(_ entry: LumaCore.NotebookEntry) {
        editingEntries.remove(entry.id)
        autoEditedEntries.remove(entry.id)
        engine?.deleteNotebookEntry(entry)
    }

    private func beginEditing(_ entry: LumaCore.NotebookEntry) {
        editingEntries.insert(entry.id)
        Task { @MainActor [weak self] in
            self?.rebuildEntries()
        }
    }

    private func presentContextMenu(anchor: Widget, x: Double, y: Double, entry: LumaCore.NotebookEntry) {
        var topSection: [ContextMenu.Item] = []
        if entry.isUserNote {
            topSection.append(.init("Edit") { [weak self] in self?.beginEditing(entry) })
        }
        topSection.append(.init("Insert Note Below") { [weak self] in self?.addUserNote(after: entry) })

        ContextMenu.present([
            topSection,
            [.init("Delete", destructive: true) { [weak self] in self?.deleteEntry(entry) }],
        ], at: anchor, x: x, y: y)
    }

    private func commitEdits(
        original: LumaCore.NotebookEntry,
        title: String,
        details: String
    ) {
        var updated = original
        updated.title = title
        updated.details = details
        editingEntries.remove(original.id)
        draftEntries.remove(original.id)
        engine?.updateNotebookEntry(updated)
    }

    // MARK: - Row construction

    private func makeRow(for entry: LumaCore.NotebookEntry) -> Widget {
        let card = Box(orientation: .vertical, spacing: 6)
        card.add(cssClass: "card")
        card.add(cssClass: "notebook-entry")
        card.marginStart = 0
        card.marginEnd = 0
        card.marginTop = 0
        card.marginBottom = 0
        card.hexpand = true

        if entry.isUserNote {
            let dblClick = GestureClick()
            dblClick.set(button: 1)
            dblClick.onPressed { [weak self] _, nPress, _, _ in
                MainActor.assumeIsolated {
                    guard nPress >= 2 else { return }
                    self?.beginEditing(entry)
                }
            }
            card.install(controller: dblClick)
        }

        let rightClick = GestureClick()
        rightClick.set(button: 3)
        rightClick.onPressed { [weak self, card] _, _, x, y in
            MainActor.assumeIsolated {
                self?.presentContextMenu(anchor: card, x: x, y: y, entry: entry)
            }
        }
        card.install(controller: rightClick)


        let inner = Box(orientation: .vertical, spacing: 6)
        inner.marginStart = 12
        inner.marginEnd = 12
        inner.marginTop = 10
        inner.marginBottom = 10
        inner.hexpand = true
        card.append(child: inner)

        let isEditing = entry.isUserNote && editingEntries.contains(entry.id)

        inner.append(child: makeHeader(for: entry, isEditing: isEditing))

        if entry.isUserNote {
            if isEditing {
                inner.append(child: makeEditableBody(for: entry))
            } else if !entry.details.isEmpty {
                let body = Label(str: entry.details)
                body.halign = .start
                body.hexpand = true
                body.wrap = true
                body.selectable = true
                inner.append(child: body)
            }
        } else {
            if let jsValue = entry.jsValue, let engine {
                let wrapper = JSInspectValueWidget.make(
                    value: jsValue,
                    engine: engine,
                    sessionID: UUID()
                )
                jsValueKeepers.append(wrapper)
                let valueWidget = wrapper.widget
                valueWidget.hexpand = true
                inner.append(child: valueWidget)
            } else if !entry.details.isEmpty {
                let body = Label(str: entry.details)
                body.add(cssClass: "monospace")
                body.halign = .start
                body.hexpand = true
                body.wrap = true
                body.selectable = true
                inner.append(child: body)
            }
        }

        if let data = entry.binaryData, !data.isEmpty {
            inner.append(child: HexView(bytes: data).widget)
        }

        return card
    }

    private static func formatHexdumpPreview(data: Data, maxLines: Int) -> String {
        let bytes = [UInt8](data)
        let total = bytes.count
        let cap = min(total, maxLines * 16)
        var out = ""
        var i = 0
        while i < cap {
            out += String(format: "0x%08x  ", i)
            var hexPart = ""
            var asciiPart = ""
            for col in 0..<16 {
                let idx = i + col
                if col == 8 {
                    hexPart += " "
                }
                if idx < cap {
                    let b = bytes[idx]
                    hexPart += String(format: "%02x", b)
                    if (0x20...0x7e).contains(b) {
                        asciiPart.append(Character(UnicodeScalar(b)))
                    } else {
                        asciiPart.append(".")
                    }
                } else {
                    hexPart += "  "
                    asciiPart.append(" ")
                }
                if col != 15 {
                    hexPart += " "
                }
            }
            out += hexPart
            out += "  |"
            out += asciiPart
            out += "|"
            i += 16
            if i < cap {
                out += "\n"
            }
        }
        if total > cap {
            if !out.isEmpty { out += "\n" }
            out += "… (total \(total) bytes)"
        }
        return out
    }

    private func makeHeader(for entry: LumaCore.NotebookEntry, isEditing: Bool) -> Box {
        let header = Box(orientation: .horizontal, spacing: 8)
        header.hexpand = true

        if let processName = entry.processName, !processName.isEmpty {
            let chip = Label(str: processName)
            chip.add(cssClass: "caption")
            chip.add(cssClass: "accent")
            header.append(child: chip)
        }

        let title = Label(str: entry.title.isEmpty ? "Note" : entry.title)
        title.add(cssClass: "heading")
        title.halign = .start
        title.selectable = true
        header.append(child: title)

        let spacer = Label(str: "")
        spacer.hexpand = true
        header.append(child: spacer)

        if let author = entry.author {
            header.append(child: makeAuthorBadge(author))
        }

        let timestamp = Label(str: timeFormatter.string(from: entry.timestamp))
        timestamp.add(cssClass: "caption")
        timestamp.add(cssClass: "dim-label")
        header.append(child: timestamp)

        if entry.isUserNote && !isEditing {
            let editButton = Button(label: "Edit")
            editButton.hasFrame = false
            editButton.add(cssClass: "flat")
            editButton.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.beginEditing(entry)
                }
            }
            header.append(child: editButton)
        }

        let addBelow = Button(label: "+ Note")
        addBelow.hasFrame = false
        addBelow.add(cssClass: "flat")
        addBelow.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.addUserNote(after: entry)
            }
        }
        header.append(child: addBelow)

        let deleteButton = Button(label: "Delete")
        deleteButton.hasFrame = false
        deleteButton.add(cssClass: "flat")
        deleteButton.add(cssClass: "error")
        deleteButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deleteEntry(entry)
            }
        }
        header.append(child: deleteButton)

        return header
    }

    private func makeAuthorBadge(_ author: LumaCore.NotebookEntry.Author) -> Box {
        let name = author.name.isEmpty ? "@\(author.id)" : author.name
        let box = Box(orientation: .horizontal, spacing: 4)
        box.tooltipText = name

        let avatar = Adw.Avatar(size: 16, text: name, showInitials: true)
        box.append(child: avatar)

        if !author.avatarURL.isEmpty,
           let url = URL(string: "\(author.avatarURL)&s=48")
        {
            Task { @MainActor [avatar] in
                guard let texture = await AvatarCache.shared.texture(for: url) else { return }
                avatar.set(customImage: texture)
            }
        }

        let label = Label(str: name)
        label.add(cssClass: "caption")
        label.add(cssClass: "dim-label")
        box.append(child: label)

        return box
    }

    private func makeEditableBody(for entry: LumaCore.NotebookEntry) -> Box {
        let column = Box(orientation: .vertical, spacing: 6)
        column.hexpand = true

        let titleEntry = Entry()
        titleEntry.text = entry.title
        titleEntry.placeholderText = "Title"
        titleEntry.hexpand = true
        column.append(child: titleEntry)

        let selectAll = autoEditedEntries.remove(entry.id) != nil
        Task { @MainActor in
            _ = titleEntry.grabFocus()
            if selectAll {
                let editable = UnsafeMutableRawPointer(titleEntry.widget_ptr)
                    .assumingMemoryBound(to: GtkEditable.self)
                gtk_editable_select_region(editable, 0, -1)
            }
        }

        let textView = TextView()
        textView.hexpand = true
        textView.vexpand = true
        textView.wrapMode = .word
        textView.topMargin = 6
        textView.bottomMargin = 6
        textView.leftMargin = 6
        textView.rightMargin = 6
        if !entry.details.isEmpty {
            textView.buffer.set(text: entry.details, len: -1)
        }

        let textScroll = ScrolledWindow()
        textScroll.hexpand = true
        textScroll.setSizeRequest(width: -1, height: 120)
        textScroll.set(child: textView)
        column.append(child: textScroll)

        let actionRow = Box(orientation: .horizontal, spacing: 8)
        actionRow.hexpand = true
        let actionSpacer = Label(str: "")
        actionSpacer.hexpand = true
        actionRow.append(child: actionSpacer)

        let cancelButton = Button(label: "Cancel")
        cancelButton.hasFrame = false
        cancelButton.add(cssClass: "flat")
        actionRow.append(child: cancelButton)

        let saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        actionRow.append(child: saveButton)

        column.append(child: actionRow)

        cancelButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.editingEntries.remove(entry.id)
                if self.draftEntries.remove(entry.id) != nil {
                    self.engine?.deleteNotebookEntry(entry)
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.rebuildEntries()
                    _ = self.newNoteButton.grabFocus()
                }
            }
        }

        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let newTitle = titleEntry.text ?? ""
                let newDetails = NotebookPane.text(from: textView)
                self.commitEdits(original: entry, title: newTitle, details: newDetails)
                _ = self.newNoteButton.grabFocus()
            }
        }

        return column
    }

    private static func text(from textView: TextView) -> String {
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

    // MARK: - Helpers

    private func clearWindowFocus() {
        guard let rootPtr = widget.root?.ptr else { return }
        let window = Gtk.WindowRef(raw: rootPtr)
        window.focus = nil
    }

    private static func makeWalkthroughStep(number: Int, text: String) -> Box {
        let row = Box(orientation: .horizontal, spacing: 10)
        row.setSizeRequest(width: 350, height: -1)
        row.halign = .center

        let numberLabel = Label(str: "\(number).")
        numberLabel.halign = .end
        numberLabel.valign = .start
        numberLabel.setSizeRequest(width: 18, height: -1)
        numberLabel.add(cssClass: "dim-label")
        row.append(child: numberLabel)

        let bodyLabel = Label(str: text)
        bodyLabel.halign = .start
        bodyLabel.wrap = true
        bodyLabel.hexpand = true
        bodyLabel.xalign = 0
        row.append(child: bodyLabel)

        return row
    }

    private static func makeWalkthroughEmptyState(onNewNote: @escaping () -> Void) -> Box {
        let outer = Box(orientation: .vertical, spacing: 0)
        outer.hexpand = true
        outer.vexpand = true
        outer.halign = .center
        outer.valign = .center

        let stack = Box(orientation: .vertical, spacing: 24)
        stack.halign = .center
        stack.valign = .center
        stack.marginStart = 24
        stack.marginEnd = 24
        stack.marginTop = 24
        stack.marginBottom = 24
        stack.add(cssClass: "luma-empty-state")

        let titleGroup = Box(orientation: .vertical, spacing: 8)
        titleGroup.halign = .center

        let image = Gtk.Image(iconName: "accessories-dictionary-symbolic")
        image.pixelSize = 40
        image.halign = .center
        titleGroup.append(child: image)

        let titleLabel = Label(str: "Notebook")
        titleLabel.add(cssClass: "title-2")
        titleLabel.halign = .center
        titleGroup.append(child: titleLabel)

        let subtitleLabel = Label(str: "Capture interesting findings here.")
        subtitleLabel.add(cssClass: "dim-label")
        subtitleLabel.wrap = true
        subtitleLabel.justify = .center
        subtitleLabel.halign = .center
        subtitleLabel.setSizeRequest(width: 360, height: -1)
        titleGroup.append(child: subtitleLabel)

        stack.append(child: titleGroup)

        let steps = Box(orientation: .vertical, spacing: 8)
        steps.halign = .center
        steps.marginStart = 64

        for (index, text) in [
            "Attach to a running app or process.",
            "Add instruments to observe behavior.",
            "Pin any event from the stream to save it here.",
        ].enumerated() {
            steps.append(child: Self.makeWalkthroughStep(number: index + 1, text: text))
        }

        stack.append(child: steps)

        let button = Button(label: "New Note")
        button.add(cssClass: "suggested-action")
        button.add(cssClass: "pill")
        button.halign = .center
        button.marginTop = 6
        button.onClicked { _ in
            MainActor.assumeIsolated {
                onNewNote()
            }
        }
        stack.append(child: button)

        outer.append(child: stack)
        return outer
    }

    private func clearChildren(of container: Box) {
        var child = container.firstChild
        while let current = child {
            child = current.nextSibling
            container.remove(child: current)
        }
    }
}

@MainActor
private final class ActionHolder {
    var action: (() -> Void)?
}
