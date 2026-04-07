import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class EventStreamPane {
    let widget: Box

    private weak var engine: Engine?
    private let toggleButton: Button
    private let statusLabel: Label
    private let scroll: ScrolledWindow
    private let eventListBox: Box
    private let dateFormatter: DateFormatter

    var onNavigateToHook: ((UUID, UUID, UUID) -> Void)?

    private var isCollapsed: Bool = true
    private var pendingNewEvents: Int = 0
    private var lastSeenTotal: Int = 0
    private let collapsedHeightRequest: Int = 36
    private let expandedHeightRequest: Int = 240

    init() {
        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "event-stream-pane")
        widget.setSizeRequest(width: -1, height: 36)

        let bar = Box(orientation: .horizontal, spacing: 8)
        bar.marginStart = 12
        bar.marginEnd = 12
        bar.marginTop = 4
        bar.marginBottom = 4
        bar.setSizeRequest(width: -1, height: 28)
        widget.append(child: bar)

        toggleButton = Button()
        toggleButton.label = "▲  Show Event Stream"
        toggleButton.hasFrame = false
        bar.append(child: toggleButton)

        statusLabel = Label(str: "")
        statusLabel.halign = .start
        statusLabel.hexpand = true
        bar.append(child: statusLabel)

        eventListBox = Box(orientation: .vertical, spacing: 0)
        eventListBox.hexpand = true

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: eventListBox)
        scroll.visible = false
        widget.append(child: scroll)

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        toggleButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.toggleCollapsed()
            }
        }
    }

    func attach(engine: Engine) {
        self.engine = engine
        lastSeenTotal = engine.eventLog.totalReceived
        observe()
        refresh()
    }

    private func toggleCollapsed() {
        isCollapsed.toggle()
        applyCollapsedState()
        if !isCollapsed {
            pendingNewEvents = 0
            if let engine {
                lastSeenTotal = engine.eventLog.totalReceived
            }
            refresh()
        }
        updateBar()
    }

    private func applyCollapsedState() {
        widget.setSizeRequest(
            width: -1,
            height: isCollapsed ? collapsedHeightRequest : expandedHeightRequest
        )
        scroll.visible = !isCollapsed
    }

    private func observe() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.eventLog.totalReceived
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleLogChanged()
                self.observe()
            }
        }
    }

    private func handleLogChanged() {
        guard let engine else { return }
        let total = engine.eventLog.totalReceived
        if isCollapsed {
            pendingNewEvents += max(0, total - lastSeenTotal)
            lastSeenTotal = total
            updateBar()
        } else {
            lastSeenTotal = total
            refresh()
        }
    }

    private func refresh() {
        guard let engine else { return }
        clearChildren(of: eventListBox)
        for event in engine.eventLog.events {
            eventListBox.append(child: makeRow(for: event))
        }
        updateBar()
    }

    private func updateBar() {
        if isCollapsed {
            if pendingNewEvents > 0 {
                toggleButton.label = "▲  Show Event Stream (\(pendingNewEvents) new)"
                widget.add(cssClass: "has-pending-events")
            } else {
                toggleButton.label = "▲  Show Event Stream"
                widget.remove(cssClass: "has-pending-events")
            }
            statusLabel.setText(str: "")
        } else {
            toggleButton.label = "▼  Hide Event Stream"
            widget.remove(cssClass: "has-pending-events")
            let count = engine?.eventLog.events.count ?? 0
            statusLabel.setText(str: count == 0 ? "no events yet" : "\(count) events")
        }
    }

    // MARK: - Row formatting

    private func makeRow(for event: RuntimeEvent) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.marginStart = 12
        row.marginEnd = 12
        row.marginTop = 2
        row.marginBottom = 2

        let time = Label(str: dateFormatter.string(from: event.timestamp))
        time.add(cssClass: "dim-label")
        time.add(cssClass: "monospace")
        time.halign = .start
        row.append(child: time)

        let context = Label(str: contextString(for: event))
        context.add(cssClass: "dim-label")
        context.halign = .start
        context.setSizeRequest(width: 160, height: -1)
        row.append(child: context)

        if let tracerWidget = makeTracerPayload(for: event) {
            row.append(child: tracerWidget)
        } else {
            let payload = Label(str: payloadString(for: event))
            payload.halign = .start
            payload.hexpand = true
            payload.ellipsize = .end
            payload.add(cssClass: "monospace")
            row.append(child: payload)
        }

        return row
    }

    private func makeTracerPayload(for event: RuntimeEvent) -> Widget? {
        guard case .instrument(let instrumentID, _) = event.source,
            case .jsValue(let v) = event.payload,
            let parsed = Engine.parseTracerEvent(from: v),
            let sessionID = event.sessionID,
            let node = engine?.node(forSessionID: sessionID)
        else { return nil }

        let hookID = parsed.id

        let column = Box(orientation: .horizontal, spacing: 8)
        column.hexpand = true

        let rightClick = GestureClick()
        rightClick.set(button: 3)
        rightClick.onPressed { [weak self] _, _, _, _ in
            MainActor.assumeIsolated {
                self?.presentHookContextMenu(
                    anchor: column,
                    sessionID: sessionID,
                    instrumentID: instrumentID,
                    hookID: hookID
                )
            }
        }
        column.add(controller: rightClick)

        let messageText: String = {
            if case .array(_, let elems) = parsed.message,
                elems.count == 1,
                case .string(let s) = elems[0]
            {
                return s
            }
            return parsed.message.inlineDescription
        }()

        let payload = Label(str: messageText)
        payload.halign = .start
        payload.hexpand = true
        payload.ellipsize = .end
        payload.add(cssClass: "monospace")
        column.append(child: payload)

        if let backtrace = parsed.backtrace, !backtrace.isEmpty {
            let button = Button(label: "⋯ bt")
            button.hasFrame = false
            button.add(cssClass: "flat")
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.presentBacktrace(button: button, node: node, pointers: backtrace)
                }
            }
            column.append(child: button)
        }

        return column
    }

    private func presentHookContextMenu(
        anchor: Widget,
        sessionID: UUID,
        instrumentID: UUID,
        hookID: UUID
    ) {
        let popover = Popover()
        popover.autohide = true

        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let goButton = Button(label: "Go to Hook")
        goButton.add(cssClass: "flat")
        goButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                popover?.popdown()
                self?.onNavigateToHook?(sessionID, instrumentID, hookID)
            }
        }
        box.append(child: goButton)

        popover.set(child: box)
        popover.set(parent: anchor)
        popover.popup()
    }

    private func presentBacktrace(
        button: Button,
        node: LumaCore.ProcessNode,
        pointers: [JSInspectValue]
    ) {
        let popover = Popover()
        popover.set(parent: WidgetRef(button))
        popover.autohide = true

        let column = Box(orientation: .vertical, spacing: 6)
        column.marginStart = 12
        column.marginEnd = 12
        column.marginTop = 10
        column.marginBottom = 10
        column.setSizeRequest(width: 520, height: 320)

        let header = Box(orientation: .horizontal, spacing: 8)
        let title = Label(str: "Backtrace")
        title.add(cssClass: "heading")
        title.halign = .start
        title.hexpand = true
        header.append(child: title)
        let spinner = Spinner()
        spinner.spinning = true
        header.append(child: spinner)
        column.append(child: header)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        let listBox = Box(orientation: .vertical, spacing: 0)
        scroll.set(child: listBox)
        column.append(child: scroll)

        let addresses = pointers.compactMap { $0.nativePointerAddress }
        for (idx, addr) in addresses.enumerated() {
            let row = Box(orientation: .horizontal, spacing: 8)
            row.marginTop = 3
            row.marginBottom = 3
            let num = Label(str: "#\(idx + 1)")
            num.add(cssClass: "dim-label")
            num.add(cssClass: "monospace")
            row.append(child: num)
            let line = Label(str: node.anchor(for: addr).displayString)
            line.add(cssClass: "monospace")
            line.halign = .start
            line.hexpand = true
            line.selectable = true
            row.append(child: line)
            listBox.append(child: row)
            if idx < addresses.count - 1 {
                listBox.append(child: Separator(orientation: .horizontal))
            }
        }

        popover.set(child: column)
        popover.popup()

        Task { @MainActor in
            defer { spinner.spinning = false }
            do {
                let symbols = try await node.symbolicate(addresses: addresses)
                var idx = 0
                var child = listBox.firstChild
                while let current = child {
                    child = current.nextSibling
                    guard let row = current as? Box else { continue }
                    if idx >= symbols.count { break }
                    let label = symbolLabel(for: symbols[idx], fallback: node.anchor(for: addresses[idx]).displayString)
                    // Row layout is: [num Label][line Label]; pick the second.
                    var inner = row.firstChild
                    var labelCount = 0
                    while let n = inner {
                        if let l = n as? Label {
                            labelCount += 1
                            if labelCount == 2 {
                                l.setText(str: label)
                                break
                            }
                        }
                        inner = n.nextSibling
                    }
                    idx += 1
                }
            } catch {
                // leave anchor strings as-is on failure
            }
        }
    }

    private func symbolLabel(for result: SymbolicateResult, fallback: String) -> String {
        switch result {
        case .failure:
            return fallback
        case .module(let module, let name):
            return "\(module)!\(name)"
        case .file(let module, let name, let file, let line):
            return "\(module)!\(name) — \(file):\(line)"
        case .fileColumn(let module, let name, let file, let line, let col):
            return "\(module)!\(name) — \(file):\(line):\(col)"
        }
    }

    private func contextString(for event: RuntimeEvent) -> String {
        let process = engine?.session(id: event.sessionID ?? UUID())?.processName
        let processSuffix = process.map { " · \($0)" } ?? ""
        switch event.source {
        case .processOutput(let fd):
            let channel: String
            switch fd {
            case 1: channel = "stdout"
            case 2: channel = "stderr"
            default: channel = "fd\(fd)"
            }
            return "\(channel)\(processSuffix)"
        case .script:
            return "script\(processSuffix)"
        case .console:
            return "console\(processSuffix)"
        case .repl:
            return "repl\(processSuffix)"
        case .instrument(_, let name):
            return "\(name)\(processSuffix)"
        }
    }

    private func payloadString(for event: RuntimeEvent) -> String {
        switch event.payload {
        case .consoleMessage(let message):
            return message.values.map { String(describing: $0) }.joined(separator: " ")
        case .jsError(let error):
            return "JSError: \(error.text)"
        case .jsValue(let value):
            return value.inlineDescription
        case .raw(let message, _):
            return String(describing: message)
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
