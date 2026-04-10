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
    private let filterBar: Box
    private let sourceFilterButton: MenuButton
    private let processFilterButton: MenuButton
    private let searchEntry: Entry
    private let pauseButton: ToggleButton
    private let clearButton: Button
    private let liveIndicator: Label
    private let scroll: ScrolledWindow
    private let listOverlay: Overlay
    private let eventListBox: Box
    private let emptyStateLabel: Label
    private let pendingPillButton: Button
    private let dateFormatter: DateFormatter

    var onNavigateToHook: ((UUID, UUID, UUID) -> Void)?
    var onCollapsedChanged: ((Bool) -> Void)?

    var collapsed: Bool { isCollapsed }

    private var isCollapsed: Bool = true
    private var isPaused: Bool = false
    private var pendingNewEvents: Int = 0
    private var lastSeenTotal: Int = 0
    private let collapsedHeightRequest: Int = 36
    private let expandedHeightRequest: Int = 320

    private var displayedEvents: [RuntimeEvent] = []
    private var filteredEvents: [RuntimeEvent] = []

    private var enabledSources: Set<EventSourceFilter> = Set(EventSourceFilter.allCases)
    private var selectedProcessName: String?
    private var searchText: String = ""
    private var isAutoScrolling: Bool = false

    init() {
        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "event-stream-pane")
        widget.setSizeRequest(width: -1, height: 36)

        let bar = Box(orientation: .horizontal, spacing: 8)
        bar.marginStart = 4
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

        filterBar = Box(orientation: .horizontal, spacing: 6)
        filterBar.marginStart = 12
        filterBar.marginEnd = 12
        filterBar.marginTop = 2
        filterBar.marginBottom = 4
        filterBar.visible = false
        widget.append(child: filterBar)

        sourceFilterButton = MenuButton()
        sourceFilterButton.label = "All Sources"
        sourceFilterButton.add(cssClass: "flat")
        filterBar.append(child: sourceFilterButton)

        processFilterButton = MenuButton()
        processFilterButton.label = "All Processes"
        processFilterButton.add(cssClass: "flat")
        filterBar.append(child: processFilterButton)

        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        filterBar.append(child: spacer)

        searchEntry = Entry()
        searchEntry.placeholderText = "Search\u{2026}"
        searchEntry.setSizeRequest(width: 200, height: -1)
        filterBar.append(child: searchEntry)

        liveIndicator = Label(str: "● Live")
        liveIndicator.add(cssClass: "dim-label")
        liveIndicator.add(cssClass: "caption")
        filterBar.append(child: liveIndicator)

        pauseButton = ToggleButton()
        pauseButton.label = "Pause"
        pauseButton.add(cssClass: "flat")
        filterBar.append(child: pauseButton)

        clearButton = Button(label: "Clear")
        clearButton.add(cssClass: "flat")
        filterBar.append(child: clearButton)

        eventListBox = Box(orientation: .vertical, spacing: 0)
        eventListBox.hexpand = true
        eventListBox.vexpand = true

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: eventListBox)

        emptyStateLabel = Label(str: "Waiting for events\u{2026}")
        emptyStateLabel.add(cssClass: "dim-label")
        emptyStateLabel.halign = .center
        emptyStateLabel.valign = .center
        emptyStateLabel.canTarget = false

        pendingPillButton = Button(label: "0 new events while paused")
        pendingPillButton.add(cssClass: "luma-event-pending-pill")
        pendingPillButton.halign = .center
        pendingPillButton.valign = .end
        pendingPillButton.marginBottom = 12
        pendingPillButton.visible = false

        listOverlay = Overlay()
        listOverlay.hexpand = true
        listOverlay.vexpand = true
        listOverlay.set(child: WidgetRef(scroll))
        listOverlay.addOverlay(widget: emptyStateLabel)
        listOverlay.addOverlay(widget: pendingPillButton)
        listOverlay.visible = false
        widget.append(child: listOverlay)

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        toggleButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.toggleCollapsed()
            }
        }

        searchEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.searchText = self.searchEntry.text ?? ""
                self.rebuildFiltered()
            }
        }

        pauseButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPaused = self.pauseButton.active
                self.pauseButton.label = self.isPaused ? "Resume" : "Pause"
                if !self.isPaused {
                    self.syncSnapshot()
                    self.pendingNewEvents = 0
                    self.scrollToBottomSoon()
                }
                self.updateLiveIndicator()
                self.updatePendingPill()
            }
        }

        clearButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearEvents()
            }
        }

        if let vadj = scroll.vadjustment {
            vadj.onValueChanged { [weak self] adj in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.isAutoScrolling { return }
                    let atBottom = (adj.upper - (adj.value + adj.pageSize)) < 20.0
                    if atBottom {
                        if self.isPaused {
                            self.isPaused = false
                            self.pauseButton.active = false
                            self.pauseButton.label = "Pause"
                            self.syncSnapshot()
                            self.updateLiveIndicator()
                        }
                    } else if !self.isPaused {
                        self.isPaused = true
                        self.pauseButton.active = true
                        self.pauseButton.label = "Resume"
                        self.updateLiveIndicator()
                        self.updatePendingPill()
                    }
                }
            }
        }

        rebuildSourceFilterMenu()
        rebuildProcessFilterMenu()
    }

    func attach(engine: Engine) {
        self.engine = engine
        lastSeenTotal = engine.eventLog.totalReceived

        engine.eventLog.onEventsAppended = { [weak self] newEvents in
            self?.handleEventsAppended(newEvents)
        }
        engine.eventLog.onEventsCleared = { [weak self] in
            self?.clearEvents()
        }

        syncSnapshot()
    }

    private func toggleCollapsed() {
        isCollapsed.toggle()
        applyCollapsedState()
        if !isCollapsed {
            pendingNewEvents = 0
            syncSnapshot()
        }
        updateBar()
        updatePendingPill()
        onCollapsedChanged?(isCollapsed)
    }

    private func applyCollapsedState() {
        widget.setSizeRequest(
            width: -1,
            height: isCollapsed ? collapsedHeightRequest : -1
        )
        listOverlay.visible = !isCollapsed
        filterBar.visible = !isCollapsed
    }

    private func handleEventsAppended(_ newEvents: ArraySlice<RuntimeEvent>) {
        guard let engine else { return }
        let delta = newEvents.count

        if isCollapsed || isPaused {
            pendingNewEvents += delta
            lastSeenTotal = engine.eventLog.totalReceived
            if isCollapsed { updateBar() } else { updatePendingPill() }
            return
        }

        lastSeenTotal = engine.eventLog.totalReceived
        displayedEvents.append(contentsOf: newEvents)

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSearch = !trimmed.isEmpty
        var appended = false

        for event in newEvents {
            let kind = EventSourceFilter.from(event.source)
            guard enabledSources.contains(kind) else { continue }
            if let name = selectedProcessName, processName(for: event) != name { continue }
            if hasSearch {
                let haystack = "\(searchBlob(for: event)) \(contextString(for: event))"
                if haystack.range(of: trimmed, options: .caseInsensitive) == nil { continue }
            }
            filteredEvents.append(event)
            let prev = filteredEvents.dropLast().last?.timestamp
            eventListBox.append(child: makeRow(for: event, previousTimestamp: prev))
            appended = true
        }

        if appended {
            emptyStateLabel.visible = false
            scrollToBottomSoon()
        }
        updateBar()
        updatePendingPill()
    }

    private func syncSnapshot() {
        guard let engine else {
            displayedEvents = []
            rebuildFiltered()
            return
        }
        displayedEvents = engine.eventLog.events
        lastSeenTotal = engine.eventLog.totalReceived
        pendingNewEvents = 0
        rebuildProcessFilterMenu()
        rebuildFiltered()
        updatePendingPill()
        scrollToBottomSoon()
    }

    private func clearEvents() {
        engine?.eventLog.clear()
        displayedEvents.removeAll()
        filteredEvents.removeAll()
        pendingNewEvents = 0
        lastSeenTotal = engine?.eventLog.totalReceived ?? 0
        refreshRows()
        updateBar()
        updatePendingPill()
    }

    private func rebuildFiltered() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSearch = !trimmed.isEmpty

        filteredEvents = displayedEvents.filter { evt in
            let kind = EventSourceFilter.from(evt.source)
            guard enabledSources.contains(kind) else { return false }
            if let name = selectedProcessName {
                guard processName(for: evt) == name else { return false }
            }
            if hasSearch {
                let haystack = "\(searchBlob(for: evt)) \(contextString(for: evt))"
                if haystack.range(of: trimmed, options: .caseInsensitive) == nil {
                    return false
                }
            }
            return true
        }

        refreshRows()
        updateBar()
    }

    private var jsValueKeepers: [JSInspectValueWidget] = []

    private func refreshRows() {
        clearChildren(of: eventListBox)
        jsValueKeepers.removeAll()
        var prevTimestamp: Date? = nil
        for event in filteredEvents {
            eventListBox.append(child: makeRow(for: event, previousTimestamp: prevTimestamp))
            prevTimestamp = event.timestamp
        }
        emptyStateLabel.visible = filteredEvents.isEmpty
        if filteredEvents.isEmpty {
            if displayedEvents.isEmpty {
                emptyStateLabel.setText(str: "Waiting for events\u{2026}")
            } else {
                emptyStateLabel.setText(str: "No events match the current filters.")
            }
        }
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
            let count = filteredEvents.count
            let total = displayedEvents.count
            if count == total {
                statusLabel.setText(str: count == 0 ? "" : "\(count) events")
            } else {
                statusLabel.setText(str: "\(count) of \(total)")
            }
        }
        updateLiveIndicator()
    }

    private func updateLiveIndicator() {
        liveIndicator.setText(str: isPaused ? "⏸ Paused" : "● Live")
    }

    private func updatePendingPill() {
        let show = !isCollapsed && isPaused && pendingNewEvents > 0
        pendingPillButton.visible = show
        if show {
            let plural = pendingNewEvents == 1 ? "" : "s"
            pendingPillButton.label = "Show \(pendingNewEvents) new event\(plural)"
        }
        pendingPillButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPaused = false
                self.pauseButton.active = false
                self.pauseButton.label = "Pause"
                self.syncSnapshot()
                self.updateLiveIndicator()
            }
        }
    }

    private func scrollToBottomSoon() {
        Task { @MainActor in
            guard let adj = scroll.vadjustment else { return }
            let target = adj.upper - adj.pageSize
            if target > adj.value {
                isAutoScrolling = true
                adj.value = target
                isAutoScrolling = false
            }
        }
    }

    // MARK: - Filter menus

    private func rebuildSourceFilterMenu() {
        let popover = Popover()
        popover.autohide = true
        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 8
        box.marginEnd = 8
        box.marginTop = 8
        box.marginBottom = 8

        for filter in EventSourceFilter.allCases {
            let check = CheckButton(label: filter.menuTitle)
            check.active = enabledSources.contains(filter)
            check.onToggled { [weak self, weak check] _ in
                MainActor.assumeIsolated {
                    guard let self, let check else { return }
                    if check.active {
                        self.enabledSources.insert(filter)
                    } else {
                        self.enabledSources.remove(filter)
                    }
                    self.updateSourceFilterButtonLabel()
                    self.rebuildFiltered()
                }
            }
            box.append(child: check)
        }

        popover.set(child: box)
        sourceFilterButton.set(popover: popover)
        updateSourceFilterButtonLabel()
    }

    private func updateSourceFilterButtonLabel() {
        if enabledSources.count == EventSourceFilter.allCases.count {
            sourceFilterButton.label = "All Sources"
        } else if enabledSources.isEmpty {
            sourceFilterButton.label = "No Sources"
        } else if enabledSources.count == 1, let only = enabledSources.first {
            sourceFilterButton.label = only.menuTitle
        } else {
            sourceFilterButton.label = "\(enabledSources.count) Sources"
        }
    }

    private func rebuildProcessFilterMenu() {
        let popover = Popover()
        popover.autohide = true
        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 8
        box.marginEnd = 8
        box.marginTop = 8
        box.marginBottom = 8

        let allButton = Button(label: "All Processes")
        allButton.add(cssClass: "flat")
        allButton.onClicked { [weak self, popover] _ in
            MainActor.assumeIsolated {
                self?.selectedProcessName = nil
                self?.processFilterButton.label = "All Processes"
                self?.rebuildFiltered()
                popover.popdown()
            }
        }
        box.append(child: allButton)

        let names = Set(displayedEvents.map { processName(for: $0) }).filter { !$0.isEmpty }.sorted()
        if !names.isEmpty {
            box.append(child: Separator(orientation: .horizontal))
        }
        for name in names {
            let item = Button(label: name)
            item.add(cssClass: "flat")
            item.onClicked { [weak self, popover] _ in
                MainActor.assumeIsolated {
                    self?.selectedProcessName = name
                    self?.processFilterButton.label = name
                    self?.rebuildFiltered()
                    popover.popdown()
                }
            }
            box.append(child: item)
        }

        popover.set(child: box)
        processFilterButton.set(popover: popover)

        if let sel = selectedProcessName, !names.contains(sel) {
            selectedProcessName = nil
            processFilterButton.label = "All Processes"
        }
    }

    // MARK: - Row formatting

    private func makeRow(for event: RuntimeEvent, previousTimestamp: Date?) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.marginStart = 12
        row.marginEnd = 12
        row.marginTop = 2
        row.marginBottom = 2

        let delta = Label(str: deltaText(from: previousTimestamp, to: event.timestamp) ?? " ")
        delta.add(cssClass: "dim-label")
        delta.add(cssClass: "monospace")
        delta.add(cssClass: "luma-event-delta")
        delta.halign = .start
        delta.setSizeRequest(width: 64, height: -1)
        row.append(child: delta)

        let badge = makeSourceBadge(for: event)
        row.append(child: badge)

        if let tracerWidget = makeTracerPayload(for: event) {
            row.append(child: tracerWidget)
        } else if let errorWidget = makeJSErrorPayload(for: event) {
            row.append(child: errorWidget)
        } else if let consoleWidget = makeConsolePayload(for: event) {
            row.append(child: consoleWidget)
        } else if let expandable = makeExpandablePayload(for: event) {
            row.append(child: expandable)
        } else {
            let payload = Label(str: payloadString(for: event))
            payload.halign = .start
            payload.hexpand = true
            payload.lines = 3
            payload.wrap = true
            payload.ellipsize = .end
            payload.add(cssClass: "monospace")
            row.append(child: payload)
        }

        attachRowContextMenu(to: row, event: event)
        return row
    }

    private func deltaText(from previous: Date?, to current: Date) -> String? {
        guard let previous else { return nil }
        let dt = current.timeIntervalSince(previous)
        guard dt > 0 else { return nil }
        let ms = dt * 1000.0
        if ms < 1.0 { return nil }
        if ms < 1000.0 {
            return String(format: "+%.0f ms", ms)
        } else if dt < 60.0 {
            return String(format: "+%.2f s", dt)
        } else {
            return String(format: "+%.0f s", dt)
        }
    }

    private func makeSourceBadge(for event: RuntimeEvent) -> Widget {
        let text = shortSourceName(for: event)
        let label = Label(str: text)
        label.add(cssClass: "luma-event-badge")
        label.add(cssClass: "luma-event-source-\(colorIndex(for: text))")
        label.halign = .start
        label.valign = .center
        return label
    }

    private func colorIndex(for key: String) -> Int {
        var hash: UInt32 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt32(byte)
        }
        return Int(hash % 8)
    }

    private func shortSourceName(for event: RuntimeEvent) -> String {
        switch event.source {
        case .processOutput(let fd):
            switch fd {
            case 1: return "stdout"
            case 2: return "stderr"
            default: return "fd\(fd)"
            }
        case .script: return "script"
        case .console: return "console"
        case .repl: return "repl"
        case .instrument:
            if let instance = instrument(for: event),
                let descriptor = engine?.descriptor(for: instance)
            {
                return descriptor.displayName
            }
            return "Instrument"
        }
    }

    private func instrument(for event: RuntimeEvent) -> LumaCore.InstrumentInstance? {
        guard case .instrument(let id, _) = event.source,
            let sid = event.sessionID
        else { return nil }
        return engine?.instrument(id: id, sessionID: sid)
    }

    private func makeJSErrorPayload(for event: RuntimeEvent) -> Widget? {
        guard case .jsError(let error) = event.payload else { return nil }
        let column = Box(orientation: .vertical, spacing: 2)
        column.hexpand = true

        let textLabel = Label(str: error.text)
        textLabel.add(cssClass: "monospace")
        textLabel.add(cssClass: "luma-event-jserror")
        textLabel.halign = .start
        textLabel.hexpand = true
        textLabel.wrap = true
        textLabel.selectable = true
        column.append(child: textLabel)

        if let fileName = error.fileName, let line = error.lineNumber {
            let colSuffix = error.columnNumber.map { ":\($0)" } ?? ""
            let loc = Label(str: "\(fileName):\(line)\(colSuffix)")
            loc.add(cssClass: "dim-label")
            loc.add(cssClass: "caption")
            loc.halign = .start
            loc.marginStart = 12
            column.append(child: loc)
        }

        if let stack = error.stack, !stack.isEmpty {
            let stackLabel = Label(str: stack)
            stackLabel.add(cssClass: "monospace")
            stackLabel.add(cssClass: "dim-label")
            stackLabel.halign = .start
            stackLabel.marginStart = 12
            stackLabel.wrap = true
            stackLabel.selectable = true
            column.append(child: stackLabel)
        }

        return column
    }

    private func makeConsolePayload(for event: RuntimeEvent) -> Widget? {
        guard case .consoleMessage(let message) = event.payload else { return nil }
        let row = Box(orientation: .horizontal, spacing: 8)
        row.hexpand = true

        let level = message.level
        let badge = Label(str: levelBadgeText(level).uppercased())
        badge.add(cssClass: "luma-event-badge")
        badge.add(cssClass: "luma-event-level-\(levelClass(level))")
        badge.valign = .start
        row.append(child: badge)

        let allStrings = message.values.compactMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        }

        if !message.values.isEmpty && allStrings.count == message.values.count {
            let payload = Label(str: allStrings.joined(separator: " "))
            payload.add(cssClass: "monospace")
            payload.halign = .start
            payload.hexpand = true
            payload.lines = 3
            payload.wrap = true
            payload.ellipsize = .end
            payload.selectable = true
            row.append(child: payload)
        } else if let engine, let sessionID = event.sessionID {
            let column = Box(orientation: .vertical, spacing: 4)
            column.hexpand = true
            for value in message.values {
                let wrapper = JSInspectValueWidget.make(value: value, engine: engine, sessionID: sessionID)
                jsValueKeepers.append(wrapper)
                wrapper.widget.halign = .start
                wrapper.widget.hexpand = true
                column.append(child: wrapper.widget)
            }
            row.append(child: column)
        } else {
            let payload = Label(str: message.values.map { $0.inlineDescription }.joined(separator: " "))
            payload.add(cssClass: "monospace")
            payload.halign = .start
            payload.hexpand = true
            payload.lines = 3
            payload.wrap = true
            payload.ellipsize = .end
            payload.selectable = true
            row.append(child: payload)
        }

        return row
    }

    private func levelBadgeText(_ level: ConsoleLevel) -> String {
        switch level {
        case .info: return "info"
        case .debug: return "debug"
        case .warning: return "warn"
        case .error: return "error"
        }
    }

    private func levelClass(_ level: ConsoleLevel) -> String {
        switch level {
        case .info: return "info"
        case .debug: return "debug"
        case .warning: return "warn"
        case .error: return "error"
        }
    }

    private func makeExpandablePayload(for event: RuntimeEvent) -> Widget? {
        guard case .jsValue(let value) = event.payload,
            let engine,
            let sessionID = event.sessionID,
            isStructured(value)
        else { return nil }

        let expander = Expander(label: value.inlineDescription)
        expander.hexpand = true
        let wrapper = JSInspectValueWidget.make(value: value, engine: engine, sessionID: sessionID)
        jsValueKeepers.append(wrapper)
        let body = wrapper.widget
        body.marginStart = 12
        body.marginTop = 4
        body.marginBottom = 4
        expander.set(child: body)
        return expander
    }

    private func isStructured(_ value: JSInspectValue) -> Bool {
        switch value {
        case .object, .array, .map, .set, .error:
            return true
        default:
            return false
        }
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
        let anchor = widget
        rightClick.onPressed { [weak self, column, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                var tx: Double = 0
                var ty: Double = 0
                column.translateCoordinates(
                    destWidget: anchor,
                    srcX: x,
                    srcY: y,
                    destX: &tx,
                    destY: &ty
                )
                self?.presentHookContextMenu(
                    anchor: anchor,
                    x: tx,
                    y: ty,
                    sessionID: sessionID,
                    instrumentID: instrumentID,
                    hookID: hookID,
                    event: event
                )
            }
        }
        column.install(controller: rightClick)

        if case .array(_, let elems) = parsed.message,
            elems.count == 1,
            case .string(let s) = elems[0]
        {
            let payload = Label(str: s)
            payload.halign = .start
            payload.hexpand = true
            payload.lines = 3
            payload.wrap = true
            payload.ellipsize = .end
            payload.add(cssClass: "monospace")
            column.append(child: payload)
        } else {
            let expander = Expander(label: parsed.message.inlineDescription)
            expander.hexpand = true
            let wrapper = JSInspectValueWidget.make(value: parsed.message, engine: engine!, sessionID: sessionID)
            jsValueKeepers.append(wrapper)
            let body = wrapper.widget
            body.marginStart = 12
            body.marginTop = 4
            body.marginBottom = 4
            expander.set(child: body)
            column.append(child: expander)
        }

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

    private func attachRowContextMenu(to row: Box, event: RuntimeEvent) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        let anchor = widget
        gesture.onPressed { [weak self, row, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                var translatedX: Double = 0
                var translatedY: Double = 0
                row.translateCoordinates(
                    destWidget: anchor,
                    srcX: x,
                    srcY: y,
                    destX: &translatedX,
                    destY: &translatedY
                )
                self.presentRowContextMenu(at: anchor, x: translatedX, y: translatedY, event: event)
            }
        }
        row.install(controller: gesture)
    }

    private func presentRowContextMenu(at anchor: Widget, x: Double, y: Double, event: RuntimeEvent) {
        ContextMenu.present([
            [.init("Pin to Notebook") { [weak self] in self?.pinToNotebook(event) }],
        ], at: anchor, x: x, y: y)
    }

    private func pinToNotebook(_ event: RuntimeEvent) {
        guard let engine else { return }
        let process = engine.session(id: event.sessionID ?? UUID())?.processName ?? ""
        let title: String
        switch event.source {
        case .processOutput(let fd):
            let channel: String
            switch fd {
            case 1: channel = "stdout"
            case 2: channel = "stderr"
            default: channel = "fd\(fd)"
            }
            title = "Output on \(channel)"
        case .script: title = "Script Runtime (\(process))"
        case .console: title = "Console (\(process))"
        case .repl: title = "REPL (\(process))"
        case .instrument(_, let name): title = "Instrument \(name)"
        }

        var jsValue: JSInspectValue? = nil
        if case .jsValue(let v) = event.payload {
            jsValue = v
        }

        var entry = LumaCore.NotebookEntry(
            title: title,
            details: payloadString(for: event),
            sessionID: event.sessionID ?? UUID(),
            processName: process
        )
        if let jsValue {
            entry.jsValue = jsValue
        }
        engine.addNotebookEntry(entry)
    }

    private func presentHookContextMenu(
        anchor: Widget,
        x: Double,
        y: Double,
        sessionID: UUID,
        instrumentID: UUID,
        hookID: UUID,
        event: RuntimeEvent
    ) {
        ContextMenu.present([
            [
                .init("Pin to Notebook") { [weak self] in self?.pinToNotebook(event) },
                .init("Go to Hook") { [weak self] in self?.onNavigateToHook?(sessionID, instrumentID, hookID) },
            ],
        ], at: anchor, x: x, y: y)
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
        var lineLabels: [Label] = []
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
            lineLabels.append(line)
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
                for (idx, symbol) in symbols.enumerated() {
                    guard idx < lineLabels.count else { break }
                    let fallback = node.anchor(for: addresses[idx]).displayString
                    lineLabels[idx].setText(str: symbolLabel(for: symbol, fallback: fallback))
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

    private func processName(for event: RuntimeEvent) -> String {
        engine?.session(id: event.sessionID ?? UUID())?.processName ?? ""
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
        case .instrument:
            let name: String
            if let instance = instrument(for: event),
                let descriptor = engine?.descriptor(for: instance)
            {
                name = descriptor.displayName
            } else {
                name = "Instrument"
            }
            return "\(name)\(processSuffix)"
        }
    }

    private func searchBlob(for event: RuntimeEvent) -> String {
        switch event.payload {
        case .consoleMessage(let message):
            return message.values.map { $0.prettyDescription() }.joined(separator: " ")
        case .jsError(let error):
            var parts = [error.text]
            if let stack = error.stack { parts.append(stack) }
            if let fileName = error.fileName { parts.append(fileName) }
            return parts.joined(separator: " ")
        case .jsValue(let value):
            return value.prettyDescription()
        case .raw(let message, _):
            return String(describing: message)
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

private enum EventSourceFilter: String, CaseIterable, Hashable {
    case processOutput
    case script
    case console
    case repl
    case instrument

    var menuTitle: String {
        switch self {
        case .processOutput: return "Process Output"
        case .script: return "Script Runtime"
        case .console: return "Console"
        case .repl: return "REPL"
        case .instrument: return "Instruments"
        }
    }

    static func from(_ source: LumaCore.RuntimeEvent.Source) -> EventSourceFilter {
        switch source {
        case .processOutput: return .processOutput
        case .script: return .script
        case .console: return .console
        case .repl: return .repl
        case .instrument: return .instrument
        }
    }
}
