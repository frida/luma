import Adw
import CGraphene
import CPango
import Foundation
import struct Graphene.PointRef
import Gtk
import LumaCore
import Observation

private func computePoint<Src: WidgetProtocol, Dst: WidgetProtocol>(
    x: Double,
    y: Double,
    from src: Src,
    to dst: Dst
) -> (x: Double, y: Double) {
    var source = graphene_point_t(x: Float(x), y: Float(y))
    var destination = graphene_point_t(x: 0, y: 0)
    _ = withUnsafeMutablePointer(to: &source) { srcPtr in
        withUnsafeMutablePointer(to: &destination) { dstPtr in
            src.computePoint(target: dst, point: PointRef(srcPtr), outPoint: PointRef(dstPtr))
        }
    }
    return (Double(destination.x), Double(destination.y))
}

@MainActor
final class EventStreamPane {
    let widget: Box

    private weak var engine: Engine?
    private let toggleButton: Button
    private let collapseCaretButton: Button
    private let collapsedBar: Box
    private let statusLabel: Label
    private let filterBar: Box
    private let headerSeparator: Separator
    private let sourceFilterButton: MenuButton
    private let processFilterButton: MenuButton
    private let searchEntry: Entry
    private let pauseButton: ToggleButton
    private let overflowMenuButton: MenuButton
    private let clearEventsButton: Button
    private let liveIndicatorBox: Box
    private let liveDot: Label
    private let liveLabel: Label
    private let scroll: ScrolledWindow
    private let scroller: BottomScroller
    private let listOverlay: Overlay
    private let eventListBox: Box
    private let emptyStateBox: Box
    private let emptyStateTitle: Label
    private let emptyStateSubtitle: Label
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

    init() {
        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "event-stream-pane")
        widget.setSizeRequest(width: -1, height: 36)

        collapsedBar = Box(orientation: .horizontal, spacing: 8)
        collapsedBar.marginStart = 4
        collapsedBar.marginEnd = 12
        collapsedBar.marginTop = 4
        collapsedBar.marginBottom = 4
        collapsedBar.setSizeRequest(width: -1, height: 28)
        widget.append(child: collapsedBar)

        toggleButton = Button()
        toggleButton.label = "▲  Show Event Stream"
        toggleButton.hasFrame = false
        toggleButton.add(cssClass: "luma-event-stream-toggle")
        collapsedBar.append(child: toggleButton)

        statusLabel = Label(str: "")
        statusLabel.halign = .start
        statusLabel.hexpand = true
        collapsedBar.append(child: statusLabel)

        filterBar = Box(orientation: .horizontal, spacing: 6)
        filterBar.marginStart = 12
        filterBar.marginEnd = 12
        filterBar.marginTop = 4
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

        liveIndicatorBox = Box(orientation: .horizontal, spacing: 6)
        liveIndicatorBox.valign = .center
        liveDot = Label(str: "●")
        liveDot.add(cssClass: "luma-live-dot")
        liveDot.valign = .center
        liveLabel = Label(str: "Live")
        liveLabel.add(cssClass: "dim-label")
        liveLabel.add(cssClass: "caption")
        liveIndicatorBox.append(child: liveDot)
        liveIndicatorBox.append(child: liveLabel)
        filterBar.append(child: liveIndicatorBox)

        pauseButton = ToggleButton()
        pauseButton.label = "Pause"
        pauseButton.add(cssClass: "flat")
        filterBar.append(child: pauseButton)

        clearEventsButton = Button(label: "Clear Events")
        clearEventsButton.add(cssClass: "flat")
        clearEventsButton.add(cssClass: "luma-menu-destructive")

        let overflowBox = Box(orientation: .vertical, spacing: 2)
        overflowBox.marginStart = 6
        overflowBox.marginEnd = 6
        overflowBox.marginTop = 6
        overflowBox.marginBottom = 6
        overflowBox.append(child: clearEventsButton)

        let overflowPopover = Popover()
        overflowPopover.autohide = true
        overflowPopover.set(child: overflowBox)

        overflowMenuButton = MenuButton()
        overflowMenuButton.set(iconName: "view-more-symbolic")
        overflowMenuButton.hasFrame = false
        overflowMenuButton.add(cssClass: "flat")
        overflowMenuButton.tooltipText = "More actions"
        overflowMenuButton.set(popover: overflowPopover)
        filterBar.append(child: overflowMenuButton)

