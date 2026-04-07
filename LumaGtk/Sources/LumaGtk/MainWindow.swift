import Foundation
import Frida
import Gtk
import LumaCore
import Observation

@MainActor
final class MainWindow {
    private let app: Application
    private let window: ApplicationWindow

    private var engine: Engine?

    private let sessionsList: ListBox
    private let packagesList: ListBox
    private let packagesSection: Box
    private let notebookListBox: ListBox
    private let notebookRow: ListBoxRow
    private let detailContainer: Box
    private let eventStreamPane: EventStreamPane
    private var notebookPane: NotebookPane?

    private var sessions: [LumaCore.ProcessSession] = []
    private var installedPackages: [LumaCore.InstalledPackage] = []
    private var instrumentsBySession: [UUID: [LumaCore.InstrumentInstance]] = [:]
    private var sessionsRowKinds: [SessionsRow] = []
    private var selection: SidebarSelection = .notebook
    private var addInstrumentButton: Button!

    private enum SidebarSelection: Equatable {
        case notebook
        case session(UUID)
        case instrument(sessionID: UUID, instrumentID: UUID)
        case package(UUID)
    }

    private enum SessionsRow {
        case session(UUID)
        case instrument(sessionID: UUID, instrumentID: UUID)
    }

    init(app: Application) {
        self.app = app
        self.window = ApplicationWindow(application: app)
        window.title = "Luma"
        window.setDefaultSize(width: 1200, height: 800)

        let notebookListBox = ListBox()
        let notebookRow = ListBoxRow()
        let sessionsList = ListBox()
        let packagesList = ListBox()
        let packagesSection = Box(orientation: .vertical, spacing: 0)
        let detailContainer = Box(orientation: .vertical, spacing: 0)
        let eventStreamPane = EventStreamPane()
        self.notebookListBox = notebookListBox
        self.notebookRow = notebookRow
        self.sessionsList = sessionsList
        self.packagesList = packagesList
        self.packagesSection = packagesSection
        self.detailContainer = detailContainer
        self.eventStreamPane = eventStreamPane

        let header = HeaderBar()
        let newSessionButton = Button(label: "New Session…")
        newSessionButton.add(cssClass: "suggested-action")
        header.packStart(child: newSessionButton)

        let addInstrumentButton = Button(label: "Add Instrument…")
        addInstrumentButton.sensitive = false
        header.packStart(child: addInstrumentButton)
        self.addInstrumentButton = addInstrumentButton

        window.set(titlebar: WidgetRef(header))

        let topPaned = Paned(orientation: .horizontal)
        topPaned.position = 280
        topPaned.startChild = WidgetRef(buildSidebar())
        topPaned.endChild = WidgetRef(buildDetailPane())
        topPaned.hexpand = true
        topPaned.vexpand = true

        let separator = Separator(orientation: .horizontal)

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: topPaned)
        column.append(child: separator)
        column.append(child: eventStreamPane.widget)
        window.set(child: column)

        newSessionButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openTargetPicker()
            }
        }
        addInstrumentButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openAddInstrumentDialog()
            }
        }
    }

    func present() {
        window.present()
        renderDetail()
    }

    func attach(engine: Engine) {
        self.engine = engine
        renderSessions(engine.sessions)
        renderPackages((try? engine.store.fetchPackagesState())?.packages ?? [])
        observeSessions()
        eventStreamPane.attach(engine: engine)
        notebookPane = NotebookPane(engine: engine)
        if case .notebook = selection {
            renderDetail()
        }
    }

    func showFatalError(_ message: String) {
        replaceDetail(with: Label(str: message))
    }

    // MARK: - Target picker

    private func openTargetPicker(reusing existing: LumaCore.ProcessSession? = nil, reason: String? = nil) {
        guard let engine else { return }
        let picker = TargetPicker(parent: window, engine: engine, reason: reason) { [weak self] device, process in
            self?.attach(device: device, process: process, reusing: existing)
        }
        picker.present()
    }

    private func attach(
        device: Frida.Device,
        process: ProcessDetails,
        reusing existing: LumaCore.ProcessSession? = nil
    ) {
        guard let engine else { return }
        var session = existing ?? LumaCore.ProcessSession(
            kind: .attach,
            deviceID: device.id,
            deviceName: device.name,
            processName: process.name,
            lastKnownPID: process.pid
        )
        session.deviceID = device.id
        session.deviceName = device.name
        session.processName = process.name
        session.lastKnownPID = process.pid
        try? engine.store.save(session)
        Task { @MainActor in
            await engine.attach(device: device, process: process, session: session)
        }
    }

    // MARK: - Sidebar build

    private func buildSidebar() -> ScrolledWindow {
        let column = Box(orientation: .vertical, spacing: 8)
        column.marginTop = 8
        column.marginBottom = 8
        column.hexpand = true
        column.vexpand = true

        column.append(child: buildNotebookSection())
        column.append(child: buildSessionsSection())
        column.append(child: buildPackagesSection())

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: column)
        return scroll
    }

    private func buildNotebookSection() -> Box {
        notebookListBox.selectionMode = .single
        notebookListBox.add(cssClass: "navigation-sidebar")
        notebookListBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard row != nil else { return }
                self?.select(.notebook)
            }
        }

        let label = Label(str: "📓  Notebook")
        label.halign = .start
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 6
        notebookRow.set(child: label)
        notebookListBox.append(child: notebookRow)
        notebookListBox.select(row: notebookRow)

        let wrapper = Box(orientation: .vertical, spacing: 0)
        wrapper.append(child: notebookListBox)
        return wrapper
    }

    private func buildSessionsSection() -> Box {
        sessionsList.selectionMode = .single
        sessionsList.add(cssClass: "navigation-sidebar")
        sessionsList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.sessionsRowKinds.count else { return }
                switch self.sessionsRowKinds[index] {
                case .session(let id):
                    self.select(.session(id))
                case .instrument(let sid, let iid):
                    self.select(.instrument(sessionID: sid, instrumentID: iid))
                }
            }
        }

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: sectionHeader("Sessions"))
        column.append(child: sessionsList)
        return column
    }

    private func buildPackagesSection() -> Box {
        packagesList.selectionMode = .single
        packagesList.add(cssClass: "navigation-sidebar")
        packagesList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.installedPackages.count else { return }
                self.select(.package(self.installedPackages[index].id))
            }
        }

        packagesSection.append(child: sectionHeader("Packages"))
        packagesSection.append(child: packagesList)
        packagesSection.visible = false
        return packagesSection
    }

    private func sectionHeader(_ title: String) -> Label {
        let label = Label(str: title.uppercased())
        label.halign = .start
        label.marginStart = 16
        label.marginEnd = 12
        label.marginTop = 12
        label.marginBottom = 4
        label.add(cssClass: "heading")
        return label
    }

    // MARK: - Detail

    private func buildDetailPane() -> ScrolledWindow {
        detailContainer.hexpand = true
        detailContainer.vexpand = true

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: detailContainer)
        return scroll
    }

    private func renderDetail() {
        let widget: Widget
        switch selection {
        case .notebook:
            if let pane = notebookPane {
                widget = pane.widget
            } else {
                widget = makePlaceholder(
                    title: "Notebook",
                    subtitle: "Pinned events and notes will appear here."
                )
            }
        case .session(let id):
            if let session = sessions.first(where: { $0.id == id }) {
                widget = makeSessionDetail(session: session)
            } else {
                widget = makePlaceholder(title: "Session", subtitle: "(no longer in store)")
            }
        case .instrument(let sid, let iid):
            if let session = sessions.first(where: { $0.id == sid }),
                let instrument = (instrumentsBySession[sid] ?? []).first(where: { $0.id == iid })
            {
                widget = makeInstrumentDetail(session: session, instrument: instrument)
            } else {
                widget = makePlaceholder(title: "Instrument", subtitle: "(no longer in store)")
            }
        case .package(let id):
            if let package = installedPackages.first(where: { $0.id == id }) {
                widget = makePlaceholder(title: package.name, subtitle: "version \(package.version)")
            } else {
                widget = makePlaceholder(title: "Package", subtitle: "(no longer installed)")
            }
        }
        replaceDetail(with: widget)
        addInstrumentButton.sensitive = currentSessionID() != nil
    }

    private func currentSessionID() -> UUID? {
        switch selection {
        case .session(let id), .instrument(let id, _):
            return id
        default:
            return nil
        }
    }

    private func makeInstrumentDetail(
        session: LumaCore.ProcessSession,
        instrument: LumaCore.InstrumentInstance
    ) -> Box {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

        let descriptor = engine?.descriptor(for: instrument)
        let title = descriptor?.displayName ?? "Instrument"
        let subtitleLines: [String] = [
            "Session: \(session.processName)",
            "Kind: \(instrument.kind)",
            "Source: \(instrument.sourceIdentifier)",
            "Enabled: \(instrument.isEnabled)",
        ]
        column.append(child: makePlaceholder(title: title, subtitle: subtitleLines.joined(separator: "\n")))

        let configHeader = Label(str: "Configuration")
        configHeader.halign = .start
        configHeader.marginStart = 24
        configHeader.marginTop = 8
        configHeader.add(cssClass: "heading")
        column.append(child: configHeader)

        let configText = String(data: instrument.configJSON, encoding: .utf8) ?? "(non-UTF8)"
        let configLabel = Label(str: configText)
        configLabel.halign = .start
        configLabel.add(cssClass: "monospace")
        configLabel.wrap = true
        configLabel.selectable = true
        configLabel.marginStart = 24
        configLabel.marginEnd = 24
        configLabel.marginTop = 4
        configLabel.marginBottom = 12
        column.append(child: configLabel)

        let actions = Box(orientation: .horizontal, spacing: 8)
        actions.marginStart = 24
        actions.marginEnd = 24
        actions.marginBottom = 16
        let toggleLabel = instrument.isEnabled ? "Disable" : "Enable"
        let toggleButton = Button(label: toggleLabel)
        toggleButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.toggleInstrument(instrument)
            }
        }
        actions.append(child: toggleButton)

        let deleteButton = Button(label: "Remove")
        deleteButton.add(cssClass: "destructive-action")
        deleteButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deleteInstrument(instrument)
            }
        }
        actions.append(child: deleteButton)
        column.append(child: actions)

        return column
    }

    private func toggleInstrument(_ instrument: LumaCore.InstrumentInstance) {
        guard let engine else { return }
        Task { @MainActor in
            await engine.setInstrumentEnabled(instrument, enabled: !instrument.isEnabled)
            self.refreshInstruments()
            self.renderDetail()
        }
    }

    private func deleteInstrument(_ instrument: LumaCore.InstrumentInstance) {
        guard let engine else { return }
        Task { @MainActor in
            await engine.removeInstrument(instrument)
            self.refreshInstruments()
            if case .instrument(_, let id) = self.selection, id == instrument.id {
                self.select(.session(instrument.sessionID))
            } else {
                self.renderDetail()
            }
        }
    }

    private func makeSessionDetail(session: LumaCore.ProcessSession) -> Box {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

        if SessionDetachedBanner.shouldShow(for: session) {
            let banner = SessionDetachedBanner.make(for: session) { [weak self] in
                self?.reestablishSession(id: session.id)
            }
            column.append(child: banner)
        }

        if let engine {
            let repl = REPLPane(engine: engine, sessionID: session.id)
            column.append(child: repl.widget)
        } else {
            column.append(child: makePlaceholder(title: session.processName, subtitle: "Engine not ready."))
        }
        return column
    }

    // MARK: - Instruments

    private func openAddInstrumentDialog() {
        guard let engine, let sessionID = currentSessionID() else { return }
        let dialog = AddInstrumentDialog(parent: window, descriptors: engine.descriptors) { [weak self] descriptor in
            self?.addInstrument(descriptor: descriptor, sessionID: sessionID)
        }
        dialog.present()
    }

    private func addInstrument(descriptor: LumaCore.InstrumentDescriptor, sessionID: UUID) {
        guard let engine else { return }
        let configJSON = descriptor.makeInitialConfigJSON()
        Task { @MainActor in
            let instance = await engine.addInstrument(
                kind: descriptor.kind,
                sourceIdentifier: descriptor.sourceIdentifier,
                configJSON: configJSON,
                sessionID: sessionID
            )
            self.refreshInstruments()
            self.select(.instrument(sessionID: sessionID, instrumentID: instance.id))
        }
    }

    private func reestablishSession(id: UUID) {
        guard let engine else { return }
        Task { @MainActor in
            let result = await engine.reestablishSession(id: id)
            if case .needsUserInput(let reason, let session) = result {
                self.openTargetPicker(reusing: session, reason: reason)
            }
        }
    }

    private func makePlaceholder(title: String, subtitle: String) -> Box {
        let stack = Box(orientation: .vertical, spacing: 8)
        stack.marginStart = 24
        stack.marginEnd = 24
        stack.marginTop = 24
        stack.marginBottom = 24

        let titleLabel = Label(str: title)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-2")
        stack.append(child: titleLabel)

        let subtitleLabel = Label(str: subtitle)
        subtitleLabel.halign = .start
        subtitleLabel.wrap = true
        stack.append(child: subtitleLabel)

        return stack
    }

    private func replaceDetail<T: WidgetProtocol>(with widget: T) {
        var child = detailContainer.firstChild
        while let current = child {
            child = current.nextSibling
            detailContainer.remove(child: current)
        }
        detailContainer.append(child: widget)
    }

    // MARK: - Selection

    private func select(_ newValue: SidebarSelection) {
        guard selection != newValue else { return }
        selection = newValue
        switch newValue {
        case .notebook:
            sessionsList.unselectAll()
            packagesList.unselectAll()
        case .session(let id), .instrument(let id, _):
            notebookListBox.unselectAll()
            packagesList.unselectAll()
            if let row = sessionsRowKinds.firstIndex(where: { rowKind in
                switch (rowKind, newValue) {
                case (.session(let s), .session(let want)):
                    return s == want
                case (.instrument(_, let i), .instrument(_, let want)):
                    return i == want
                default:
                    return false
                }
            }).flatMap({ sessionsList.getRowAt(index: $0) }) {
                sessionsList.select(row: row)
            }
            _ = id
        case .package:
            notebookListBox.unselectAll()
            sessionsList.unselectAll()
        }
        renderDetail()
    }

    // MARK: - Engine bindings

    private func observeSessions() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.sessions
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                self.renderSessions(engine.sessions)
                self.observeSessions()
            }
        }
    }

    private func renderSessions(_ snapshot: [LumaCore.ProcessSession]) {
        sessions = snapshot
        refreshInstruments()

        let stillExists: Bool
        switch selection {
        case .session(let id), .instrument(let id, _):
            stillExists = snapshot.contains(where: { $0.id == id })
        default:
            stillExists = true
        }
        if !stillExists {
            select(.notebook)
            notebookListBox.select(row: notebookRow)
        }
    }

    private func refreshInstruments() {
        guard let engine else { return }
        instrumentsBySession.removeAll()
        for session in sessions {
            let list = (try? engine.store.fetchInstruments(sessionID: session.id)) ?? []
            instrumentsBySession[session.id] = list
        }
        rebuildSessionsList()
    }

    private func rebuildSessionsList() {
        sessionsList.removeAll()
        sessionsRowKinds.removeAll()
        for session in sessions {
            let row = ListBoxRow()
            let label = Label(str: "\(session.processName) — \(session.deviceName)")
            label.halign = .start
            label.marginStart = 12
            label.marginEnd = 12
            label.marginTop = 4
            label.marginBottom = 4
            row.set(child: label)
            sessionsList.append(child: row)
            sessionsRowKinds.append(.session(session.id))

            for instrument in instrumentsBySession[session.id] ?? [] {
                let irow = ListBoxRow()
                let descriptor = engine?.descriptor(for: instrument)
                let title = descriptor?.displayName ?? "Instrument"
                let ilabel = Label(str: "↳  \(title)")
                ilabel.halign = .start
                ilabel.marginStart = 24
                ilabel.marginEnd = 12
                ilabel.marginTop = 2
                ilabel.marginBottom = 2
                if !instrument.isEnabled {
                    ilabel.add(cssClass: "dim-label")
                }
                irow.set(child: ilabel)
                sessionsList.append(child: irow)
                sessionsRowKinds.append(.instrument(sessionID: session.id, instrumentID: instrument.id))
            }
        }

        if let idx = currentSelectionRowIndex(),
            let row = sessionsList.getRowAt(index: idx)
        {
            sessionsList.select(row: row)
        }
    }

    private func currentSelectionRowIndex() -> Int? {
        switch selection {
        case .session(let id):
            return sessionsRowKinds.firstIndex {
                if case .session(let s) = $0 { return s == id }
                return false
            }
        case .instrument(_, let id):
            return sessionsRowKinds.firstIndex {
                if case .instrument(_, let i) = $0 { return i == id }
                return false
            }
        default:
            return nil
        }
    }

    private func renderPackages(_ snapshot: [LumaCore.InstalledPackage]) {
        installedPackages = snapshot
        packagesList.removeAll()
        for package in snapshot {
            let row = ListBoxRow()
            let label = Label(str: "\(package.name)  \(package.version)")
            label.halign = .start
            label.marginStart = 12
            label.marginEnd = 12
            label.marginTop = 4
            label.marginBottom = 4
            row.set(child: label)
            packagesList.append(child: row)
        }
        packagesSection.visible = !snapshot.isEmpty
    }
}
