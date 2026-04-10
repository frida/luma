import CGtk
import Foundation
import Gdk
import GLibObject
import Gtk
import LumaCore

@MainActor
final class InsightDetailView {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private var insight: LumaCore.AddressInsight

    private let headerAddrLabel: Label
    private let headerSymbolLabel: Label
    private let statusLabel: Label
    private let spinner: Spinner
    private let refreshButton: Button

    private let contentHost: Box
    private let memoryHost: Box
    private let disasmHost: Box
    private let disasmBox: Box
    private let loadMoreButton: Button
    private var hexView: HexView?

    private var disasmLines: [DisassemblyLine] = []
    private var disasmRows: [Box] = []
    private var selectedIndex: Int? = nil
    private var loadTask: Task<Void, Never>?
    private var isLoadingMore = false
    private var isDarkMode = false
    private var themeSignalID: gulong = 0

    private static let initialChunk = 64
    private static let moreChunk = 64

    init(engine: Engine, sessionID: UUID, insight: LumaCore.AddressInsight) {
        self.engine = engine
        self.sessionID = sessionID
        self.insight = insight

        widget = Box(orientation: .vertical, spacing: 8)
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12
        widget.hexpand = true
        widget.vexpand = true

        let headerRow = Box(orientation: .horizontal, spacing: 8)

        headerAddrLabel = Label(str: insight.title)
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

        statusLabel = Label(str: "")
        statusLabel.halign = .start
        statusLabel.add(cssClass: "dim-label")
        statusLabel.visible = false
        widget.append(child: statusLabel)

        widget.append(child: Separator(orientation: .horizontal))

        contentHost = Box(orientation: .vertical, spacing: 0)
        contentHost.hexpand = true
        contentHost.vexpand = true
        widget.append(child: contentHost)

        memoryHost = Box(orientation: .vertical, spacing: 0)
        memoryHost.hexpand = true
        memoryHost.vexpand = true

        disasmHost = Box(orientation: .vertical, spacing: 4)
        disasmHost.hexpand = true
        disasmHost.vexpand = true

        disasmBox = Box(orientation: .vertical, spacing: 0)
        disasmBox.focusable = true
        let disasmScroll = ScrolledWindow()
        disasmScroll.hexpand = true
        disasmScroll.vexpand = true
        disasmScroll.setSizeRequest(width: 720, height: 360)
        disasmScroll.set(child: disasmBox)
        disasmHost.append(child: disasmScroll)

        loadMoreButton = Button(label: "Load more")
        loadMoreButton.add(cssClass: "flat")
        loadMoreButton.halign = .center
        loadMoreButton.sensitive = false
        disasmHost.append(child: loadMoreButton)

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
        disasmBox.install(controller: keyController)

        isDarkMode = Self.detectDarkMode()
        if let settings = gtk_settings_get_default() {
            themeSignalID = g_signal_connect_data(
                settings,
                "notify::gtk-theme-name",
                unsafeBitCast(themeChangedCallback, to: GCallback.self),
                Unmanaged.passUnretained(self).toOpaque(),
                nil,
                GConnectFlags(rawValue: 0)
            )
        }

        refresh()
    }

    deinit {
        if themeSignalID != 0, let settings = gtk_settings_get_default() {
            g_signal_handler_disconnect(settings, themeSignalID)
        }
    }

    private static func detectDarkMode() -> Bool {
        guard let settings = Settings.getDefault() else { return false }
        let value = settings.get(property: .gtkThemeName)
        guard let name = value.string else { return false }
        return name.localizedCaseInsensitiveContains("dark")
    }

    private func setContent(_ child: Widget) {
        var c = contentHost.firstChild
        while let cur = c {
            c = cur.nextSibling
            contentHost.remove(child: cur)
        }
        contentHost.append(child: child)
    }

    func refresh() {
        loadTask?.cancel()
        isLoadingMore = false
        disasmLines = []
        disasmRows = []
        selectedIndex = nil
        clearChildren(of: disasmBox)
        loadMoreButton.sensitive = false
        statusLabel.visible = false
        statusLabel.setText(str: "")

        guard let engine else { return }

        switch insight.kind {
        case .memory:
            let hex = HexView(bytes: Data())
            hexView = hex
            setContent(hex.widget)
        case .disassembly:
            hexView = nil
            setContent(disasmHost)
        }

        guard let node = engine.node(forSessionID: sessionID) else {
            showStatus("Session detached.")
            return
        }

        spinner.spinning = true
        spinner.start()

        let anchor = insight.anchor
        let byteCount = insight.byteCount
        let kind = insight.kind

        loadTask = Task { @MainActor in
            defer {
                spinner.spinning = false
                spinner.stop()
            }

            let resolved: UInt64
            do {
                resolved = try await node.resolve(anchor)
            } catch {
                if Task.isCancelled { return }
                showStatus("Resolve failed: \(error.localizedDescription)")
                return
            }
            if Task.isCancelled { return }

            insight.lastResolvedAddress = resolved
            try? engine.store.save(insight)

            headerAddrLabel.setText(str: String(format: "0x%llx", resolved))
            await resolveSymbol(node: node, address: resolved)

            switch kind {
            case .memory:
                do {
                    let bytes = try await node.readRemoteMemory(at: resolved, count: byteCount)
                    if Task.isCancelled { return }
                    hexView?.setBytes(Data(bytes), baseAddress: resolved)
                } catch {
                    if Task.isCancelled { return }
                    showStatus("Read failed: \(error.localizedDescription)")
                }

            case .disassembly:
                guard let disassembler = engine.disassembler(forSessionID: sessionID) else {
                    showStatus("Disassembler unavailable.")
                    return
                }
                let lines = await disassembler.disassemble(
                    DisassemblyRequest(address: resolved, count: Self.initialChunk, isDarkMode: self.isDarkMode)
                )
                if Task.isCancelled { return }

                self.disasmLines = lines
                for line in lines {
                    let row = self.makeDisasmRow(line: line)
                    self.disasmRows.append(row)
                    self.disasmBox.append(child: row)
                }
                if !lines.isEmpty {
                    self.selectRow(at: 0, focus: false)
                }
                self.loadMoreButton.sensitive = !lines.isEmpty
            }
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.setText(str: text)
        statusLabel.visible = true
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
            return "\(moduleName)!\(name) \u{2014} \(fileName):\(lineNumber)"
        case .fileColumn(let moduleName, let name, let fileName, let lineNumber, let column):
            return "\(moduleName)!\(name) \u{2014} \(fileName):\(lineNumber):\(column)"
        }
    }

