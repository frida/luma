import Foundation
import Gtk
import LumaCore

@MainActor
final class REPLPane {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let cellsBox: Box
    private let cellsScroll: ScrolledWindow
    private let inputEntry: Entry
    private let runButton: Button
    private let timeFormatter: DateFormatter

    private var cells: [LumaCore.REPLCell] = []
    private var observation: StoreObservation?

    init(engine: Engine, sessionID: UUID) {
        self.engine = engine
        self.sessionID = sessionID

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        cellsBox = Box(orientation: .vertical, spacing: 4)
        cellsBox.marginStart = 16
        cellsBox.marginEnd = 16
        cellsBox.marginTop = 12
        cellsBox.marginBottom = 12
        cellsBox.hexpand = true

        cellsScroll = ScrolledWindow()
        cellsScroll.hexpand = true
        cellsScroll.vexpand = true
        cellsScroll.set(child: cellsBox)
        widget.append(child: cellsScroll)

        widget.append(child: Separator(orientation: .horizontal))

        let inputRow = Box(orientation: .horizontal, spacing: 8)
        inputRow.marginStart = 12
        inputRow.marginEnd = 12
        inputRow.marginTop = 6
        inputRow.marginBottom = 6

        let prompt = Label(str: "›")
        prompt.add(cssClass: "monospace")
        prompt.add(cssClass: "dim-label")
        inputRow.append(child: prompt)

        inputEntry = Entry()
        inputEntry.hexpand = true
        inputEntry.placeholderText = "Enter JavaScript\u{2026}"
        inputRow.append(child: inputEntry)

        runButton = Button(label: "Run")
        runButton.add(cssClass: "suggested-action")
        inputRow.append(child: runButton)

        widget.append(child: inputRow)

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        inputEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated {
                self?.submit()
            }
        }
        runButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.submit()
            }
        }

        loadCells()
        observation = engine.store.observeREPLCells(sessionID: sessionID) { [weak self] newCells in
            Task { @MainActor in
                self?.cells = newCells
                self?.refresh()
            }
        }
        refresh()
        updateInputState()
    }


    func updateInputState() {
        let isAttached = engine?.node(forSessionID: sessionID) != nil
        inputEntry.sensitive = isAttached
        runButton.sensitive = isAttached
        if !isAttached {
            inputEntry.placeholderText = "Session detached — re-establish to continue."
        } else {
            inputEntry.placeholderText = "Enter JavaScript\u{2026}"
        }
    }

    private func loadCells() {
        guard let engine else { return }
        cells = (try? engine.store.fetchREPLCells(sessionID: sessionID)) ?? []
    }

    private func submit() {
        let raw = inputEntry.text ?? ""
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let node = engine?.node(forSessionID: sessionID) else {
            return
        }
        inputEntry.text = ""
        Task { @MainActor in
            await node.evalInREPL(code)
        }
    }

    private func refresh() {
        clearChildren(of: cellsBox)
        for cell in cells.sorted(by: { $0.timestamp < $1.timestamp }) {
            cellsBox.append(child: makeRow(for: cell))
        }
    }

    private func makeRow(for cell: LumaCore.REPLCell) -> Widget {
        if cell.isSessionBoundary {
            let bar = Box(orientation: .horizontal, spacing: 8)
            bar.marginTop = 6
            bar.marginBottom = 6
            let separator = Separator(orientation: .horizontal)
            separator.hexpand = true
            separator.valign = .center
            let label = Label(str: cell.code)
            label.add(cssClass: "dim-label")
            label.add(cssClass: "caption")
            bar.append(child: separator)
            bar.append(child: label)
            return bar
        }

        let column = Box(orientation: .vertical, spacing: 2)
        column.hexpand = true

        let codeRow = Box(orientation: .horizontal, spacing: 8)
        let prompt = Label(str: "›")
        prompt.add(cssClass: "monospace")
        prompt.add(cssClass: "dim-label")
        codeRow.append(child: prompt)
        let codeLabel = Label(str: cell.code)
        codeLabel.add(cssClass: "monospace")
        codeLabel.halign = .start
        codeLabel.hexpand = true
        codeLabel.wrap = true
        codeLabel.selectable = true
        codeRow.append(child: codeLabel)
        column.append(child: codeRow)

        let resultLabel = Label(str: format(result: cell.result))
        resultLabel.add(cssClass: "monospace")
        resultLabel.halign = .start
        resultLabel.hexpand = true
        resultLabel.marginStart = 16
        resultLabel.wrap = true
        resultLabel.selectable = true
        column.append(child: resultLabel)

        return column
    }

    private func format(result: LumaCore.REPLCell.Result) -> String {
        switch result {
        case .text(let s):
            return s
        case .js(let value):
            return String(describing: value)
        case .binary(let data, let meta):
            let kind = meta?.typedArray ?? "binary"
            return "<\(kind) \(data.count) bytes>"
        }
    }

    private func clearChildren(of container: Box) {
        var child = container.firstChild
        while let current = child {
            child = current.nextSibling
            container.remove(child: current)
        }
    }
}
