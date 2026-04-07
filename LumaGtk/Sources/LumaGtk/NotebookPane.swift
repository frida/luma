import CGtk
import Foundation
import Gtk
import LumaCore
import Observation

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

        emptyState = MainWindow.makeEmptyState(
            icon: "document-new-symbolic",
            title: "Notebook is empty",
            subtitle: "Pin REPL output, JS values, or notes here.",
            actionLabel: "New Note",
            onAction: { [weak engine] in
                guard let engine else { return }
                let note = LumaCore.NotebookEntry(
                    title: "Note",
                    details: "",
                    binaryData: nil,
                    processName: nil,
                    isUserNote: true
                )
                engine.addNotebookEntry(note, after: nil)
            }
        )
        emptyState.hexpand = true
        emptyState.vexpand = true

        contentBox.append(child: emptyState)

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
        overlay.addOverlay(widget: newNoteButton)

        widget.append(child: overlay)

        newNoteButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.addUserNote()
            }
        }

        observe()
        refresh()
    }

    // MARK: - Observation

    private func observe() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.notebookEntries
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refresh() {
        guard let engine else { return }
        let entries = engine.notebookEntries.sorted { $0.timestamp < $1.timestamp }

        clearChildren(of: contentBox)
        clearChildren(of: entriesBox)

        if entries.isEmpty {
            contentBox.append(child: emptyState)
            return
        }

        for entry in entries {
            if entry.isUserNote
                && entry.title == "Note"
                && entry.details.isEmpty
                && !autoEditedEntries.contains(entry.id)
            {
                autoEditedEntries.insert(entry.id)
                editingEntries.insert(entry.id)
            }
            entriesBox.append(child: makeRow(for: entry))
        }
        contentBox.append(child: scroll)
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
        engine.addNotebookEntry(note, after: other)
    }

    private func deleteEntry(_ entry: LumaCore.NotebookEntry) {
        editingEntries.remove(entry.id)
        autoEditedEntries.remove(entry.id)
        engine?.deleteNotebookEntry(entry)
    }

    private func beginEditing(_ entry: LumaCore.NotebookEntry) {
        editingEntries.insert(entry.id)
        refresh()
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
                let valueWidget = JSInspectValueWidget.make(
                    value: jsValue,
                    engine: engine,
                    sessionID: UUID()
                )
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
            let dump = NotebookPane.formatHexdumpPreview(data: data, maxLines: 8)
            let binaryLabel = Label(str: dump)
            binaryLabel.add(cssClass: "monospace")
            binaryLabel.halign = .start
            binaryLabel.xalign = 0
            binaryLabel.selectable = true
            inner.append(child: binaryLabel)
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
        deleteButton.add(cssClass: "destructive-action")
        deleteButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deleteEntry(entry)
            }
        }
        header.append(child: deleteButton)

        return header
    }

    private func makeEditableBody(for entry: LumaCore.NotebookEntry) -> Box {
        let column = Box(orientation: .vertical, spacing: 6)
        column.hexpand = true

        let titleEntry = Entry()
        titleEntry.text = entry.title
        titleEntry.placeholderText = "Title"
        titleEntry.hexpand = true
        column.append(child: titleEntry)

        let textView = TextView()
        textView.hexpand = true
        textView.vexpand = true
        textView.wrapMode = .word
        textView.topMargin = 6
        textView.bottomMargin = 6
        textView.leftMargin = 6
        textView.rightMargin = 6
        if !entry.details.isEmpty {
            entry.details.withCString { cstr in
                textView.buffer.set(text: cstr, len: -1)
            }
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
                self.refresh()
            }
        }

        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let newTitle = titleEntry.text ?? ""
                let newDetails = NotebookPane.text(from: textView)
                self.commitEdits(original: entry, title: newTitle, details: newDetails)
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

    private func clearChildren(of container: Box) {
        var child = container.firstChild
        while let current = child {
            child = current.nextSibling
            container.remove(child: current)
        }
    }
}
