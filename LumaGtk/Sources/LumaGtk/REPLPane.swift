import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class REPLPane {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let bannerSlot: Box
    private var currentBanner: Widget?
    private var lastBannerPhase: LumaCore.ProcessSession.Phase?
    private var lastBannerError: String?
    private var lastBannerGatingActive: Bool?
    private var lastBannerArmed: Bool?
    private let console: ConsoleView
    private let timeFormatter: DateFormatter
    private weak var owner: MainWindow?

    private var cells: [LumaCore.REPLCell] = []
    private var rowKeepers: [Any] = []
    private var mode: LumaCore.REPLLanguage = .javascript
    private var draftSaveTask: Task<Void, Never>?

    init(engine: Engine, sessionID: UUID, owner: MainWindow? = nil) {
        self.engine = engine
        self.sessionID = sessionID
        self.owner = owner

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        bannerSlot = Box(orientation: .vertical, spacing: 0)
        bannerSlot.hexpand = true
        widget.append(child: bannerSlot)

        console = ConsoleView(
            style: ConsoleView.Style(
                promptGlyph: "\u{203A}",
                placeholder: "Enter JavaScript\u{2026}",
                runButtonLabel: "Run"
            ),
            emptyState: REPLPane.makeEmptyState()
        )
        widget.append(child: console.widget)

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        mode = engine.replLanguage(forSessionID: sessionID)

        console.onSubmit = { [weak self] code in self?.submit(code: code) }
        console.onComplete = { [weak self] code, cursor in
            guard let self, let node = self.engine?.node(forSessionID: self.sessionID) else { return [] }
            return await node.completeInREPL(code: code, cursor: cursor, language: self.mode)
        }
        console.onPromptClicked = { [weak self] in self?.toggleMode() }
        console.commandInterceptor = { [weak self] code in self?.handleModeCommand(code) ?? false }
        console.onInputChanged = { [weak self] text in self?.scheduleDraftSave(text) }
        console.onHistoryRecalled = { [weak self] code in
            guard let self,
                let cell = self.cells.last(where: { !$0.isSessionBoundary && $0.code == code })
            else { return }
            self.setMode(cell.language)
        }
        console.onBackgroundContextMenu = { [weak self] anchor, x, y in
            self?.presentScrollAreaContextMenu(at: anchor, x: x, y: y)
        }

        applyMode()
        console.setInputText(engine.replDraft(forSessionID: sessionID) ?? "")

        loadCells()
        applySessionState()
    }

    private func applyMode() {
        console.setPromptMarkup(Self.promptMarkup(for: mode))
        console.completionReplacesWholeToken = mode == .r2
    }

    private func toggleMode() {
        setMode(mode == .javascript ? .r2 : .javascript)
        console.focusInput()
    }

    private func handleModeCommand(_ code: String) -> Bool {
        switch code {
        case ":": setMode(mode == .javascript ? .r2 : .javascript)
        case ":js", ":javascript": setMode(.javascript)
        case ":r2": setMode(.r2)
        default: return false
        }
        return true
    }

    private func setMode(_ newMode: LumaCore.REPLLanguage) {
        guard newMode != mode else { return }
        mode = newMode
        applyMode()
        applySessionState()
        engine?.setREPLLanguage(sessionID: sessionID, newMode)
    }

    private func activePlaceholder() -> String {
        mode == .r2 ? "Enter an r2 command\u{2026}" : "Enter JavaScript\u{2026}"
    }

    private func scheduleDraftSave(_ text: String) {
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.engine?.setREPLDraft(sessionID: self.sessionID, text.isEmpty ? nil : text)
        }
    }

    private static func promptMarkup(for language: LumaCore.REPLLanguage) -> String {
        let glyph = language == .r2 ? "\u{00BB}" : "\u{203A}"
        return "<span alpha=\"55%\">\(glyph)</span>"
    }

    func applySessionState() {
        guard let engine else { return }
        let session = engine.sessions.first(where: { $0.id == sessionID })
        let isLive = isLive(session: session, engine: engine)
        let canInteract = !engine.collaboration.isCollaborative || engine.collaboration.isOwner
        let canType = isLive && canInteract

        let placeholder: String
        if isLive {
            placeholder = activePlaceholder()
        } else if let session {
            placeholder = inactiveMessage(for: session)
        } else {
            placeholder = "Session not attached."
        }
        console.setInputEnabled(canType, placeholder: placeholder)

        updateBanner(for: session, engine: engine)
    }

    private func isLive(session: LumaCore.ProcessSession?, engine: Engine) -> Bool {
        guard let session else { return false }
        if engine.node(forSessionID: sessionID) != nil { return true }
        if let host = session.host,
           host.id != engine.localUserID,
           session.phase == .attached || session.phase == .attaching
        {
            return true
        }
        return false
    }

    func focusInput() {
        console.focusInput()
    }

    func appendCell(_ cell: LumaCore.REPLCell) {
        guard cell.sessionID == sessionID else { return }
        cells.append(cell)
        console.appendEntry(makeRow(for: cell))
    }

    private func updateBanner(for session: LumaCore.ProcessSession?, engine: Engine) {
        let wantsBanner = session.map { SessionDetachedBanner.shouldShow(for: $0) } ?? false
        let phase = session?.phase
        let error = session?.lastError
        let armed: Bool? = session.map {
            if case .armed = $0.armingState { return true }
            return false
        }
        let gatingActive: Bool? = session.map { engine.isGatingActive(forDeviceID: $0.deviceID) }
        let bannerDirty = wantsBanner != (currentBanner != nil)
            || phase != lastBannerPhase
            || error != lastBannerError
            || armed != lastBannerArmed
            || gatingActive != lastBannerGatingActive
        lastBannerPhase = phase
        lastBannerError = error
        lastBannerArmed = armed
        lastBannerGatingActive = gatingActive

        guard bannerDirty else { return }

        if let rootPtr = widget.root?.ptr {
            WindowRef(raw: rootPtr).focus = nil
        }
        if let existing = currentBanner {
            bannerSlot.remove(child: existing)
            currentBanner = nil
        }
        guard let session, wantsBanner else { return }

        let banner = SessionDetachedBanner.make(
            for: session,
            gatingActive: engine.isGatingActive(forDeviceID: session.deviceID),
            canReattach: engine.canTakeHosting(session),
            onReattach: { [weak self] in self?.owner?.reestablishSession(id: session.id) },
            onDisarm: { [weak engine] in
                Task { @MainActor in await engine?.disarmSession(id: session.id) }
            },
            onArm: { [weak self] in self?.owner?.presentArmDialog(session: session) },
            onResumeGating: { [weak engine] in
                Task { @MainActor in await engine?.resumeGating(forSessionID: session.id) }
            }
        )
        bannerSlot.append(child: banner)
        currentBanner = banner
    }

    private func inactiveMessage(for session: LumaCore.ProcessSession) -> String {
        if case .armed = session.armingState {
            if engine?.isGatingActive(forDeviceID: session.deviceID) == true {
                return "Waiting for a matching launch — REPL available once captured."
            }
            return "Armed but inactive — resume spawn gating to capture launches."
        }
        if let host = session.host,
           host.id != engine?.localUserID,
           engine?.node(forSessionID: session.id) == nil,
           session.phase == .attached || session.phase == .attaching
        {
            return "Hosted by @\(host.id) on \(session.deviceName) — REPL runs on the hosting device."
        }
        if session.lastAttachedAt != nil {
            return "Session detached — use \(session.kind.reestablishLabel) to continue."
        }
        return "Session not attached — arm it from the banner above."
    }

    private func loadCells() {
        guard let engine else { return }
        cells = (try? engine.store.fetchREPLCells(sessionID: sessionID)) ?? []
        console.clearEntries()
        rowKeepers.removeAll()
        let sorted = cells.sorted(by: { $0.timestamp < $1.timestamp })
        for cell in sorted {
            console.appendEntry(makeRow(for: cell))
        }
        console.setHistory(sorted.filter { !$0.isSessionBoundary }.map { $0.code })
    }

    private func submit(code: String) {
        guard let engine else { return }
        if engine.isHostedRemotelyLive(sessionID) {
            let cellID = UUID()
            let placeholder = LumaCore.REPLCell(
                id: cellID,
                sessionID: sessionID,
                code: code,
                language: mode,
                result: .text("Running\u{2026}"),
                timestamp: Date()
            )
            try? engine.store.save(placeholder)
            engine.collaboration.sendReplEvalRequest(
                sessionID: sessionID,
                code: code,
                language: mode,
                cellID: cellID
            )
        } else if let node = engine.node(forSessionID: sessionID) {
            Task { @MainActor in
                await node.evalInREPL(code, language: mode)
            }
        }
    }

    private func makeRow(for cell: LumaCore.REPLCell) -> Widget {
        if cell.isSessionBoundary {
            let bar = Box(orientation: .horizontal, spacing: 8)
            bar.marginTop = 6
            bar.marginBottom = 6
            let leadingSeparator = Separator(orientation: .horizontal)
            leadingSeparator.hexpand = true
            leadingSeparator.valign = .center
            let time = DateFormatter.localizedString(
                from: cell.timestamp, dateStyle: .none, timeStyle: .short)
            let label = Label(str: "\(cell.code) at \(time)")
            label.add(cssClass: "dim-label")
            label.add(cssClass: "caption")
            let trailingSeparator = Separator(orientation: .horizontal)
            trailingSeparator.hexpand = true
            trailingSeparator.valign = .center
            bar.append(child: leadingSeparator)
            bar.append(child: label)
            bar.append(child: trailingSeparator)
            return bar
        }

        let column = Box(orientation: .vertical, spacing: 2)
        column.hexpand = true

        let codeRow = Box(orientation: .horizontal, spacing: 6)
        let prompt = Label(str: "")
        prompt.add(cssClass: "monospace")
        prompt.useMarkup = true
        prompt.valign = .start
        prompt.setMarkup(str: Self.promptMarkup(for: cell.language))
        codeRow.append(child: prompt)
        let codeLabel = Label(str: cell.code)
        codeLabel.add(cssClass: "monospace")
        codeLabel.add(cssClass: "repl-cell-code")
        codeLabel.halign = .start
        codeLabel.xalign = 0
        codeLabel.wrap = false
        codeLabel.selectable = true
        let codeScroll = ScrolledWindow()
        codeScroll.setPolicy(hscrollbarPolicy: GTK_POLICY_AUTOMATIC, vscrollbarPolicy: GTK_POLICY_NEVER)
        codeScroll.propagateNaturalHeight = true
        codeScroll.hexpand = true
        codeScroll.vexpand = false
        codeScroll.valign = .start
        codeScroll.set(child: codeLabel)
        codeRow.append(child: codeScroll)
        let timeLabel = Label(str: DateFormatter.localizedString(
            from: cell.timestamp, dateStyle: .none, timeStyle: .short))
        timeLabel.add(cssClass: "caption")
        timeLabel.add(cssClass: "dim-label")
        timeLabel.valign = .start
        timeLabel.tooltipText = DateFormatter.localizedString(
            from: cell.timestamp, dateStyle: .medium, timeStyle: .medium)
        codeRow.append(child: timeLabel)
        column.append(child: codeRow)

        if !Self.isResultEmpty(cell.result) {
            let resultRow = Box(orientation: .horizontal, spacing: 6)
            resultRow.hexpand = true
            let resultArrow = Label(str: "\u{2190}")
            resultArrow.add(cssClass: "monospace")
            resultArrow.add(cssClass: "dim-label")
            resultArrow.valign = .start
            resultRow.append(child: resultArrow)

            let resultWidget: Widget
            var fillsWidth = false
            switch cell.result {
            case .js(let value):
                if let engine {
                    let wrapper = JSInspectValueWidget.make(value: value, engine: engine, sessionID: sessionID) { [weak self] in
                        self?.console.pinToBottom()
                    }
                    rowKeepers.append(wrapper)
                    resultWidget = wrapper.widget
                } else {
                    resultWidget = makePlainResultLabel(text: format(result: cell.result))
                }
            case .styled(let styled):
                let view = REPLStyledResult(styled) { [weak self] in self?.console.pinToBottom() }
                rowKeepers.append(view)
                resultWidget = view.widget
                fillsWidth = true
            case .binary(let data, let meta):
                let column2 = Box(orientation: .vertical, spacing: 4)
                column2.hexpand = true
                column2.halign = .start
                let kind = meta?.typedArray ?? "binary"
                let header = Label(str: "<\(kind) \(data.count) bytes>")
                header.add(cssClass: "monospace")
                header.halign = .start
                column2.append(child: header)
                let hex = HexView(bytes: data, baseAddress: meta?.baseAddress ?? 0)
                rowKeepers.append(hex)
                hex.widget.hexpand = true
                hex.widget.vexpand = false
                hex.widget.halign = .start
                column2.append(child: hex.widget)
                resultWidget = column2
            case .text(let s):
                let view = REPLStyledResult(LumaCore.StyledText(s)) { [weak self] in self?.console.pinToBottom() }
                rowKeepers.append(view)
                resultWidget = view.widget
                fillsWidth = true
            }
            resultWidget.hexpand = true
            resultWidget.halign = fillsWidth ? .fill : .start
            resultRow.append(child: resultWidget)
            column.append(child: resultRow)
        }

        attachContextMenu(to: column, cell: cell)

        return column
    }

    private static func isResultEmpty(_ result: LumaCore.REPLCell.Result) -> Bool {
        switch result {
        case .text(let s): return s.isEmpty
        case .styled(let s): return s.isEmpty
        case .js(let v): return v == .undefined
        case .binary(let data, _): return data.isEmpty
        }
    }

    private func makePlainResultLabel(text: String) -> Widget {
        let label = Label(str: DisplayTruncation.truncated(text))
        label.add(cssClass: "monospace")
        label.halign = .start
        label.hexpand = true
        label.wrap = true
        label.selectable = true
        return label
    }

    private func attachContextMenu(to anchor: Box, cell: LumaCore.REPLCell) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.onPressed { [anchor, weak self] _, _, x, y in
            MainActor.assumeIsolated {
                self?.presentCellContextMenu(at: anchor, x: x, y: y, cell: cell)
            }
        }
        anchor.install(controller: gesture)
    }

    private func presentCellContextMenu(at anchor: Widget, x: Double, y: Double, cell: LumaCore.REPLCell) {
        ContextMenu.present([
            [
                .init("Add to Notebook") { [weak self] in
                    self?.addCellToNotebook(cell)
                },
            ],
            [
                .init("Clear History", destructive: true) { [weak self] in
                    self?.clearHistory()
                },
            ],
        ], at: anchor, x: x, y: y)
    }

    private func presentScrollAreaContextMenu(at anchor: Widget, x: Double, y: Double) {
        ContextMenu.present([
            [
                .init("Clear History", destructive: true) { [weak self] in
                    self?.clearHistory()
                },
            ],
        ], at: anchor, x: x, y: y)
    }

    private func clearHistory() {
        try? engine?.store.deleteREPLCells(sessionID: sessionID)
        cells.removeAll()
        rowKeepers.removeAll()
        console.clearEntries()
        console.setHistory([])
    }

    private func addCellToNotebook(_ cell: LumaCore.REPLCell) {
        guard let engine else { return }
        let processName = engine.sessions.first { $0.id == sessionID }?.processName ?? ""

        let details: String
        var styled: LumaCore.StyledText? = nil
        var binary: Data? = nil
        var jsValue: LumaCore.JSInspectValue? = nil
        switch cell.result {
        case .text(let s):
            details = s
        case .styled(let s):
            details = s.plainText
            styled = s
        case .js(let v):
            details = ""
            jsValue = v
        case .binary(let data, let meta):
            details = meta?.typedArray ?? ""
            binary = data
        }

        var entry = LumaCore.NotebookEntry(
            title: cell.code,
            details: details,
            styledDetails: styled,
            binaryData: binary,
            sessionID: sessionID,
            processName: processName
        )
        if let jsValue {
            entry.jsValue = jsValue
        }
        engine.addNotebookEntry(entry)
    }

    private func format(result: LumaCore.REPLCell.Result) -> String {
        switch result {
        case .text(let s):
            return s
        case .styled(let s):
            return s.plainText
        case .js(let value):
            return value.prettyDescription()
        case .binary(let data, let meta):
            let kind = meta?.typedArray ?? "binary"
            let header = "<\(kind) \(data.count) bytes>\n"
            return header + Self.formatHexdumpPreview(data: data, maxLines: 4)
        }
    }

    private static func formatHexdumpPreview(data: Data, maxLines: Int) -> String {
        if data.isEmpty {
            return "<no data>"
        }
        let bytes = [UInt8](data)
        let total = bytes.count
        let cap = min(total, maxLines * 16)
        var out = ""
        var i = 0
        while i < cap {
            out += String(format: "0x%016llx  ", UInt64(i))
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
            out += hexPart + "  |" + asciiPart + "|\n"
            i += 16
        }
        if total > cap {
            out += "\u{2026} (total \(total) bytes)"
        }
        return out
    }

    private static func makeEmptyState() -> Box {
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

        let image = Gtk.Image(iconName: "utilities-terminal-symbolic")
        image.pixelSize = 40
        image.halign = .center
        titleGroup.append(child: image)

        let titleLabel = Label(str: "Read-Eval-Print Loop")
        titleLabel.add(cssClass: "title-2")
        titleLabel.halign = .center
        titleGroup.append(child: titleLabel)

        let subtitleLabel = Label(str: "Evaluate JavaScript in the target process,\nor run radare2 commands for disassembly and analysis.")
        subtitleLabel.add(cssClass: "dim-label")
        subtitleLabel.wrap = true
        subtitleLabel.justify = .center
        subtitleLabel.halign = .center
        subtitleLabel.setSizeRequest(width: 360, height: -1)
        titleGroup.append(child: subtitleLabel)

        stack.append(child: titleGroup)

        let tips = Box(orientation: .vertical, spacing: 8)
        tips.halign = .center

        for text in [
            "Type an expression and press Return to evaluate it.",
            "Click the prompt \u{2014} or type :js / :r2 \u{2014} to switch between JavaScript and radare2.",
            "In JavaScript, try Process.mainModule or Process.enumerateModules().",
            "In r2 mode, the seek starts at the main module \u{2014} try x for a hexdump, or afl to list functions.",
            "Step through previous expressions with \u{2191} and \u{2193}.",
        ] {
            tips.append(child: makeTipRow(text: text))
        }

        stack.append(child: tips)

        outer.append(child: stack)
        return outer
    }

    private static func makeTipRow(text: String) -> Box {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.halign = .start

        let bullet = Label(str: "\u{2022}")
        bullet.valign = .start
        bullet.add(cssClass: "dim-label")
        row.append(child: bullet)

        let bodyLabel = Label(str: text)
        bodyLabel.halign = .start
        bodyLabel.wrap = true
        bodyLabel.xalign = 0
        row.append(child: bodyLabel)

        return row
    }
}
