import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class CodeShareUIKind: InstrumentUIKind {
    func makeDetailUI(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> InstrumentDetailUI {
        CodeShareDetailUI(engine: engine, instrument: instrument)
    }
}

@MainActor
private final class CodeShareDetailUI: InstrumentDetailUI {
    let widget: Widget

    private weak var engine: Engine?
    private var instrument: LumaCore.InstrumentInstance
    private let column: Box

    init(engine: Engine, instrument: LumaCore.InstrumentInstance) {
        self.engine = engine
        self.instrument = instrument

        let column = Box(orientation: .vertical, spacing: 8)
        column.hexpand = true
        column.vexpand = true
        column.marginStart = 24
        column.marginEnd = 24
        column.marginTop = 8
        column.marginBottom = 12
        self.column = column
        widget = column

        rebuild()
    }

    func update(_ instrument: LumaCore.InstrumentInstance) {
        guard instrument.configJSON != self.instrument.configJSON else { return }
        self.instrument = instrument
        rebuild()
    }

    private func rebuild() {
        while let child = column.firstChild {
            column.remove(child: child)
        }

        guard let config = try? JSONDecoder().decode(CodeShareConfig.self, from: instrument.configJSON) else {
            column.append(child: InstrumentUIHelpers.errorLabel("Failed to decode codeshare config"))
            return
        }

        let title = Label(str: config.name.isEmpty ? "Code Share" : config.name)
        title.add(cssClass: "title-3")
        title.halign = .start
        column.append(child: title)

        if let project = config.project {
            let sub = Label(str: "@\(project.owner)/\(project.slug)")
            sub.add(cssClass: "dim-label")
            sub.add(cssClass: "caption")
            sub.halign = .start
            column.append(child: sub)
        } else {
            let sub = Label(str: "Local snippet (not published)")
            sub.add(cssClass: "dim-label")
            sub.add(cssClass: "caption")
            sub.halign = .start
            column.append(child: sub)
        }

        let current = config.currentSourceHash
        if config.lastReviewedHash == nil {
            column.append(child: InstrumentUIHelpers.makeBanner("⚠ Not yet reviewed. Please audit this script before enabling."))
        } else if config.lastReviewedHash != current {
            column.append(child: InstrumentUIHelpers.makeBanner("✎ Locally modified since last review."))
        } else if let synced = config.lastSyncedHash, synced != current {
            column.append(child: InstrumentUIHelpers.makeBanner("↻ Differs from last synced version on CodeShare."))
        }

        let nameRow = Box(orientation: .horizontal, spacing: 8)
        nameRow.append(child: Label(str: "Name"))
        let nameEntry = Entry()
        nameEntry.text = config.name
        nameEntry.hexpand = true
        nameRow.append(child: nameEntry)
        column.append(child: nameRow)

        let descRow = Box(orientation: .horizontal, spacing: 8)
        descRow.append(child: Label(str: "Description"))
        let descEntry = Entry()
        descEntry.text = config.description
        descEntry.hexpand = true
        descRow.append(child: descEntry)
        column.append(child: descRow)

        let codeHeader = Label(str: "Source")
        codeHeader.halign = .start
        codeHeader.add(cssClass: "heading")
        column.append(child: codeHeader)

        let textView = TextView()
        textView.hexpand = true
        textView.vexpand = true
        textView.monospace = true
        textView.topMargin = 6
        textView.bottomMargin = 6
        textView.leftMargin = 6
        textView.rightMargin = 6
        textView.buffer?.set(text: config.source, len: -1)
        let codeScroll = ScrolledWindow()
        codeScroll.hexpand = true
        codeScroll.vexpand = true
        codeScroll.setSizeRequest(width: -1, height: 280)
        codeScroll.set(child: textView)
        column.append(child: codeScroll)

        let actions = Box(orientation: .horizontal, spacing: 8)
        let spacer = Label(str: "")
        spacer.hexpand = true
        actions.append(child: spacer)

        let saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.sensitive = false
        actions.append(child: saveButton)
        column.append(child: actions)

        let updateDirty = {
            let dirty =
                (nameEntry.text ?? "") != config.name
                || (descEntry.text ?? "") != config.description
                || readText(from: textView) != config.source
            saveButton.sensitive = dirty
        }
        nameEntry.onChanged { _ in MainActor.assumeIsolated { updateDirty() } }
        descEntry.onChanged { _ in MainActor.assumeIsolated { updateDirty() } }
        textView.buffer?.onChanged { _ in MainActor.assumeIsolated { updateDirty() } }

        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var updated = config
                updated.name = nameEntry.text ?? ""
                updated.description = descEntry.text ?? ""
                updated.source = readText(from: textView)
                updated.lastReviewedHash = updated.currentSourceHash
                guard let data = try? JSONEncoder().encode(updated) else { return }
                self.apply(configJSON: data)
            }
        }
    }

    private func apply(configJSON: Data) {
        instrument.configJSON = configJSON
        guard let engine else { return }
        let snapshot = instrument
        Task { @MainActor in
            await engine.applyInstrumentConfig(snapshot, configJSON: configJSON)
        }
    }
}

@MainActor
private func readText(from textView: TextView) -> String {
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
