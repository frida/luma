import CWebKit
import Foundation
import Frida
import Gtk
import LumaCore
import Observation

@MainActor
final class MainWindow {
    private let app: Application
    private weak var application: LumaApplication?
    let window: ApplicationWindow
    private(set) var document: LumaDocument

    private var engine: Engine?

    private let sessionsList: ListBox
    private let packagesList: ListBox
    private let packagesSection: Box
    private var sessionsHeaderLabel: Label!
    private var packagesHeaderLabel: Label!
    private var sessionsEmptyHint: Label!
    private var packagesEmptyHint: Label!
    private let notebookListBox: ListBox
    private let notebookRow: ListBoxRow
    private let detailContainer: Box
    private let eventStreamPane: EventStreamPane
    private var notebookPane: NotebookPane?
    private weak var currentTracerEditor: InstrumentConfigEditor?

    private var sessions: [LumaCore.ProcessSession] = []
    private var installedPackages: [LumaCore.InstalledPackage] = []
    private var instrumentsBySession: [UUID: [LumaCore.InstrumentInstance]] = [:]
    private var insightsBySession: [UUID: [LumaCore.AddressInsight]] = [:]
    private var capturesBySession: [UUID: [LumaCore.ITraceCaptureRecord]] = [:]
    private var sessionIconTempFiles: [UUID: URL] = [:]
    private var sessionsRowKinds: [SessionsRow] = []
    private var selection: SidebarSelection = .notebook
    private var addInstrumentButton: Button!
    private var installPackageButton: Button!
    private var collaborationButton: Button!
    private var collaborationPanel: CollaborationPanel?
    private let outerPaned: Paned
    private var topPaned: Paned!
    private var toastOverlay: ToastOverlay!
    private var isCollaborationPanelVisible: Bool = false

    private enum SidebarSelection: Equatable {
        case notebook
        case session(UUID)
        case repl(UUID)
        case instrument(sessionID: UUID, instrumentID: UUID)
        case insight(sessionID: UUID, insightID: UUID)
        case itraceCapture(sessionID: UUID, captureID: UUID)
        case package(UUID)
    }

    private enum SessionsRow {
        case session(UUID)
        case repl(UUID)
        case instrument(sessionID: UUID, instrumentID: UUID)
        case insight(sessionID: UUID, insightID: UUID)
        case itraceCapture(sessionID: UUID, captureID: UUID)
    }