        collapseCaretButton = Button()
        collapseCaretButton.set(iconName: "go-down-symbolic")
        collapseCaretButton.add(cssClass: "flat")
        collapseCaretButton.tooltipText = "Hide the event stream"
        filterBar.append(child: collapseCaretButton)

        eventListBox = Box(orientation: .vertical, spacing: 0)
        eventListBox.hexpand = true
        eventListBox.valign = .end

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: eventListBox)
        scroller = BottomScroller(scroll, threshold: 20.0)

        emptyStateBox = Box(orientation: .vertical, spacing: 6)
        emptyStateBox.halign = .center
        emptyStateBox.valign = .center
        emptyStateBox.canTarget = false

        emptyStateTitle = Label(str: "No events yet")
        emptyStateTitle.add(cssClass: "heading")
        emptyStateTitle.halign = .center
        emptyStateBox.append(child: emptyStateTitle)

        emptyStateSubtitle = Label(str: "Events from your sessions will appear here.")
        emptyStateSubtitle.add(cssClass: "dim-label")
        emptyStateSubtitle.halign = .center
        emptyStateSubtitle.justify = .center
        emptyStateSubtitle.wrap = true
        emptyStateBox.append(child: emptyStateSubtitle)

        pendingPillButton = Button(label: "0 new events while paused")
        pendingPillButton.add(cssClass: "luma-event-pending-pill")
        pendingPillButton.halign = .center
        pendingPillButton.valign = .end
        pendingPillButton.marginBottom = 12
        pendingPillButton.visible = false

        headerSeparator = Separator(orientation: .horizontal)
        headerSeparator.visible = false
        widget.append(child: headerSeparator)

        listOverlay = Overlay()
        listOverlay.hexpand = true
        listOverlay.vexpand = true
        listOverlay.set(child: WidgetRef(scroll))
        listOverlay.addOverlay(widget: emptyStateBox)
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

        collapseCaretButton.onClicked { [weak self] _ in
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
                self.setPaused(self.pauseButton.active)
            }
        }

        scroller.onPinnedChanged = { [weak self] pinned in
            MainActor.assumeIsolated { self?.setPaused(!pinned) }
        }

        clearEventsButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overflowMenuButton.popdown()
                self?.clearEvents()
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
            self?.handleEventsCleared()
        }

        syncSnapshot()
    }

    func setInitialCollapsed(_ value: Bool) {
        guard isCollapsed != value else { return }
        isCollapsed = value
        applyCollapsedState()
        updateBar()
        updatePendingPill()
    }

    private func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        pauseButton.active = paused
        pauseButton.label = paused ? "Resume" : "Pause"
        if !paused {
            syncSnapshot()
            pendingNewEvents = 0
            scroller.pin()
        }
        updateLiveIndicator()
        updatePendingPill()
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
        collapsedBar.visible = isCollapsed
        filterBar.visible = !isCollapsed
        headerSeparator.visible = !isCollapsed
        listOverlay.visible = !isCollapsed
        if isCollapsed {
            widget.remove(cssClass: "is-expanded")
        } else {
            widget.add(cssClass: "is-expanded")
        }
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
            emptyStateBox.visible = false
            scroller.pin()
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
        scroller.pin()
    }

    private func clearEvents() {
        engine?.clearEventLog()
    }

    private func handleEventsCleared() {
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
        emptyStateBox.visible = filteredEvents.isEmpty
        if filteredEvents.isEmpty {
            applyEmptyState()
        }
    }

    private func applyEmptyState() {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSourceFilter = enabledSources != Set(EventSourceFilter.allCases)
        let hasProcessFilter = selectedProcessName != nil

        if displayedEvents.isEmpty {
            emptyStateTitle.setText(str: "No events yet")
            emptyStateSubtitle.setText(str: "Events from your sessions will appear here.")
        } else if !trimmedSearch.isEmpty {
            emptyStateTitle.setText(str: "No events match your search")
            emptyStateSubtitle.setText(str: "Try a different search term.")
        } else if hasSourceFilter || hasProcessFilter {
            emptyStateTitle.setText(str: "No events match the current filters")
            emptyStateSubtitle.setText(str: "Try adjusting the source or process filters.")
        } else {
            emptyStateTitle.setText(str: "No events yet")
            emptyStateSubtitle.setText(str: "Events from your sessions will appear here.")
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
        } else {
            widget.remove(cssClass: "has-pending-events")
        }
        updateLiveIndicator()
    }

    private func updateLiveIndicator() {
        liveLabel.setText(str: isPaused ? "Paused" : "Live")
        if isPaused {
            liveDot.remove(cssClass: "luma-live-dot")
            liveDot.add(cssClass: "luma-paused-dot")
        } else {
            liveDot.remove(cssClass: "luma-paused-dot")
            liveDot.add(cssClass: "luma-live-dot")
        }
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
            check.onToggled { [weak self] ref in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if ref.active {
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
            payload.halign = .fill
            payload.xalign = 0
            payload.hexpand = true
            payload.lines = 3
            payload.wrap = true
            payload.ellipsize = .end
            payload.selectable = true
            payload.add(cssClass: "monospace")
            row.append(child: payload)
        }

        let badge = makeSourceBadge(for: event)
        badge.halign = .end
        row.append(child: badge)

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
        let text = sourceBadgeText(for: event)
        let label = Label(str: text)
        label.add(cssClass: "luma-event-badge")
        label.add(cssClass: "luma-event-source-\(colorIndex(for: badgeColorKey(for: event)))")
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

    private func sourceBadgeText(for event: RuntimeEvent) -> String {
        let process = processName(for: event)
        switch event.source {
        case .processOutput(let fd):
            let channel: String
            switch fd {
            case 1: channel = "stdout"
            case 2: channel = "stderr"
            default: channel = "fd\(fd)"
            }
            return "\(process) • \(channel)"
        case .script:
            return "\(process) • Script Runtime"
        case .console:
            return "\(process) • Console"
        case .repl:
            return "\(process) • REPL"
        case .instrument:
            let name = instrument(for: event)
                .map { engine?.descriptor(for: $0).displayName ?? "Instrument" } ?? "Instrument"
            return "\(name) • \(process)"
        case .spawnGating(_, let deviceName, _, _, let outcome):
            let label = outcome == .captured ? "Spawn Captured" : "Spawn Released"
            return "\(deviceName) • \(label)"
        case .engine(let subsystem):
            return "Engine • \(subsystem)"
        }
    }

    private func badgeColorKey(for event: RuntimeEvent) -> String {
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
            if let instance = instrument(for: event), let engine {
                return engine.descriptor(for: instance).displayName
            }
            return "Instrument"
        case .spawnGating(_, _, _, _, let outcome):
            return outcome == .captured ? "spawn-captured" : "spawn-released"
        case .engine:
            return "engine"
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
        textLabel.halign = .fill
        textLabel.xalign = 0
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
            loc.selectable = true
            column.append(child: loc)
        }

        if let stack = error.stack, !stack.isEmpty {
            let stackLabel = Label(str: stack)
            stackLabel.add(cssClass: "monospace")
            stackLabel.add(cssClass: "dim-label")
            stackLabel.halign = .fill
            stackLabel.xalign = 0
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
            payload.halign = .fill
            payload.xalign = 0
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
                wrapper.widget.halign = .fill
                wrapper.widget.hexpand = true
                column.append(child: wrapper.widget)
            }
            row.append(child: column)
        } else {
            let payload = Label(str: message.values.map { $0.inlineDescription }.joined(separator: " "))
            payload.add(cssClass: "monospace")
            payload.halign = .fill
            payload.xalign = 0
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

        let wrapper = JSInspectValueWidget.make(value: value, engine: engine, sessionID: sessionID)
        jsValueKeepers.append(wrapper)
        wrapper.widget.hexpand = true
        return wrapper.widget
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
            let sessionID = event.sessionID
        else { return nil }

        let hookID = parsed.id

        let column = Box(orientation: .horizontal, spacing: 8)
        column.hexpand = true

        let rightClick = GestureClick()
        rightClick.set(button: 3)
        let anchor = widget
        rightClick.onPressed { [weak self, column, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                let (tx, ty) = computePoint(x: x, y: y, from: column, to: anchor)
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
            payload.halign = .fill
            payload.xalign = 0
            payload.hexpand = true
            payload.lines = 3
            payload.wrap = true
            payload.ellipsize = .end
            payload.selectable = true
            payload.add(cssClass: "monospace")
            column.append(child: payload)
        } else {
            let wrapper = JSInspectValueWidget.make(value: parsed.message, engine: engine!, sessionID: sessionID)
            jsValueKeepers.append(wrapper)
            wrapper.widget.hexpand = true
            column.append(child: wrapper.widget)
        }

        if let backtrace = parsed.backtrace, !backtrace.isEmpty {
            let button = Button()
            button.set(child: Image(iconName: "view-list-symbolic"))
            button.add(cssClass: "flat")
            button.valign = .start
            button.tooltipText = "Show backtrace"
            button.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setPaused(true)
                    self.presentBacktrace(button: button, sessionID: sessionID, pointers: backtrace)
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
                let (tx, ty) = computePoint(x: x, y: y, from: row, to: anchor)
                self.presentRowContextMenu(at: anchor, x: tx, y: ty, event: event)
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
        case .instrument(_, let name):
            title = engine.instrument(forEvent: event).map { engine.descriptor(for: $0).displayName } ?? name
        case .spawnGating(_, _, _, _, let outcome):
            title = outcome == .captured ? "Spawn Captured" : "Spawn Released"
        case .engine(let subsystem):
            title = "Engine (\(subsystem))"
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
        sessionID: UUID,
        pointers: [JSInspectValue]
    ) {
        guard let engine else { return }
        let popover = Popover()
        popover.set(parent: WidgetRef(button))
        popover.autohide = true

        let column = Box(orientation: .vertical, spacing: 10)
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
        let spinner = makeSpinner()
        spinner.valign = .center
        spinner.visible = false
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
            row.marginTop = 4
            row.marginBottom = 4
            let num = Label(str: "#\(idx + 1)")
            num.add(cssClass: "dim-label")
            num.add(cssClass: "monospace")
            num.valign = .center
            row.append(child: num)
            let line = Label(str: engine.anchor(sessionID: sessionID, address: addr).displayString)
            line.add(cssClass: "monospace")
            line.halign = .start
            line.hexpand = true
            line.valign = .center
            line.selectable = false
            row.append(child: line)
            lineLabels.append(line)
            AddressActionMenu.attach(to: line, engine: engine, sessionID: sessionID, address: addr, value: String(format: "0x%llx", addr))

            let openButton = Button()
            openButton.set(child: Image(iconName: "go-next-symbolic"))
            openButton.add(cssClass: "circular")
            openButton.add(cssClass: "flat")
            openButton.valign = .center
            openButton.tooltipText = "Open Disassembly"
            openButton.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.openDisassembly(sessionID: sessionID, address: addr)
                }
            }
            row.append(child: openButton)

            listBox.append(child: row)
            if idx < addresses.count - 1 {
                listBox.append(child: Separator(orientation: .horizontal))
            }
        }

        popover.set(child: column)
        popover.popup()

        spinner.visible = true
        Task { @MainActor in
            defer { spinner.visible = false }
            let displays = await engine.symbolDisplay(sessionID: sessionID, addresses: addresses)
            for (idx, display) in displays.enumerated() where idx < lineLabels.count {
                lineLabels[idx].setText(str: display.displayString)
            }
        }
    }

    private func openDisassembly(sessionID: UUID, address: UInt64) {
        guard let engine else { return }
        do {
            let insight = try engine.getOrCreateInsight(
                sessionID: sessionID,
                pointer: address,
                kind: .disassembly
            )
            AddressActionMenu.navigator?(sessionID, insight.id)
        } catch {
            AddressActionMenu.errorReporter?("Can\u{2019}t open disassembly: \(error.localizedDescription)")
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
            if let instance = instrument(for: event), let engine {
                name = engine.descriptor(for: instance).displayName
            } else {
                name = "Instrument"
            }
            return "\(name)\(processSuffix)"
        case .spawnGating(_, let deviceName, _, _, let outcome):
            let label = outcome == .captured ? "captured" : "released"
            return "spawn \(label) · \(deviceName)"
        case .engine(let subsystem):
            return "engine · \(subsystem)"
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
        while let child = container.firstChild {
            container.remove(child: child)
        }
    }
}

private enum EventSourceFilter: String, CaseIterable, Hashable {
    case processOutput
    case script
    case console
    case repl
    case instrument
    case spawnGating
    case engine

    var menuTitle: String {
        switch self {
        case .processOutput: return "Process Output"
        case .script: return "Script Runtime"
        case .console: return "Console"
        case .repl: return "REPL"
        case .instrument: return "Instruments"
        case .spawnGating: return "Spawn Gating"
        case .engine: return "Engine"
        }
    }

    static func from(_ source: LumaCore.RuntimeEvent.Source) -> EventSourceFilter {
        switch source {
        case .processOutput: return .processOutput
        case .script: return .script
        case .console: return .console
        case .repl: return .repl
        case .instrument: return .instrument
        case .spawnGating: return .spawnGating
        case .engine: return .engine
        }
    }
}
