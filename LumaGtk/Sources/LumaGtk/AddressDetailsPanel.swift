import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class AddressDetailsPanel {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let address: UInt64

    private let headerAddrLabel: Label
    private let headerSymbolLabel: Label
    private let insightsBox: Box
    private let disasmBox: Box
    private let spinner: Spinner
    private let loadMoreButton: Button
    private let refreshButton: Button

    private var disasmLines: [DisassemblyLine] = []
    private var disasmRows: [Box] = []
    private var selectedIndex: Int? = nil
    private var loadTask: Task<Void, Never>?
    private var isLoadingMore = false

    private static let initialChunk = 40
    private static let moreChunk = 40

    init(engine: Engine, sessionID: UUID, address: UInt64) {
        self.engine = engine
        self.sessionID = sessionID
        self.address = address

        widget = Box(orientation: .vertical, spacing: 8)
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12
        widget.hexpand = true
        widget.vexpand = true

        let headerRow = Box(orientation: .horizontal, spacing: 8)

        headerAddrLabel = Label(str: String(format: "0x%llx", address))
        headerAddrLabel.add(cssClass: "monospace")
        headerAddrLabel.add(cssClass: "title-3")
        headerAddrLabel.halign = .start
        headerAddrLabel.selectable = true
        headerRow.append(child: headerAddrLabel)

        spinner = Spinner()
        spinner.spinning = false
        headerRow.append(child: spinner)

        let headerSpacer = Box(orientation: .horizontal, spacing: 0)
        headerSpacer.hexpand = true
        headerRow.append(child: headerSpacer)

        refreshButton = Button(label: "Refresh")
        refreshButton.add(cssClass: "flat")
        headerRow.append(child: refreshButton)

        widget.append(child: headerRow)

        headerSymbolLabel = Label(str: "")
        headerSymbolLabel.halign = .start
        headerSymbolLabel.add(cssClass: "dim-label")
        headerSymbolLabel.selectable = true
        headerSymbolLabel.wrap = true
        widget.append(child: headerSymbolLabel)

        widget.append(child: Separator(orientation: .horizontal))

        let insightsHeader = Label(str: "Insights")
        insightsHeader.halign = .start
        insightsHeader.add(cssClass: "heading")
        widget.append(child: insightsHeader)

        insightsBox = Box(orientation: .vertical, spacing: 4)
        widget.append(child: insightsBox)

        widget.append(child: Separator(orientation: .horizontal))

        let disasmHeader = Label(str: "Disassembly")
        disasmHeader.halign = .start
        disasmHeader.add(cssClass: "heading")
        widget.append(child: disasmHeader)

        disasmBox = Box(orientation: .vertical, spacing: 0)
        disasmBox.focusable = true

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setSizeRequest(width: 720, height: 360)
        scroll.set(child: disasmBox)
        widget.append(child: scroll)

        loadMoreButton = Button(label: "Load more")
        loadMoreButton.add(cssClass: "flat")
        loadMoreButton.halign = .center
        loadMoreButton.sensitive = false
        widget.append(child: loadMoreButton)

        refreshButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        loadMoreButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.loadMore() }
        }

        let keyController = EventControllerKey()
        keyController.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                self?.handleDisasmKey(keyval: keyval) ?? false
            }
        }
        disasmBox.add(controller: keyController)

        refresh()
    }

    private func handleDisasmKey(keyval: UInt) -> Bool {
        let key = Int32(keyval)
        guard !disasmLines.isEmpty else { return false }
        if key == Gdk.keyUp {
            moveSelection(by: -1)
            return true
        }
        if key == Gdk.keyDown {
            moveSelection(by: 1)
            return true
        }
        if key == Gdk.keyPageUp {
            moveSelection(by: -10)
            return true
        }
        if key == Gdk.keyPageDown {
            moveSelection(by: 10)
            return true
        }
        if key == Gdk.keyReturn {
            if let idx = selectedIndex {
                jumpFromLine(at: idx)
            }
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !disasmLines.isEmpty else { return }
        let current = selectedIndex ?? -1
        var next = current + delta
        if next < 0 { next = 0 }
        if next >= disasmLines.count { next = disasmLines.count - 1 }
        selectRow(at: next, focus: true)
    }

    private func selectRow(at index: Int, focus: Bool) {
        guard index >= 0, index < disasmRows.count else { return }
        if let prev = selectedIndex, prev >= 0, prev < disasmRows.count {
            disasmRows[prev].remove(cssClass: "selected")
        }
        selectedIndex = index
        let row = disasmRows[index]
        row.add(cssClass: "selected")
        if focus {
            _ = row.grabFocus()
        }
    }

    private func candidateTarget(for line: DisassemblyLine) -> UInt64? {
        if let t = line.branchTarget { return t }
        if let t = line.callTarget { return t }
        let asm = line.asmText.plainText
        return Self.firstHexAddress(in: asm)
    }

    private static func firstHexAddress(in s: String) -> UInt64? {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count, chars[i] == "0", (chars[i + 1] == "x" || chars[i + 1] == "X") {
                var j = i + 2
                let start = j
                while j < chars.count, chars[j].isHexDigit {
                    j += 1
                }
                if j > start {
                    let hex = String(chars[start..<j])
                    if let v = UInt64(hex, radix: 16) {
                        return v
                    }
                }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }

    private func jumpFromLine(at index: Int) {
        guard index >= 0, index < disasmLines.count else { return }
        let line = disasmLines[index]
        guard let target = candidateTarget(for: line) else { return }
        guard let destIndex = disasmLines.firstIndex(where: { $0.address == target }) else { return }
        selectRow(at: destIndex, focus: true)
    }

    func refresh() {
        loadTask?.cancel()
        isLoadingMore = false
        disasmLines = []
        disasmRows = []
        selectedIndex = nil
        clearChildren(of: disasmBox)
        clearChildren(of: insightsBox)
        loadMoreButton.sensitive = false

        guard let engine else { return }

        renderInsights(engine: engine)

        guard let node = engine.node(forSessionID: sessionID) else {
            headerSymbolLabel.setText(str: "Session detached.")
            return
        }
        guard let disassembler = engine.disassembler(forSessionID: sessionID) else {
            headerSymbolLabel.setText(str: "Disassembler unavailable.")
            return
        }

        spinner.spinning = true
        spinner.start()

        let addr = address
        let sid = sessionID
        loadTask = Task { @MainActor in
            defer {
                spinner.spinning = false
                spinner.stop()
            }

            await self.resolveSymbol(node: node, address: addr)

            let lines = await disassembler.disassemble(
                DisassemblyRequest(address: addr, count: Self.initialChunk, isDarkMode: true)
            )
            if Task.isCancelled { return }
            guard sid == self.sessionID else { return }

            self.disasmLines = lines
            for line in lines {
                let row = self.makeDisasmRow(line: line, index: self.disasmRows.count)
                self.disasmRows.append(row)
                self.disasmBox.append(child: row)
            }
            if !lines.isEmpty {
                self.selectRow(at: 0, focus: false)
            }
            self.loadMoreButton.sensitive = !lines.isEmpty
        }
    }

    private func resolveSymbol(node: ProcessNode, address: UInt64) async {
        do {
            let results = try await node.symbolicate(addresses: [address])
            guard let result = results.first else { return }
            headerSymbolLabel.setText(str: Self.describe(result))
        } catch {
            headerSymbolLabel.setText(str: "Symbolicate failed: \(error.localizedDescription)")
        }
    }

    private static func describe(_ result: SymbolicateResult) -> String {
        switch result {
        case .failure:
            return "Unknown symbol"
        case .module(let moduleName, let name):
            return "\(moduleName)!\(name)"
        case .file(let moduleName, let name, let fileName, let lineNumber):
            return "\(moduleName)!\(name) — \(fileName):\(lineNumber)"
        case .fileColumn(let moduleName, let name, let fileName, let lineNumber, let column):
            return "\(moduleName)!\(name) — \(fileName):\(lineNumber):\(column)"
        }
    }

    private func renderInsights(engine: Engine) {
        let insights = (try? engine.store.fetchInsights(sessionID: sessionID)) ?? []
        let matching = insights.filter { $0.lastResolvedAddress == address }
        if matching.isEmpty {
            let none = Label(str: "No saved insights for this address.")
            none.halign = .start
            none.add(cssClass: "dim-label")
            insightsBox.append(child: none)
            return
        }
        for insight in matching {
            let row = Box(orientation: .horizontal, spacing: 6)
            let kind = insight.kind == .disassembly ? "disasm" : "memory"
            let label = Label(str: "[\(kind)] \(insight.title)")
            label.halign = .start
            label.hexpand = true
            row.append(child: label)
            insightsBox.append(child: row)
        }

        let annotations = engine.addressAnnotations[sessionID]?[address]
        if let annotations, !annotations.decorations.isEmpty {
            let label = Label(str: "Annotations: \(annotations.decorations.count)")
            label.halign = .start
            label.add(cssClass: "dim-label")
            insightsBox.append(child: label)
        }
    }

    private func loadMore() {
        guard !isLoadingMore else { return }
        guard let last = disasmLines.last else { return }
        guard let engine, let disassembler = engine.disassembler(forSessionID: sessionID) else { return }

        isLoadingMore = true
        loadMoreButton.sensitive = false
        spinner.spinning = true
        spinner.start()

        let start = last.address
        Task { @MainActor in
            defer {
                isLoadingMore = false
                spinner.spinning = false
                spinner.stop()
            }

            let decoded = await disassembler.disassemble(
                DisassemblyRequest(address: start, count: Self.moreChunk, isDarkMode: true)
            )
            if Task.isCancelled { return }
            guard !decoded.isEmpty else { return }

            var page = decoded
            page.removeFirst()
            for line in page {
                let row = makeDisasmRow(line: line, index: disasmRows.count)
                disasmLines.append(line)
                disasmRows.append(row)
                disasmBox.append(child: row)
            }
            loadMoreButton.sensitive = !page.isEmpty
        }
    }

    private func makeDisasmRow(line: DisassemblyLine, index: Int) -> Box {
        let row = Box(orientation: .horizontal, spacing: 12)
        row.marginStart = 6
        row.marginEnd = 6
        row.add(cssClass: "luma-disasm-row")
        row.focusable = true

        let addrLabel = Label(str: line.addressText.plainText)
        addrLabel.add(cssClass: "monospace")
        addrLabel.add(cssClass: "dim-label")
        addrLabel.halign = .start
        addrLabel.setSizeRequest(width: 120, height: -1)
        row.append(child: addrLabel)

        let bytesLabel = Label(str: line.bytesText.plainText)
        bytesLabel.add(cssClass: "monospace")
        bytesLabel.add(cssClass: "dim-label")
        bytesLabel.halign = .start
        bytesLabel.setSizeRequest(width: 100, height: -1)
        row.append(child: bytesLabel)

        let asmLabel = Label(str: "")
        asmLabel.setMarkup(str: StyledTextPango.markup(for: line.asmText))
        asmLabel.add(cssClass: "monospace")
        asmLabel.halign = .start
        asmLabel.hexpand = true
        row.append(child: asmLabel)

        if let comment = line.commentText, !comment.isEmpty {
            let commentLabel = Label(str: "")
            commentLabel.setMarkup(str: StyledTextPango.markup(for: comment))
            commentLabel.add(cssClass: "monospace")
            commentLabel.add(cssClass: "dim-label")
            commentLabel.halign = .start
            row.append(child: commentLabel)
        }

        let click = GestureClick()
        click.set(button: 1)
        click.onPressed { [weak self] _, nPress, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let rowIndex = self.disasmRows.firstIndex(where: { $0 === row }) else { return }
                self.selectRow(at: rowIndex, focus: true)
                if nPress >= 2 {
                    self.jumpFromLine(at: rowIndex)
                }
            }
        }
        row.add(controller: click)

        return row
    }

    private func clearChildren(of box: Box) {
        while let child = box.firstChild {
            box.remove(child: child)
        }
    }

    static func present(from anchor: Widget, engine: Engine, sessionID: UUID, address: UInt64) {
        let panel = AddressDetailsPanel(engine: engine, sessionID: sessionID, address: address)

        let window = Window()
        window.title = String(format: "Address 0x%llx", address)
        window.setDefaultSize(width: 820, height: 640)
        window.modal = false
        window.destroyWithParent = true

        if let rootPtr = anchor.root?.ptr {
            window.setTransientFor(parent: WindowRef(raw: rootPtr))
        }

        let header = HeaderBar()
        let closeButton = Button(label: "Close")
        closeButton.onClicked { [weak window] _ in
            MainActor.assumeIsolated { window?.destroy() }
        }
        header.packEnd(child: closeButton)
        window.set(titlebar: WidgetRef(header))

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: WidgetRef(panel.widget.widget_ptr))
        window.set(child: scroll)

        Self.retain(panel: panel, window: window)

        window.present()
    }

    private static var retained: [ObjectIdentifier: AddressDetailsPanel] = [:]

    private static func retain(panel: AddressDetailsPanel, window: Window) {
        let key = ObjectIdentifier(window)
        retained[key] = panel
        let handler: (WindowRef) -> Bool = { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
            return false
        }
        window.onCloseRequest(handler: handler)
    }
}
