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

        let payload = Label(str: payloadString(for: event))
        payload.halign = .start
        payload.hexpand = true
        payload.ellipsize = .end
        payload.add(cssClass: "monospace")
        row.append(child: payload)

        return row
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
            return String(describing: value)
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