    private func loadMore() {
        guard !isLoadingMore else { return }
        guard insight.kind == .disassembly else { return }
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
                DisassemblyRequest(address: start, count: Self.moreChunk, isDarkMode: self.isDarkMode)
            )
            if Task.isCancelled { return }
            guard !decoded.isEmpty else { return }

            var page = decoded
            page.removeFirst()
            for line in page {
                let row = makeDisasmRow(line: line)
                disasmLines.append(line)
                disasmRows.append(row)
                disasmBox.append(child: row)
            }
            loadMoreButton.sensitive = !page.isEmpty
        }
    }

    private func handleDisasmKey(keyval: UInt) -> Bool {
        let key = Int32(keyval)
        guard !disasmLines.isEmpty else { return false }
        if key == Gdk.keyUp || key == Gdk.keyk {
            moveSelection(by: -1); return true
        }
        if key == Gdk.keyDown || key == Gdk.keyj {
            moveSelection(by: 1); return true
        }
        if key == Gdk.keyPageUp {
            moveSelection(by: -10); return true
        }
        if key == Gdk.keyPageDown {
            moveSelection(by: 10); return true
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
        return nil
    }

    private func jumpFromLine(at index: Int) {
        guard index >= 0, index < disasmLines.count else { return }
        let line = disasmLines[index]
        guard let target = candidateTarget(for: line) else { return }
        if let destIndex = disasmLines.firstIndex(where: { $0.address == target }) {
            selectRow(at: destIndex, focus: true)
            return
        }
        guard let engine else { return }
        do {
            let newInsight = try engine.getOrCreateInsight(sessionID: sessionID, pointer: target, kind: .disassembly)
            AddressActionMenu.navigator?(sessionID, newInsight.id)
        } catch {
            AddressActionMenu.errorReporter?("Can\u{2019}t jump here: \(error.localizedDescription)")
        }
    }

    private func makeDisasmRow(line: DisassemblyLine) -> Box {
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

        let address = line.address
        let addrGesture = GestureClick()
        addrGesture.set(button: 3)
        addrGesture.propagationPhase = GTK_PHASE_CAPTURE
        addrGesture.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated {
                self?.showAddressMenu(at: addrLabel, x: x, y: y, address: address)
            }
        }
        addrLabel.install(controller: addrGesture)

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
        row.install(controller: click)

        return row
    }

    private func showAddressMenu(at anchor: Widget, x: Double, y: Double, address: UInt64) {
        guard let engine else { return }

        let sessionID = self.sessionID
        var sections: [[ContextMenu.Item]] = []

        sections.append([
            .init("Copy Address") {
                let hex = String(format: "0x%llx", address)
                guard let display = gdk_display_get_default() else { return }
                let clipboard = gdk_display_get_clipboard(display)
                hex.withCString { gdk_clipboard_set_text(clipboard, $0) }
            },
        ])

        var insightItems: [ContextMenu.Item] = [
            .init("Open Memory") {
                Self.navigateToInsight(engine: engine, sessionID: sessionID, address: address, kind: .memory)
            },
            .init("Open Disassembly") {
                Self.navigateToInsight(engine: engine, sessionID: sessionID, address: address, kind: .disassembly)
            },
        ]

        let actions = engine.addressActions(sessionID: sessionID, address: address)
        for action in actions {
            insightItems.append(ContextMenu.Item(action.title, destructive: action.role == .destructive) {
                Task { @MainActor in
                    _ = await action.perform()
                }
            })
        }

        sections.append(insightItems)

        ContextMenu.present(sections, at: anchor, x: x, y: y)
    }

    private static func navigateToInsight(engine: Engine, sessionID: UUID, address: UInt64, kind: AddressInsight.Kind) {
        do {
            let insight = try engine.getOrCreateInsight(sessionID: sessionID, pointer: address, kind: kind)
            AddressActionMenu.navigator?(sessionID, insight.id)
        } catch {
            AddressActionMenu.errorReporter?("Can\u{2019}t open insight: \(error.localizedDescription)")
        }
    }

    fileprivate func handleThemeChanged() {
        let wasDark = isDarkMode
        isDarkMode = Self.detectDarkMode()
        if isDarkMode != wasDark {
            refresh()
        }
    }

    private func clearChildren(of box: Box) {
        while let child = box.firstChild {
            box.remove(child: child)
        }
    }
}

private let themeChangedCallback: @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?
) -> Void = { _, _, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let view = Unmanaged<InsightDetailView>.fromOpaque(ptr).takeUnretainedValue()
        view.handleThemeChanged()
    }
}
