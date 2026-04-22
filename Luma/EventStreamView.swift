import SwiftUI
import LumaCore

struct EventStreamView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    var onCollapseRequested: (() -> Void)?

    @State private var displayedEvents: [RuntimeEvent] = []
    @State private var filteredEvents: [RuntimeEvent] = []

    @State private var isPaused: Bool = false
    @State private var pendingNewEvents: Int = 0
    @State private var lastEventsVersion: Int = 0

    @State private var scrollToLastToken: Int = 0
    @State private var isAtBottom: Bool = true
    @State private var isAutoScrolling: Bool = false

    @State private var searchText: String = ""
    @State private var searchCache: [RuntimeEvent.ID: String] = [:]
    @State private var sourceFilter: EventSourceFilter = .all
    @State private var selectedProcessName: String?

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollViewReader { proxy in
                GeometryReader { geo in
                    ZStack(alignment: .bottomTrailing) {
                        scrollContent
                            .coordinateSpace(name: "EventScroll")
                            .onPreferenceChange(BottomRowOffsetPreferenceKey.self) { bottomY in
                                updateScrollPosition(bottomY: bottomY, viewportHeight: geo.size.height)
                            }

                        if let empty = emptyStateReason {
                            EmptyStateView(reason: empty)
                        }

                        if pendingNewEvents > 0 && (isPaused || !isAtBottom) {
                            Button {
                                goLiveAndScrollToBottom()
                            } label: {
                                Text("Show \(pendingNewEvents) new event\(pendingNewEvents == 1 ? "" : "s")")
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.thinMaterial)
                                    .clipShape(Capsule())
                            }
                            .padding()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isSearchFocused = false
                    }
                    .onAppear {
                        syncSnapshotFromWorkspace()
                        isPaused = false
                        pendingNewEvents = 0
                        isAtBottom = true
                        scrollToLastToken &+= 1
                    }
                    .onChange(of: workspace.engine.eventLog.totalReceived) { _, newVersion in
                        handleEventVersionChange(newVersion)
                    }
                    .onChange(of: scrollToLastToken) { _, _ in
                        guard let last = filteredEvents.last else { return }
                        isAutoScrolling = true
                        proxy.scrollTo(last.id, anchor: .bottom)
                        DispatchQueue.main.async {
                            isAutoScrolling = false
                        }
                    }
                    .onChange(of: searchText) { _, _ in
                        rebuildFilteredEvents()
                    }
                    .onChange(of: sourceFilter) { _, _ in
                        rebuildFilteredEvents()
                    }
                    .onChange(of: selectedProcessName) { _, _ in
                        rebuildFilteredEvents()
                    }
                }
            }
        }
    }

    private var header: some View {
        Group {
            if isCompactWidth {
                HStack(spacing: 8) {
                    compactSourceFilter
                    if !availableProcessNames.isEmpty {
                        compactProcessFilter
                    }
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                    pauseButton
                    overflowMenu
                }
            } else {
                HStack(spacing: 8) {
                    Label("Event Stream", systemImage: "waveform")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    regularSourceFilter

                    if !availableProcessNames.isEmpty {
                        regularProcessFilter
                    }

                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .focused($isSearchFocused)

                    Spacer()

                    HStack(spacing: 6) {
                        Circle()
                            .frame(width: 6, height: 6)
                            .foregroundColor(isPaused ? .gray : .green)
                        Text(isPaused ? "Paused" : "Live")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    pauseButton
                    overflowMenu

                    if let onCollapseRequested {
                        Button {
                            onCollapseRequested()
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .help("Hide the event stream")
                    }
                }
            }
        }
        .padding(.horizontal, isCompactWidth ? 16 : 8)
        .padding(.vertical, 4)
    }

    private var regularSourceFilter: some View {
        Picker("", selection: $sourceFilter) {
            ForEach(EventSourceFilter.allCases) { filter in
                Text(filter.menuTitle).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .help("Filter by event source")
    }

    private var compactSourceFilter: some View {
        Menu {
            Picker("Source", selection: $sourceFilter) {
                ForEach(EventSourceFilter.allCases) { filter in
                    Text(filter.menuTitle).tag(filter)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .symbolVariant(sourceFilter == .all ? .none : .fill)
        }
        .accessibilityLabel("Filter by event source")
    }

    private var regularProcessFilter: some View {
        Menu {
            processFilterContent
        } label: {
            Label(
                selectedProcessName ?? "All Processes",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .controlSize(.small)
        .help("Filter by process")
    }

    private var compactProcessFilter: some View {
        Menu {
            processFilterContent
        } label: {
            Image(systemName: "cpu")
                .symbolVariant(selectedProcessName == nil ? .none : .fill)
        }
        .accessibilityLabel("Filter by process")
    }

    @ViewBuilder
    private var processFilterContent: some View {
        Button("All Processes") {
            selectedProcessName = nil
        }

        Divider()

        ForEach(availableProcessNames, id: \.self) { name in
            Button {
                selectedProcessName = name
            } label: {
                if selectedProcessName == name {
                    Label(name, systemImage: "checkmark")
                } else {
                    Text(name)
                }
            }
        }
    }

    private var pauseButton: some View {
        Button {
            togglePause()
        } label: {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.borderless)
        .help(isPaused ? "Resume live tail" : "Pause event stream")
    }

    private var overflowMenu: some View {
        Menu {
            Button(role: .destructive) {
                workspace.engine.eventLog.clear()
                resetAllEventState()
                isPaused = false
                isAtBottom = true
            } label: {
                Label("Clear Events", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .help("More actions")
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filteredEvents.enumerated()), id: \.1.id) { index, evt in
                    let previousTimestamp: Date? = index > 0 ? filteredEvents[index - 1].timestamp : nil

                    EventRow(
                        evt: evt,
                        previousTimestamp: previousTimestamp,
                        workspace: workspace,
                        selection: $selection
                    ) {
                        pin(evt)
                    }
                    .id(evt.id)
                    .background(
                        GeometryReader { rowGeo in
                            Color.clear
                                .preference(
                                    key: BottomRowOffsetPreferenceKey.self,
                                    value: index == filteredEvents.count - 1
                                        ? rowGeo.frame(in: .named("EventScroll")).maxY
                                        : BottomRowOffsetPreferenceKey.defaultValue
                                )
                        }
                    )

                    Divider()
                }
            }
        }
    }

    enum EmptyReason {
        case noEvents
        case filtered
        case search
    }

    private var emptyStateReason: EmptyReason? {
        if !filteredEvents.isEmpty {
            return nil
        }

        if displayedEvents.isEmpty {
            return .noEvents
        }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .search
        }

        if sourceFilter != .all || selectedProcessName != nil {
            return .filtered
        }

        return .noEvents
    }

    private func resetAllEventState() {
        displayedEvents.removeAll()
        filteredEvents.removeAll()
        searchCache.removeAll()
        pendingNewEvents = 0
        lastEventsVersion = 0
    }

    private func syncSnapshotFromWorkspace() {
        displayedEvents = workspace.events
        lastEventsVersion = workspace.engine.eventLog.totalReceived
        rebuildFilteredEvents()
    }

    private func goLiveAndScrollToBottom() {
        isPaused = false
        pendingNewEvents = 0
        syncSnapshotFromWorkspace()
        isAtBottom = true
        scrollToLastToken &+= 1
    }

    private func updateScrollPosition(bottomY: CGFloat, viewportHeight: CGFloat) {
        guard !filteredEvents.isEmpty else {
            isAtBottom = true
            return
        }

        if bottomY == BottomRowOffsetPreferenceKey.defaultValue { return }

        let threshold: CGFloat = 20
        let distanceFromBottom = bottomY - viewportHeight
        let atBottomNow = distanceFromBottom <= threshold

        if atBottomNow != isAtBottom {
            if !atBottomNow && !isPaused && !isAutoScrolling {
                isPaused = true
            }
            isAtBottom = atBottomNow
        }
    }

    private func togglePause() {
        if isPaused {
            goLiveAndScrollToBottom()
        } else {
            isPaused = true
            syncSnapshotFromWorkspace()
        }
    }

    private func handleEventVersionChange(_ newVersion: Int) {
        if newVersion == 0 {
            resetAllEventState()
            return
        }

        let delta = max(0, newVersion - lastEventsVersion)

        if isPaused {
            pendingNewEvents += delta
            lastEventsVersion = newVersion
            return
        }

        lastEventsVersion = newVersion
        if isAtBottom {
            syncSnapshotFromWorkspace()
            pendingNewEvents = 0
            scrollToLastToken &+= 1
        } else {
            pendingNewEvents += delta
        }
    }

    private func rebuildFilteredEvents() {
        guard !displayedEvents.isEmpty else {
            filteredEvents = []
            searchCache = [:]
            return
        }

        let ids = Set(displayedEvents.map { $0.id })
        searchCache = searchCache.filter { ids.contains($0.key) }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSearch = !trimmedSearch.isEmpty

        filteredEvents = displayedEvents.filter { evt in
            guard sourceFilter.matches(evt.source) else { return false }

            if let name = selectedProcessName {
                guard processName(for: evt) == name else { return false }
            }

            if hasSearch {
                let blob: String
                if let cached = searchCache[evt.id] {
                    blob = cached
                } else {
                    let context = prettyContext(evt)
                    let payload = prettyPayload(evt)
                    let combined = [payload, context.title, context.process ?? ""]
                        .joined(separator: " ")
                    searchCache[evt.id] = combined
                    blob = combined
                }

                guard blob.localizedCaseInsensitiveContains(trimmedSearch) else {
                    return false
                }
            }

            return true
        }
    }

    private var availableProcessNames: [String] {
        let names = Set(displayedEvents.map { processName(for: $0) })
        return names.sorted()
    }

    private func pin(_ evt: RuntimeEvent) {
        let (processName, title) = prettyContext(evt)

        workspace.engine.addNotebookEntry(
            LumaCore.NotebookEntry(
                title: title,
                details: prettyPayload(evt),
                binaryData: evt.data.map { Data($0) },
                sessionID: evt.sessionID ?? UUID(),
                processName: processName
            ))
    }

    private func processName(for evt: RuntimeEvent) -> String {
        workspace.engine.session(id: evt.sessionID ?? UUID())?.processName ?? ""
    }

    private func prettyContext(_ evt: RuntimeEvent) -> (process: String?, title: String) {
        let processName = workspace.engine.session(id: evt.sessionID ?? UUID())?.processName ?? ""
        switch evt.source {
        case .processOutput(let fd):
            let channel: String = {
                switch fd {
                case 1: return "stdout"
                case 2: return "stderr"
                default: return "fd\(fd)"
                }
            }()
            return (processName, "Output on \(channel)")

        case .script:
            return (processName, "Script Runtime (\(processName))")

        case .console:
            return (processName, "Console (\(processName))")

        case .repl:
            return (processName, "REPL (\(processName))")

        case .instrument(_, let name):
            return (processName, "Instrument \(name)")
        }
    }

    private func prettyPayload(_ evt: RuntimeEvent) -> String {
        switch evt.source {
        case .console:
            if case .consoleMessage(let message) = evt.payload {
                let parts = message.values.map { $0.inlineDescription }
                return parts.joined(separator: " ")
            }
            return String(describing: evt.payload)

        case .instrument:
            if let instrument = workspace.instrument(for: evt),
                let descriptor = workspace.engine.descriptor(for: instrument)
            {
                return descriptor.summarizeEvent(evt)
            }
            return String(describing: evt.payload)

        default:
            return String(describing: evt.payload)
        }
    }
}

private struct BottomRowOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let new = nextValue()
        if new != .infinity {
            value = new
        }
    }
}

private enum EventSourceFilter: String, CaseIterable, Identifiable {
    case all
    case output
    case script
    case console
    case repl
    case instrument

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .all: return "All Sources"
        case .output: return "Process Output"
        case .script: return "Script Runtime"
        case .console: return "Console"
        case .repl: return "REPL"
        case .instrument: return "Instruments"
        }
    }

    func matches(_ source: LumaCore.RuntimeEvent.Source) -> Bool {
        switch self {
        case .all:
            return true
        case .output:
            if case .processOutput = source { return true }
            return false
        case .script:
            if case .script = source { return true }
            return false
        case .console:
            if case .console = source { return true }
            return false
        case .repl:
            if case .repl = source { return true }
            return false
        case .instrument:
            if case .instrument = source { return true }
            return false
        }
    }
}

private struct EmptyStateView: View {
    let reason: EventStreamView.EmptyReason

    var body: some View {
        VStack(spacing: 6) {
            switch reason {
            case .noEvents:
                Text("No events yet")
                    .font(.headline)
                Text("Events from your sessions will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .filtered:
                Text("No events match the current filters")
                    .font(.headline)
                Text("Try adjusting the source or process filters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .search:
                Text("No events match your search")
                    .font(.headline)
                Text("Try a different search term.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

struct EventRow: View {
    let evt: RuntimeEvent
    let previousTimestamp: Date?
    let workspace: Workspace
    @Binding var selection: SidebarItemID?
    let pinAction: () -> Void

    private static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.locale = .autoupdatingCurrent
        df.timeZone = .current
        return df
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let delta = deltaText {
                Text(delta)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                    .help(Self.timestampFormatter.string(from: evt.timestamp))
            } else {
                Text(" ")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                    .help(Self.timestampFormatter.string(from: evt.timestamp))
            }

            contentView

            Spacer(minLength: 8)

            EventSourceBadge(evt: evt, workspace: workspace)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.background)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                pinAction()
            } label: {
                Label("Pin to Notebook", systemImage: "pin")
            }

            ForEach(instrumentMenuItems) { item in
                if item.role == .destructive {
                    Button(role: .destructive) {
                        item.action()
                    } label: {
                        Label(item.title, systemImage: item.systemImage ?? "questionmark.circle")
                    }
                } else {
                    Button {
                        item.action()
                    } label: {
                        Label(item.title, systemImage: item.systemImage ?? "questionmark.circle")
                    }
                }
            }
        }
    }

    private var deltaText: String? {
        guard let previousTimestamp else {
            return nil
        }

        let dt = evt.timestamp.timeIntervalSince(previousTimestamp)
        guard dt > 0 else { return nil }

        let ms = dt * 1000.0

        if ms < 1.0 {
            return nil
        }

        if ms < 1000.0 {
            return String(format: "+%.0f ms", ms)
        } else if dt < 60.0 {
            return String(format: "+%.2f s", dt)
        } else {
            return String(format: "+%.0f s", dt)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let errorView = jsErrorEventView {
            errorView
        } else if let consoleView = consoleEventView {
            consoleView
        } else if let instrumentView = instrumentEventView {
            instrumentView
        } else {
            Text(String(describing: evt.payload))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private var jsErrorEventView: AnyView? {
        guard case .jsError(let error) = evt.payload else {
            return nil
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text(error.text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color.red)
                    .textSelection(.enabled)

                if let fileName = error.fileName, let line = error.lineNumber {
                    Text("\(fileName):\(line)\(error.columnNumber.map { ":\($0)" } ?? "")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let stack = error.stack, !stack.isEmpty {
                    Text(stack)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        )
    }

    private var consoleEventView: AnyView? {
        guard case .consoleMessage(let message) = evt.payload else {
            return nil
        }

        let allStrings = message.values.compactMap { value -> String? in
            if case .string(let s) = value {
                return s
            }
            return nil
        }

        let valueView: AnyView
        if !message.values.isEmpty && allStrings.count == message.values.count {
            valueView = AnyView(
                Text(allStrings.joined(separator: " "))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
            )
        } else {
            valueView = AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(message.values.enumerated()), id: \.0) { _, value in
                        JSInspectValueView(
                            value: value,
                            sessionID: evt.sessionID ?? UUID(),
                            workspace: workspace,
                            selection: $selection
                        )
                        .font(.system(.footnote, design: .monospaced))
                    }
                }
            )
        }

        return AnyView(
            HStack(alignment: .top, spacing: 8) {
                Text(message.level.badgeText.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(message.level.badgeColor.opacity(0.15))
                    .foregroundStyle(message.level.badgeColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                valueView
            }
        )
    }

    private var instrumentEventView: AnyView? {
        guard let instrument = workspace.instrument(for: evt),
            let ui = InstrumentUIRegistry.shared.ui(for: instrument)
        else {
            return nil
        }

        return ui.renderEvent(evt, workspace: workspace, selection: $selection)
    }

    private var instrumentMenuItems: [InstrumentEventMenuItem] {
        guard let instrument = workspace.instrument(for: evt),
            let ui = InstrumentUIRegistry.shared.ui(for: instrument)
        else {
            return []
        }

        return ui.makeEventContextMenuItems(evt, workspace: workspace, selection: $selection)
    }
}

private struct EventSourceBadge: View {
    let evt: RuntimeEvent
    @ObservedObject var workspace: Workspace

    var body: some View {
        Text(labelText)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var processName: String {
        workspace.engine.session(id: evt.sessionID ?? UUID())?.processName ?? ""
    }

    private var labelText: String {
        switch evt.source {
        case .processOutput(let fd):
            let channel: String = {
                switch fd {
                case 1: return "stdout"
                case 2: return "stderr"
                default: return "fd\(fd)"
                }
            }()
            return "\(processName) • \(channel)"

        case .script:
            return "\(processName) • Script Runtime"

        case .console:
            return "\(processName) • Console"

        case .repl:
            return "\(processName) • REPL"

        case .instrument:
            let name = workspace.instrument(for: evt).flatMap { workspace.engine.descriptor(for: $0)?.displayName } ?? "Instrument"
            return "\(name) • \(processName)"
        }
    }

    private var backgroundColor: Color {
        switch evt.source {
        case .processOutput(let fd):
            switch fd {
            case 1: return .gray
            case 2: return .orange
            default: return .orange
            }
        case .script:
            return .mint
        case .console:
            return .purple
        case .repl:
            return .accentColor
        case .instrument:
            return .green
        }
    }
}

extension ConsoleLevel {
    fileprivate var badgeText: String {
        switch self {
        case .info: return "info"
        case .debug: return "debug"
        case .warning: return "warn"
        case .error: return "error"
        }
    }

    fileprivate var badgeColor: Color {
        switch self {
        case .info: return .accentColor
        case .debug: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