    init(app: Application, application: LumaApplication, document: LumaDocument) {
        self.app = app
        self.application = application
        self.document = document
        self.window = ApplicationWindow(application: app)
        self.outerPaned = Paned(orientation: .horizontal)
        window.title = MainWindow.makeTitle(for: document)
        let state = LumaState.shared
        window.setDefaultSize(width: state.windowWidth, height: state.windowHeight)
        if state.windowMaximized {
            window.maximize()
        }

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

        let installPackageButton = Button(label: "Install Package…")
        header.packStart(child: installPackageButton)
        self.installPackageButton = installPackageButton

        let collaborationButton = Button(label: "Collaboration")
        header.packStart(child: collaborationButton)
        self.collaborationButton = collaborationButton

        let primaryMenuButton = MenuButton()
        primaryMenuButton.set(iconName: "open-menu-symbolic")
        primaryMenuButton.tooltipText = "Main menu"
        if let menuModelPtr = application.primaryMenuPtr,
            let menuButtonPtr = primaryMenuButton.menu_button_ptr.map(UnsafeMutableRawPointer.init)
        {
            luma_menu_button_set_menu(menuButtonPtr, menuModelPtr)
        }
        header.packEnd(child: primaryMenuButton)

        window.set(titlebar: WidgetRef(header))

        let topPaned = Paned(orientation: .horizontal)
        topPaned.position = state.sidebarSashPosition
        let sidebar = buildSidebar()
        let detail = buildDetailPane()
        topPaned.startChild = WidgetRef(sidebar)
        topPaned.endChild = WidgetRef(detail)
        topPaned.hexpand = true
        topPaned.vexpand = true
        self.topPaned = topPaned

        outerPaned.position = state.collaborationSashPosition
        outerPaned.startChild = WidgetRef(topPaned)
        outerPaned.hexpand = true
        outerPaned.vexpand = true

        let separator = Separator(orientation: .horizontal)

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: outerPaned)
        column.append(child: separator)
        column.append(child: eventStreamPane.widget)
        let toastOverlay = ToastOverlay(content: column)
        self.toastOverlay = toastOverlay
        window.set(child: toastOverlay.widget)

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
        installPackageButton.onClicked { [weak self, weak installPackageButton] _ in
            MainActor.assumeIsolated {
                guard let button = installPackageButton else { return }
                self?.openPackageSearch(anchor: button)
            }
        }
        collaborationButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setCollaborationVisible(!self.isCollaborationPanelVisible)
            }
        }

        let closeHandler: (WindowRef) -> Bool = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persistWindowState()
                self.application?.windowDidClose(self)
            }
            return false
        }
        window.onCloseRequest(handler: closeHandler)
    }

    private func setCollaborationVisible(_ visible: Bool) {
        isCollaborationPanelVisible = visible
        collaborationPanel?.widget.visible = visible
    }

    func present() {
        window.present()
        renderDetail()
    }

    func showToast(_ message: String) {
        toastOverlay?.show(message)
    }

    func documentDidChange() {
        if let updated = application?.documentForWindow(self) {
            self.document = updated
        }
        window.title = MainWindow.makeTitle(for: document)
        showToast("Saved as \(document.displayName).luma")
    }

    private static func makeTitle(for document: LumaDocument) -> String {
        if document.isUntitled {
            return "Luma — ● \(document.displayName)"
        }
        return "Luma — \(document.displayName)"
    }

    private func persistWindowState() {
        var width: Int32 = 0
        var height: Int32 = 0
        window.getDefaultSize(width: &width, height: &height)
        let state = LumaState.shared
        state.saveWindowGeometry(
            width: Int(width),
            height: Int(height),
            maximized: window.isMaximized
        )
        state.saveSashes(
            sidebar: Int(topPaned.position),
            collaboration: Int(outerPaned.position)
        )
    }


    func attach(engine: Engine) {
        self.engine = engine
        renderSessions(engine.sessions)
        renderPackages((try? engine.store.fetchPackagesState())?.packages ?? [])
        observeSessions()
        eventStreamPane.attach(engine: engine)
        eventStreamPane.onNavigateToHook = { [weak self] sessionID, instrumentID, hookID in
            self?.navigateToHook(sessionID: sessionID, instrumentID: instrumentID, hookID: hookID)
        }
        let panel = CollaborationPanel(engine: engine, onClose: { [weak self] in
            self?.setCollaborationVisible(false)
        })
        collaborationPanel = panel
        outerPaned.endChild = WidgetRef(panel.widget)
        panel.widget.visible = isCollaborationPanelVisible
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
                case .repl(let id):
                    self.select(.repl(id))
                case .instrument(let sid, let iid):
                    self.select(.instrument(sessionID: sid, instrumentID: iid))
                case .insight(let sid, let iid):
                    self.select(.insight(sessionID: sid, insightID: iid))
                case .itraceCapture(let sid, let cid):
                    self.select(.itraceCapture(sessionID: sid, captureID: cid))
                }
            }
        }

        let body = Box(orientation: .vertical, spacing: 0)
        let hint = Label(str: "No sessions yet")
        hint.halign = .start
        hint.marginStart = 16
        hint.marginEnd = 12
        hint.marginTop = 4
        hint.marginBottom = 8
        hint.add(cssClass: "dim-label")
        sessionsEmptyHint = hint
        body.append(child: hint)
        body.append(child: sessionsList)

        let headerLabel = Label(str: "SESSIONS (0)")
        headerLabel.halign = .start
        headerLabel.add(cssClass: "luma-sidebar-section-header")
        sessionsHeaderLabel = headerLabel

        let expander = Expander(label: "")
        expander.set(labelWidget: headerLabel)
        expander.set(child: body)
        expander.expanded = true
        expander.marginStart = 4
        expander.marginEnd = 4

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: expander)
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

        let body = Box(orientation: .vertical, spacing: 0)
        let hint = Label(str: "No packages installed")
        hint.halign = .start
        hint.marginStart = 16
        hint.marginEnd = 12
        hint.marginTop = 4
        hint.marginBottom = 8
        hint.add(cssClass: "dim-label")
        packagesEmptyHint = hint
        body.append(child: hint)
        body.append(child: packagesList)

        let headerLabel = Label(str: "PACKAGES (0)")
        headerLabel.halign = .start
        headerLabel.add(cssClass: "luma-sidebar-section-header")
        packagesHeaderLabel = headerLabel

        let expander = Expander(label: "")
        expander.set(labelWidget: headerLabel)
        expander.set(child: body)
        expander.expanded = true
        expander.marginStart = 4
        expander.marginEnd = 4

        packagesSection.append(child: expander)
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
                widget = MainWindow.makeEmptyState(
                    icon: "computer-symbolic",
                    title: "Session unavailable",
                    subtitle: "This session is no longer in the store."
                )
            }
        case .repl(let id):
            if let session = sessions.first(where: { $0.id == id }), let engine {
                widget = makeREPLDetail(session: session, engine: engine)
            } else {
                widget = MainWindow.makeEmptyState(
                    icon: "utilities-terminal-symbolic",
                    title: "REPL unavailable",
                    subtitle: "The owning session is no longer in the store."
                )
            }
        case .insight(let sid, let iid):
            let cached = insightsBySession[sid]?.first { $0.id == iid }
            let insight = cached ?? (try? engine?.store.fetchInsights(sessionID: sid))?.first { $0.id == iid }
            if let insight, let engine {
                let address = insight.lastResolvedAddress ?? 0
                let panel = AddressDetailsPanel(engine: engine, sessionID: sid, address: address)
                widget = panel.widget
            } else {
                widget = MainWindow.makeEmptyState(
                    icon: "text-x-generic-symbolic",
                    title: "Insight not found",
                    subtitle: "This insight is no longer in the store."
                )
            }
        case .itraceCapture(let sid, let cid):
            let cached = capturesBySession[sid]
            let allCaptures = cached ?? (try? engine?.store.fetchITraceCaptures(sessionID: sid)) ?? []
            if let capture = allCaptures.first(where: { $0.id == cid }), let engine {
                let others = allCaptures.filter { $0.id != cid }
                let detail = ITraceDetailView(
                    capture: capture,
                    otherCaptures: others,
                    engine: engine,
                    sessionID: sid
                )
                widget = detail.widget
            } else {
                widget = MainWindow.makeEmptyState(
                    icon: "audio-x-generic-symbolic",
                    title: "Capture unavailable",
                    subtitle: "This ITrace capture is no longer in the store."
                )
            }
        case .instrument(let sid, let iid):
            if let session = sessions.first(where: { $0.id == sid }),
                let instrument = (instrumentsBySession[sid] ?? []).first(where: { $0.id == iid })
            {
                widget = makeInstrumentDetail(session: session, instrument: instrument)
            } else {
                widget = MainWindow.makeEmptyState(
                    icon: "applications-development-symbolic",
                    title: "Instrument unavailable",
                    subtitle: "This instrument is no longer in the store."
                )
            }
        case .package(let id):
            if let package = installedPackages.first(where: { $0.id == id }), let engine {
                let pane = PackageDetailPane(engine: engine, package: package)
                pane.onChanged = { [weak self] in
                    self?.refreshPackages()
                    self?.showToast("Updated \(package.name)")
                }
                widget = pane.widget
            } else {
                widget = MainWindow.makeEmptyState(
                    icon: "package-x-generic-symbolic",
                    title: "Package unavailable",
                    subtitle: "This package is no longer installed."
                )
            }
        }
        replaceDetail(with: widget)
        addInstrumentButton.sensitive = currentSessionID() != nil
    }

    private func currentSessionID() -> UUID? {
        switch selection {
        case .session(let id), .repl(let id):
            return id
        case .instrument(let id, _), .insight(let id, _), .itraceCapture(let id, _):
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

        if let engine {
            let editor = InstrumentConfigEditor(engine: engine, instrument: instrument)
            column.append(child: editor.widget)
            if instrument.kind == .tracer {
                currentTracerEditor = editor
            }
        }

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
        let descriptor = engine.descriptor(for: instrument)
        let title = descriptor?.displayName ?? "Instrument"
        Task { @MainActor in
            await engine.removeInstrument(instrument)
            self.refreshInstruments()
            if case .instrument(_, let id) = self.selection, id == instrument.id {
                self.select(.session(instrument.sessionID))
            } else {
                self.renderDetail()
            }
            self.showToast("Removed \(title)")
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

        let subtitle = "\(session.deviceName) · pid \(session.lastKnownPID)"
        column.append(child: makePlaceholder(title: session.processName, subtitle: subtitle))
        return column
    }

    private func makeREPLDetail(session: LumaCore.ProcessSession, engine: Engine) -> Box {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

        if SessionDetachedBanner.shouldShow(for: session) {
            let banner = SessionDetachedBanner.make(for: session) { [weak self] in
                self?.reestablishSession(id: session.id)
            }
            column.append(child: banner)
        }

        let repl = REPLPane(engine: engine, sessionID: session.id)
        column.append(child: repl.widget)
        return column
    }

    // MARK: - Instruments

    private func openAddInstrumentDialog() {
        guard let engine, let sessionID = currentSessionID() else { return }
        let dialog = AddInstrumentDialog(
            parent: window,
            engine: engine,
            sessionID: sessionID,
            descriptors: engine.descriptors
        ) { [weak self] instance in
            guard let self else { return }
            self.refreshInstruments()
            self.select(.instrument(sessionID: sessionID, instrumentID: instance.id))
            let title = engine.descriptor(for: instance)?.displayName ?? "Instrument"
            self.showToast("Added \(title)")
        }
        dialog.present()
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

    static func makeEmptyState(
        icon: String,
        title: String,
        subtitle: String,
        actionLabel: String? = nil,
        onAction: (() -> Void)? = nil
    ) -> Box {
        let outer = Box(orientation: .vertical, spacing: 0)
        outer.hexpand = true
        outer.vexpand = true
        outer.halign = .center
        outer.valign = .center

        let stack = Box(orientation: .vertical, spacing: 12)
        stack.halign = .center
        stack.valign = .center
        stack.marginStart = 24
        stack.marginEnd = 24
        stack.marginTop = 24
        stack.marginBottom = 24
        stack.add(cssClass: "luma-empty-state")

        let image = Gtk.Image(iconName: icon)
        image.pixelSize = 64
        image.halign = .center
        image.add(cssClass: "dim-label")
        stack.append(child: image)

        let titleLabel = Label(str: title)
        titleLabel.add(cssClass: "title-2")
        titleLabel.halign = .center
        stack.append(child: titleLabel)

        let subtitleLabel = Label(str: subtitle)
        subtitleLabel.add(cssClass: "dim-label")
        subtitleLabel.wrap = true
        subtitleLabel.justify = .center
        subtitleLabel.halign = .center
        subtitleLabel.setSizeRequest(width: 360, height: -1)
        stack.append(child: subtitleLabel)

        if let actionLabel, let onAction {
            let button = Button(label: actionLabel)
            button.add(cssClass: "suggested-action")
            button.add(cssClass: "pill")
            button.halign = .center
            button.marginTop = 6
            button.onClicked { _ in
                MainActor.assumeIsolated {
                    onAction()
                }
            }
            stack.append(child: button)
        }

        outer.append(child: stack)
        return outer
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

    private func navigateToHook(sessionID: UUID, instrumentID: UUID, hookID: UUID) {
        select(.instrument(sessionID: sessionID, instrumentID: instrumentID))
        currentTracerEditor?.selectTracerHook(id: hookID)
    }

    private func select(_ newValue: SidebarSelection) {
        guard selection != newValue else { return }
        selection = newValue
        switch newValue {
        case .notebook:
            sessionsList.unselectAll()
            packagesList.unselectAll()
        case .session, .repl, .instrument, .insight, .itraceCapture:
            notebookListBox.unselectAll()
            packagesList.unselectAll()
            if let idx = currentSelectionRowIndex(),
                let row = sessionsList.getRowAt(index: idx)
            {
                sessionsList.select(row: row)
            }
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
        case .session(let id), .repl(let id):
            stillExists = snapshot.contains(where: { $0.id == id })
        case .instrument(let id, _), .insight(let id, _), .itraceCapture(let id, _):
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
        insightsBySession.removeAll()
        capturesBySession.removeAll()
        for session in sessions {
            instrumentsBySession[session.id] =
                (try? engine.store.fetchInstruments(sessionID: session.id)) ?? []
            insightsBySession[session.id] =
                ((try? engine.store.fetchInsights(sessionID: session.id)) ?? [])
                .sorted { $0.createdAt < $1.createdAt }
            capturesBySession[session.id] =
                ((try? engine.store.fetchITraceCaptures(sessionID: session.id)) ?? [])
                .sorted { $0.capturedAt < $1.capturedAt }
        }
        rebuildSessionsList()
    }

    private func rebuildSessionsList() {
        sessionsList.removeAll()
        sessionsRowKinds.removeAll()
        sessionsHeaderLabel?.label = "SESSIONS (\(sessions.count))"
        sessionsEmptyHint?.visible = sessions.isEmpty
        sessionsList.visible = !sessions.isEmpty

        for session in sessions {
            let headerRow = ListBoxRow()
            let headerBox = Box(orientation: .horizontal, spacing: 8)
            headerBox.marginStart = 8
            headerBox.marginEnd = 12
            headerBox.marginTop = 4
            headerBox.marginBottom = 4

            let icon = makeSessionIcon(for: session)
            icon.pixelSize = 24
            icon.add(cssClass: "luma-session-icon")
            headerBox.append(child: icon)

            let titles = Box(orientation: .vertical, spacing: 2)
            titles.halign = .start
            titles.hexpand = true
            let nameLabel = Label(str: session.processName)
            nameLabel.halign = .start
            nameLabel.add(cssClass: "title-4")
            titles.append(child: nameLabel)
            let deviceLabel = Label(str: session.deviceName)
            deviceLabel.halign = .start
            deviceLabel.add(cssClass: "caption")
            deviceLabel.add(cssClass: "dim-label")
            titles.append(child: deviceLabel)
            headerBox.append(child: titles)

            headerRow.set(child: headerBox)
            attachSessionContextMenu(row: headerRow, anchor: headerBox, session: session)
            sessionsList.append(child: headerRow)
            sessionsRowKinds.append(.session(session.id))

            let replRow = ListBoxRow()
            let replBox = Box(orientation: .horizontal, spacing: 6)
            replBox.marginStart = 28
            replBox.marginEnd = 12
            replBox.marginTop = 2
            replBox.marginBottom = 2
            let replIcon = Gtk.Image(iconName: "utilities-terminal-symbolic")
            replIcon.pixelSize = 16
            replBox.append(child: replIcon)
            let replLabel = Label(str: "REPL")
            replLabel.halign = .start
            replBox.append(child: replLabel)
            replRow.set(child: replBox)
            sessionsList.append(child: replRow)
            sessionsRowKinds.append(.repl(session.id))

            for instrument in instrumentsBySession[session.id] ?? [] {
                let irow = ListBoxRow()
                let descriptor = engine?.descriptor(for: instrument)
                let title = descriptor?.displayName ?? "Instrument"
                let rowBox = Box(orientation: .horizontal, spacing: 6)
                rowBox.halign = .start
                rowBox.marginStart = 28
                rowBox.marginEnd = 12
                rowBox.marginTop = 2
                rowBox.marginBottom = 2
                if let descriptor {
                    let iconBox = InstrumentIconView.make(for: descriptor)
                    rowBox.append(child: iconBox)
                }
                let ilabel = Label(str: title)
                ilabel.halign = .start
                if !instrument.isEnabled {
                    ilabel.add(cssClass: "dim-label")
                }
                rowBox.append(child: ilabel)
                irow.set(child: rowBox)
                attachInstrumentContextMenu(row: irow, anchor: rowBox, instrument: instrument)
                sessionsList.append(child: irow)
                sessionsRowKinds.append(.instrument(sessionID: session.id, instrumentID: instrument.id))
            }

            for insight in insightsBySession[session.id] ?? [] {
                let irow = ListBoxRow()
                let rowBox = Box(orientation: .horizontal, spacing: 6)
                rowBox.halign = .start
                rowBox.marginStart = 28
                rowBox.marginEnd = 12
                rowBox.marginTop = 2
                rowBox.marginBottom = 2
                let iconName = insight.kind == .memory
                    ? "text-x-generic-symbolic"
                    : "applications-engineering-symbolic"
                let iconImage = Gtk.Image(iconName: iconName)
                iconImage.pixelSize = 16
                rowBox.append(child: iconImage)
                let lbl = Label(str: insight.title)
                lbl.halign = .start
                rowBox.append(child: lbl)
                irow.set(child: rowBox)
                attachInsightContextMenu(row: irow, anchor: rowBox, insight: insight)
                sessionsList.append(child: irow)
                sessionsRowKinds.append(.insight(sessionID: session.id, insightID: insight.id))
            }

            for capture in capturesBySession[session.id] ?? [] {
                let crow = ListBoxRow()
                let rowBox = Box(orientation: .horizontal, spacing: 6)
                rowBox.halign = .start
                rowBox.marginStart = 28
                rowBox.marginEnd = 12
                rowBox.marginTop = 2
                rowBox.marginBottom = 2
                let iconImage = Gtk.Image(iconName: "audio-x-generic-symbolic")
                iconImage.pixelSize = 16
                rowBox.append(child: iconImage)
                let lbl = Label(str: capture.displayName)
                lbl.halign = .start
                rowBox.append(child: lbl)
                crow.set(child: rowBox)
                attachCaptureContextMenu(row: crow, anchor: rowBox, capture: capture)
                sessionsList.append(child: crow)
                sessionsRowKinds.append(.itraceCapture(sessionID: session.id, captureID: capture.id))
            }
        }

        if let idx = currentSelectionRowIndex(),
            let row = sessionsList.getRowAt(index: idx)
        {
            sessionsList.select(row: row)
        }
    }

    private func makeSessionIcon(for session: LumaCore.ProcessSession) -> Gtk.Image {
        if let data = session.iconPNGData {
            let url: URL
            if let cached = sessionIconTempFiles[session.id] {
                url = cached
            } else {
                let dir = URL(fileURLWithPath: "/tmp/luma-icons", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = dir.appendingPathComponent("\(session.id.uuidString).png")
                try? data.write(to: target)
                sessionIconTempFiles[session.id] = target
                url = target
            }
            return Gtk.Image(file: url.path)
        }
        return Gtk.Image(iconName: "application-x-executable-symbolic")
    }

    // MARK: - Sidebar context menus

    private func attachSessionContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        session: LumaCore.ProcessSession
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, weak anchor] _, _, _, _ in
            MainActor.assumeIsolated {
                guard let self, let anchor else { return }
                self.presentSessionContextMenu(anchor: anchor, session: session)
            }
        }
        row.add(controller: click)
    }

    private func presentSessionContextMenu(anchor: Widget, session: LumaCore.ProcessSession) {
        let popover = Popover()
        popover.autohide = true

        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let node = engine?.node(forSessionID: session.id)
        if node != nil {
            let killButton = Button(label: "Kill Process")
            killButton.add(cssClass: "flat")
            killButton.add(cssClass: "destructive-action")
            killButton.onClicked { [weak self, weak popover] _ in
                MainActor.assumeIsolated {
                    popover?.popdown()
                    self?.confirmKillProcess(session: session)
                }
            }
            box.append(child: killButton)

            let detachButton = Button(label: "Detach Session")
            detachButton.add(cssClass: "flat")
            detachButton.onClicked { [weak self, weak popover] _ in
                MainActor.assumeIsolated {
                    popover?.popdown()
                    if let node = self?.engine?.node(forSessionID: session.id) {
                        self?.engine?.removeNode(node)
                        self?.showToast("Detached \(session.processName)")
                    }
                }
            }
            box.append(child: detachButton)
        } else {
            let reButton = Button(label: "Reestablish…")
            reButton.add(cssClass: "flat")
            reButton.onClicked { [weak self, weak popover] _ in
                MainActor.assumeIsolated {
                    popover?.popdown()
                    self?.reestablishSession(id: session.id)
                }
            }
            box.append(child: reButton)
        }

        box.append(child: Separator(orientation: .horizontal))

        let deleteButton = Button(label: "Delete Session")
        deleteButton.add(cssClass: "flat")
        deleteButton.add(cssClass: "destructive-action")
        deleteButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                popover?.popdown()
                self?.confirmDeleteSession(session)
            }
        }
        box.append(child: deleteButton)

        popover.set(child: box)
        popover.set(parent: anchor)
        popover.popup()
    }

    private func attachInstrumentContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        instrument: LumaCore.InstrumentInstance
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, weak anchor] _, _, _, _ in
            MainActor.assumeIsolated {
                guard let self, let anchor else { return }
                self.presentInstrumentContextMenu(anchor: anchor, instrument: instrument)
            }
        }
        row.add(controller: click)
    }

    private func presentInstrumentContextMenu(
        anchor: Widget,
        instrument: LumaCore.InstrumentInstance
    ) {
        let popover = Popover()
        popover.autohide = true
        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let toggleLabel = instrument.isEnabled ? "Disable" : "Enable"
        let toggleButton = Button(label: toggleLabel)
        toggleButton.add(cssClass: "flat")
        toggleButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                popover?.popdown()
                self?.toggleInstrument(instrument)
            }
        }
        box.append(child: toggleButton)

        box.append(child: Separator(orientation: .horizontal))

        let deleteButton = Button(label: "Delete Instrument")
        deleteButton.add(cssClass: "flat")
        deleteButton.add(cssClass: "destructive-action")
        deleteButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                popover?.popdown()
                self?.confirmDeleteInstrument(instrument)
            }
        }
        box.append(child: deleteButton)

        popover.set(child: box)
        popover.set(parent: anchor)
        popover.popup()
    }

    private func attachInsightContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        insight: LumaCore.AddressInsight
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, weak anchor] _, _, _, _ in
            MainActor.assumeIsolated {
                guard let self, let anchor else { return }
                self.presentInsightContextMenu(anchor: anchor, insight: insight)
            }
        }
        row.add(controller: click)
    }

    private func presentInsightContextMenu(
        anchor: Widget,
        insight: LumaCore.AddressInsight
    ) {
        let popover = Popover()
        popover.autohide = true
        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let deleteButton = Button(label: "Delete Insight")
        deleteButton.add(cssClass: "flat")
        deleteButton.add(cssClass: "destructive-action")
        deleteButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                popover?.popdown()
                self?.confirmDeleteInsight(insight)
            }
        }
        box.append(child: deleteButton)

        popover.set(child: box)
        popover.set(parent: anchor)
        popover.popup()
    }

    private func attachCaptureContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        capture: LumaCore.ITraceCaptureRecord
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, weak anchor] _, _, _, _ in
            MainActor.assumeIsolated {
                guard let self, let anchor else { return }
                self.presentCaptureContextMenu(anchor: anchor, capture: capture)
            }
        }
        row.add(controller: click)
    }

    private func presentCaptureContextMenu(
        anchor: Widget,
        capture: LumaCore.ITraceCaptureRecord
    ) {
        let popover = Popover()
        popover.autohide = true
        let box = Box(orientation: .vertical, spacing: 2)
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let deleteButton = Button(label: "Delete Capture")
        deleteButton.add(cssClass: "flat")
        deleteButton.add(cssClass: "destructive-action")
        deleteButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                popover?.popdown()
                self?.confirmDeleteCapture(capture)
            }
        }
        box.append(child: deleteButton)

        popover.set(child: box)
        popover.set(parent: anchor)
        popover.popup()
    }

    // MARK: - Destructive confirmation helpers

    private func confirmKillProcess(session: LumaCore.ProcessSession) {
        confirmDestructive(
            message: "Kill \(session.processName)?",
            detail: "This will force-terminate the process. Any unsaved work in the target will be lost.",
            destructiveLabel: "Kill"
        ) { [weak self] in
            guard let self, let node = self.engine?.node(forSessionID: session.id) else { return }
            let pid = session.lastKnownPID
            let device = node.device
            Task { @MainActor in
                do {
                    try await device.kill(pid)
                    self.showToast("Killed \(session.processName)")
                } catch {
                    self.showToast("Kill failed: \(error)")
                }
            }
        }
    }

    private func confirmDeleteSession(_ session: LumaCore.ProcessSession) {
        confirmDestructive(
            message: "Delete session “\(session.processName)”?",
            detail: "This removes the session and its history from the project.",
            destructiveLabel: "Delete"
        ) { [weak self] in
            guard let self else { return }
            if let node = self.engine?.node(forSessionID: session.id) {
                self.engine?.removeNode(node)
            }
            try? self.engine?.store.deleteSession(id: session.id)
            if self.currentSessionID() == session.id {
                self.select(.notebook)
                self.notebookListBox.select(row: self.notebookRow)
            }
            self.refreshInstruments()
            self.showToast("Deleted \(session.processName)")
        }
    }

    private func confirmDeleteInstrument(_ instrument: LumaCore.InstrumentInstance) {
        let title = engine?.descriptor(for: instrument)?.displayName ?? "Instrument"
        confirmDestructive(
            message: "Delete instrument “\(title)”?",
            detail: nil,
            destructiveLabel: "Delete"
        ) { [weak self] in
            self?.deleteInstrument(instrument)
        }
    }

    private func confirmDeleteInsight(_ insight: LumaCore.AddressInsight) {
        confirmDestructive(
            message: "Delete insight “\(insight.title)”?",
            detail: nil,
            destructiveLabel: "Delete"
        ) { [weak self] in
            guard let self else { return }
            try? self.engine?.store.deleteInsight(id: insight.id)
            if case .insight(_, let id) = self.selection, id == insight.id {
                self.select(.repl(insight.sessionID))
            }
            self.refreshInstruments()
            self.showToast("Deleted insight")
        }
    }

    private func confirmDeleteCapture(_ capture: LumaCore.ITraceCaptureRecord) {
        confirmDestructive(
            message: "Delete capture “\(capture.displayName)”?",
            detail: "This removes the recorded ITrace data from the project.",
            destructiveLabel: "Delete"
        ) { [weak self] in
            guard let self else { return }
            try? self.engine?.store.deleteCapture(id: capture.id)
            if case .itraceCapture(_, let id) = self.selection, id == capture.id {
                self.select(.repl(capture.sessionID))
            }
            self.refreshInstruments()
            self.showToast("Deleted capture")
        }
    }

    private func confirmDestructive(
        message: String,
        detail: String?,
        destructiveLabel: String,
        action: @escaping () -> Void
    ) {
        guard let parentPtr = window.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let box = ConfirmCallbackBox(action: action)
        let context = Unmanaged.passRetained(box).toOpaque()
        message.withCString { messageCstr in
            destructiveLabel.withCString { labelCstr in
                if let detail {
                    detail.withCString { detailCstr in
                        luma_alert_confirm(parentPtr, messageCstr, detailCstr, labelCstr, lumaConfirmThunk, context)
                    }
                } else {
                    luma_alert_confirm(parentPtr, messageCstr, nil, labelCstr, lumaConfirmThunk, context)
                }
            }
        }
    }

    private func currentSelectionRowIndex() -> Int? {
        switch selection {
        case .session(let id):
            return sessionsRowKinds.firstIndex {
                if case .session(let s) = $0 { return s == id }
                return false
            }
        case .repl(let id):
            return sessionsRowKinds.firstIndex {
                if case .repl(let s) = $0 { return s == id }
                return false
            }
        case .instrument(_, let id):
            return sessionsRowKinds.firstIndex {
                if case .instrument(_, let i) = $0 { return i == id }
                return false
            }
        case .insight(_, let id):
            return sessionsRowKinds.firstIndex {
                if case .insight(_, let i) = $0 { return i == id }
                return false
            }
        case .itraceCapture(_, let id):
            return sessionsRowKinds.firstIndex {
                if case .itraceCapture(_, let c) = $0 { return c == id }
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
        packagesHeaderLabel?.label = "PACKAGES (\(snapshot.count))"
        packagesEmptyHint?.visible = snapshot.isEmpty
        packagesList.visible = !snapshot.isEmpty
    }

    private func openPackageSearch(anchor: Button) {
        guard let engine else { return }
        PackageSearchDialog.present(from: anchor, engine: engine) { [weak self] in
            self?.refreshPackages()
            self?.showToast("Package installed")
        }
    }

    private func refreshPackages() {
        guard let engine else { return }
        let snapshot = (try? engine.store.fetchPackagesState())?.packages ?? []
        renderPackages(snapshot)
        if case .package(let id) = selection, !snapshot.contains(where: { $0.id == id }) {
            select(.notebook)
            notebookListBox.select(row: notebookRow)
        } else {
            renderDetail()
        }
    }
}

private final class ConfirmCallbackBox {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
}

private let lumaConfirmThunk: @convention(c) (
    Int32, UnsafeMutableRawPointer?
) -> Void = { confirmed, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let box = Unmanaged<ConfirmCallbackBox>.fromOpaque(ptr).takeRetainedValue()
        if confirmed != 0 {
            box.action()
        }
    }
}
