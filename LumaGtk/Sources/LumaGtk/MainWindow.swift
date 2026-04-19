import Adw
import CLuma
import Foundation
import Frida
import Gtk
import LumaCore
import Observation

@MainActor
final class MainWindow {
    private let app: Gtk.Application
    private weak var application: LumaApplication?
    let window: Adw.ApplicationWindow
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
    private var currentInstrumentDetail: InstrumentDetailPane?
    private var currentREPLPane: REPLPane?
    private var currentREPLSessionID: UUID?
    private var currentInsightDetail: InsightDetailView?
    private var currentInsightID: UUID?
    private var currentITraceDetail: ITraceDetailView?
    private var currentITraceCaptureID: UUID?
    private(set) lazy var sharedTracerEditor: MonacoEditor = makeSharedTracerEditor()
    private(set) lazy var sharedCodeShareEditor: MonacoEditor = makeSharedCodeShareEditor()

    private var sessions: [LumaCore.ProcessSession] = []
    private var installedPackages: [LumaCore.InstalledPackage] = []
    private var instrumentsBySession: [UUID: [LumaCore.InstrumentInstance]] = [:]
    private var insightsBySession: [UUID: [LumaCore.AddressInsight]] = [:]
    private var capturesBySession: [UUID: [LumaCore.ITraceCaptureRecord]] = [:]
    private var sessionsRowKinds: [SessionsRow] = []
    private var sessionNameLabels: [UUID: Label] = [:]
    private var sessionDeviceLabels: [UUID: Label] = [:]
    private var selection: SidebarSelection = .notebook
    private var addInstrumentButton: Button!
    private var resumeProcessButton: Button!
    private var installPackageButton: Button!
    private var collaborationButton: Button!
    private var collaborationPanel: CollaborationPanel?
    private let outerPaned: Paned
    private var splitView: Adw.NavigationSplitView!
    private var eventStreamPaned: Paned!
    private var eventStreamHost: Box!
    private var detailHost: Widget!
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

    private enum SessionsRow: Equatable {
        case session(UUID)
        case repl(UUID)
        case instrument(sessionID: UUID, instrumentID: UUID)
        case insight(sessionID: UUID, insightID: UUID)
        case itraceCapture(sessionID: UUID, captureID: UUID)

        var sessionID: UUID {
            switch self {
            case .session(let id), .repl(let id): return id
            case .instrument(let id, _), .insight(let id, _), .itraceCapture(let id, _): return id
            }
        }
    }

    init(app: Gtk.Application, application: LumaApplication, document: LumaDocument) {
        self.app = app
        self.application = application
        self.document = document
        self.window = Adw.ApplicationWindow(app: app)
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

        let header = Adw.HeaderBar()
        let newSessionButton = Button(label: "New Session…")
        newSessionButton.add(cssClass: "suggested-action")
        header.packStart(child: newSessionButton)

        let addInstrumentButton = Button(label: "Add Instrument…")
        addInstrumentButton.sensitive = false
        header.packStart(child: addInstrumentButton)
        self.addInstrumentButton = addInstrumentButton

        let resumeProcessButton = Button(label: "Resume Process")
        resumeProcessButton.set(iconName: "media-playback-start-symbolic")
        resumeProcessButton.tooltipText = "Resume spawned process"
        resumeProcessButton.visible = false
        header.packStart(child: resumeProcessButton)
        self.resumeProcessButton = resumeProcessButton

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

        let sidebar = buildSidebar()
        let detail = buildDetailPane()
        let sidebarPage = "Luma".withCString { Adw.NavigationPage(child: sidebar, title: $0) }
        let contentPage = "Detail".withCString { Adw.NavigationPage(child: detail, title: $0) }
        let splitView = Adw.NavigationSplitView()
        splitView.set(sidebar: sidebarPage)
        splitView.set(content: contentPage)
        splitView.setMinSidebar(width: 240)
        splitView.setMaxSidebar(width: 400)
        splitView.hexpand = true
        splitView.vexpand = true
        self.splitView = splitView

        outerPaned.position = state.collaborationSashPosition
        outerPaned.startChild = WidgetRef(splitView)
        outerPaned.hexpand = true
        outerPaned.vexpand = true

        let eventStreamPaned = Paned(orientation: .vertical)
        eventStreamPaned.resizeStartChild = true
        eventStreamPaned.resizeEndChild = true
        eventStreamPaned.shrinkStartChild = false
        eventStreamPaned.shrinkEndChild = false
        eventStreamPaned.hexpand = true
        eventStreamPaned.vexpand = true
        self.eventStreamPaned = eventStreamPaned
        self.detailHost = outerPaned

        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true
        self.eventStreamHost = column
        eventStreamPane.setInitialCollapsed(LumaState.shared.eventStreamCollapsed)
        applyEventStreamLayout()

        eventStreamPane.onCollapsedChanged = { [weak self] _ in
            self?.applyEventStreamLayout()
        }
        let toastOverlay = ToastOverlay(content: column)
        self.toastOverlay = toastOverlay

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: toastOverlay.widget)
        window.set(content: toolbarView)

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
        resumeProcessButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeProcess()
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

        let closeHandler: (Gtk.WindowRef) -> Bool = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persistWindowState()
                self.application?.windowDidClose(self)
            }
            return false
        }
        window.onCloseRequest(handler: closeHandler)
    }

    func toggleCollaboration() {
        setCollaborationVisible(!isCollaborationPanelVisible)
    }

    func resumeProcess() {
        guard let engine, let sessionID = currentSessionID(),
              let node = engine.node(forSessionID: sessionID),
              let session = try? engine.store.fetchSession(id: sessionID),
              session.phase == .awaitingInitialResume
        else { return }
        Task { @MainActor in
            await engine.resumeSpawnedProcess(node: node)
        }
    }

    private func updateResumeButtonVisibility() {
        guard let sessionID = currentSessionID(),
            let session = sessions.first(where: { $0.id == sessionID })
        else {
            resumeProcessButton.visible = false
            return
        }
        resumeProcessButton.visible = session.phase == .awaitingInitialResume
    }

    private func setCollaborationVisible(_ visible: Bool) {
        isCollaborationPanelVisible = visible
        collaborationPanel?.widget.visible = visible
    }

    func present() {
        window.present()
        renderDetail()
    }

    func showToast(_ message: String, durationSeconds: Double = 3.0) {
        toastOverlay?.show(message, durationSeconds: durationSeconds)
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
        let eventStreamSash: Int?
        if eventStreamPane.collapsed {
            eventStreamSash = nil
        } else {
            eventStreamSash = Int(eventStreamPaned.position)
        }
        state.saveSashes(
            collaboration: Int(outerPaned.position),
            eventStream: eventStreamSash,
            eventStreamCollapsed: eventStreamPane.collapsed
        )
    }

    private func applyEventStreamLayout() {
        let host = eventStreamHost!
        var c = host.firstChild
        while let cur = c {
            c = cur.nextSibling
            host.remove(child: cur)
        }
        // Detach children from any prior parent (Paned holds raw refs).
        let detail = detailHost!
        let stream = eventStreamPane.widget
        eventStreamPaned.startChild = nil
        eventStreamPaned.endChild = nil

        if eventStreamPane.collapsed {
            host.append(child: detail)
            host.append(child: stream)
        } else {
            eventStreamPaned.startChild = WidgetRef(detail)
            eventStreamPaned.endChild = WidgetRef(stream)
            var totalHeight = Int(eventStreamPaned.allocatedHeight)
            if totalHeight <= 0 {
                totalHeight = LumaState.shared.windowHeight
            }
            let saved = LumaState.shared.eventStreamSashPosition
            let defaultPosition = max(0, (totalHeight * 3) / 4)
            eventStreamPaned.position = Int(saved ?? defaultPosition)
            host.append(child: eventStreamPaned)
        }
    }


    func attach(engine: Engine) {
        self.engine = engine
        engine.onSessionListChanged = { [weak self] change in self?.handleSessionListChange(change) }
        engine.onREPLCellAdded = { [weak self] cell in self?.currentREPLPane?.appendCell(cell) }
        engine.onNotebookChanged = { [weak self] change in self?.notebookPane?.handleNotebookChange(change) }
        engine.onInstalledPackagesChanged = { [weak self] packages in self?.renderPackages(packages) }
        engine.populateSessionList()
        renderPackages(engine.installedPackages)
        eventStreamPane.attach(engine: engine)
        eventStreamPane.onNavigateToHook = { [weak self] sessionID, instrumentID, hookID in
            self?.navigateToHook(sessionID: sessionID, instrumentID: instrumentID, hookID: hookID)
        }
        AddressActionMenu.navigator = { [weak self] sessionID, insightID in
            guard let self else { return }
            self.select(.insight(sessionID: sessionID, insightID: insightID))
        }
        AddressActionMenu.errorReporter = { [weak self] message in
            self?.showToast(message)
        }
        InsightDetailView.copyFeedback = { [weak self] message in
            self?.showToast(message, durationSeconds: 1.0)
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

    func newSession() {
        openTargetPicker()
    }

    private func openTargetPicker(reusing existing: LumaCore.ProcessSession? = nil, reason: String? = nil) {
        guard let engine else { return }
        let picker = TargetPicker(
            parent: window,
            engine: engine,
            reason: reason,
            onAttach: { [weak self] device, process in
                self?.attach(device: device, process: process, reusing: existing)
            },
            onSpawn: { [weak self] device, config in
                self?.spawn(device: device, config: config, reusing: existing)
            }
        )
        picker.present()
    }

    private func spawn(
        device: Frida.Device,
        config: SpawnConfig,
        reusing existing: LumaCore.ProcessSession? = nil
    ) {
        guard let engine else { return }
        var session = existing ?? LumaCore.ProcessSession(
            kind: .spawn(config),
            deviceID: device.id,
            deviceName: device.name,
            processName: config.defaultDisplayName,
            lastKnownPID: 0
        )
        session.kind = .spawn(config)
        session.deviceID = device.id
        session.deviceName = device.name
        session.processName = config.defaultDisplayName
        if existing != nil {
            engine.updateSession(id: session.id) { s in s = session }
        } else {
            engine.createSession(session)
        }
        select(.repl(session.id))
        Task { @MainActor in
            await engine.spawnAndAttach(device: device, session: session)
            self.refreshAfterAttach(sessionID: session.id)
        }
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
        if existing != nil {
            engine.updateSession(id: session.id) { s in s = session }
        } else {
            engine.createSession(session)
        }
        select(.repl(session.id))
        Task { @MainActor in
            await engine.attach(device: device, process: process, session: session)
            self.refreshAfterAttach(sessionID: session.id)
        }
    }

    private func refreshAfterAttach(sessionID: UUID) {
        Task { @MainActor in
            guard currentREPLSessionID == sessionID, let pane = currentREPLPane else { return }
            pane.focusInput()
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
        headerLabel.add(cssClass: "caption-heading")
        headerLabel.add(cssClass: "dim-label")
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
        headerLabel.add(cssClass: "caption-heading")
        headerLabel.add(cssClass: "dim-label")
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

    private func reclaimSharedEditors() {
        for editor in [sharedTracerEditor, sharedCodeShareEditor] {
            if editor.widget.parent != nil {
                editor.widget.unparent()
            }
        }
    }

    private func renderDetail() {
        if case .repl(let id) = selection {
            if currentREPLSessionID != id {
                currentREPLPane = nil
                currentREPLSessionID = nil
            }
        } else {
            currentREPLPane = nil
            currentREPLSessionID = nil
        }
        if case .instrument(_, let iid) = selection {
            if currentInstrumentDetail?.instrumentID != iid {
                reclaimSharedEditors()
                currentInstrumentDetail = nil
            }
        } else {
            reclaimSharedEditors()
            currentInstrumentDetail = nil
        }
        if case .insight(_, let iid) = selection {
            if currentInsightID != iid {
                currentInsightDetail = nil
                currentInsightID = nil
            }
        } else {
            currentInsightDetail = nil
            currentInsightID = nil
        }
        if case .itraceCapture(_, let cid) = selection {
            if currentITraceCaptureID != cid {
                currentITraceDetail = nil
                currentITraceCaptureID = nil
            }
        } else {
            currentITraceDetail = nil
            currentITraceCaptureID = nil
        }
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
            let session = sessions.first(where: { $0.id == sid })
            if let insight, let engine, let session {
                let detail: InsightDetailView
                if let existing = currentInsightDetail, currentInsightID == iid {
                    existing.applySessionState()
                    detail = existing
                } else {
                    detail = InsightDetailView(engine: engine, session: session, insight: insight, owner: self)
                    currentInsightDetail = detail
                    currentInsightID = iid
                }
                widget = detail.widget
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
                let detail: ITraceDetailView
                if let existing = currentITraceDetail, currentITraceCaptureID == cid {
                    detail = existing
                } else {
                    let others = allCaptures.filter { $0.id != cid }
                    detail = ITraceDetailView(
                        capture: capture,
                        otherCaptures: others,
                        engine: engine,
                        sessionID: sid
                    )
                    currentITraceDetail = detail
                    currentITraceCaptureID = cid
                }
                widget = detail.widget
            } else {
                widget = MainWindow.makeEmptyState(
                    icon: "system-run-symbolic",
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
    ) -> Widget {
        guard let engine else {
            return MainWindow.makeEmptyState(
                icon: "applications-development-symbolic",
                title: "Instrument unavailable",
                subtitle: "Engine is not attached."
            )
        }
        if let existing = currentInstrumentDetail, existing.instrumentID == instrument.id {
            existing.applySessionState()
            return existing.widget
        }
        let pane = InstrumentDetailPane(
            engine: engine,
            session: session,
            instrument: instrument,
            owner: self,
            tracerEditor: sharedTracerEditor
        )
        currentInstrumentDetail = pane
        return pane.widget
    }

    private func toggleInstrument(_ instrument: LumaCore.InstrumentInstance) {
        guard let engine else { return }
        Task { @MainActor in
            await engine.setInstrumentEnabled(instrument, enabled: !instrument.isEnabled)
            self.renderDetail()
        }
    }

    private func deleteInstrument(_ instrument: LumaCore.InstrumentInstance) {
        guard let engine else { return }
        let descriptor = engine.descriptor(for: instrument)
        let title = descriptor?.displayName ?? "Instrument"
        Task { @MainActor in
            await engine.removeInstrument(instrument)
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

        let repl = REPLPane(engine: engine, sessionID: session.id, owner: self)
        currentREPLPane = repl
        currentREPLSessionID = session.id
        column.append(child: repl.widget)
        Task { @MainActor [weak self] in
            guard let self, self.currentREPLPane === repl else { return }
            repl.focusInput()
        }
        return column
    }

    // MARK: - Instruments

    func addInstrument() {
        openAddInstrumentDialog()
    }

    private func openAddInstrumentDialog() {
        guard let engine, let sessionID = currentSessionID() else { return }
        let existing = (try? engine.store.fetchInstruments(sessionID: sessionID)) ?? []
        let disabledDescriptorIDs = Set(existing.compactMap { engine.descriptor(for: $0)?.id })
        let dialog = AddInstrumentDialog(
            parent: window,
            engine: engine,
            sessionID: sessionID,
            descriptors: engine.descriptors,
            disabledDescriptorIDs: disabledDescriptorIDs,
            tracerEditor: sharedTracerEditor,
            codeShareEditor: sharedCodeShareEditor
        ) { [weak self] instance in
            guard let self else { return }
            self.select(.instrument(sessionID: sessionID, instrumentID: instance.id))
            let title = engine.descriptor(for: instance)?.displayName ?? "Instrument"
            self.showToast("Added \(title)")
        }
        dialog.present()
    }

    func reestablishSession(id: UUID) {
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
    ) -> Adw.StatusPage {
        let page = Adw.StatusPage()
        page.hexpand = true
        page.vexpand = true
        icon.withCString { page.set(iconName: $0) }
        title.withCString { page.set(title: $0) }
        subtitle.withCString { page.set(description: $0) }

        if let actionLabel, let onAction {
            let button = Button(label: actionLabel)
            button.add(cssClass: "suggested-action")
            button.add(cssClass: "pill")
            button.halign = .center
            button.onClicked { _ in
                MainActor.assumeIsolated { onAction() }
            }
            page.set(child: button)
        }

        return page
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
        currentInstrumentDetail?.selectTracerHook(id: hookID)
    }

    func navigate(to target: LumaCore.NavigationTarget) {
        switch target {
        case .instrumentComponent(let sessionID, let instrumentID, let componentID):
            navigateToHook(sessionID: sessionID, instrumentID: instrumentID, hookID: componentID)
        }
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
        updateResumeButtonVisibility()
        renderDetail()
    }

    // MARK: - Engine bindings

    private func handleSessionListChange(_ change: LumaCore.SessionListChange) {
        switch change {
        case .sessionAdded(let session):
            sessions.insert(session, at: 0)
            insertSessionRows(session, at: 0)
        case .sessionUpdated(let session):
            if let i = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[i] = session
            }
            sessionNameLabels[session.id]?.label = session.processName
            sessionDeviceLabels[session.id]?.label = session.deviceName
            if currentREPLSessionID == session.id {
                currentREPLPane?.applySessionState()
            }
            currentInstrumentDetail?.applySessionState()
            currentInsightDetail?.applySessionState()
            updateResumeButtonVisibility()
        case .sessionRemoved(let id):
            removeSessionRows(id)
            sessions.removeAll { $0.id == id }
            instrumentsBySession.removeValue(forKey: id)
            insightsBySession.removeValue(forKey: id)
            capturesBySession.removeValue(forKey: id)
            sessionNameLabels.removeValue(forKey: id)
            sessionDeviceLabels.removeValue(forKey: id)
            switch selection {
            case .session(let sid), .repl(let sid), .instrument(let sid, _), .insight(let sid, _), .itraceCapture(let sid, _):
                if sid == id {
                    select(.notebook)
                    notebookListBox.select(row: notebookRow)
                }
            default: break
            }
        case .instrumentAdded(let instrument):
            instrumentsBySession[instrument.sessionID, default: []].append(instrument)
            insertChildRow(makeInstrumentRow(instrument), kind: .instrument(sessionID: instrument.sessionID, instrumentID: instrument.id), sessionID: instrument.sessionID)
        case .instrumentUpdated(let instrument):
            if let arr = instrumentsBySession[instrument.sessionID],
                let i = arr.firstIndex(where: { $0.id == instrument.id })
            {
                instrumentsBySession[instrument.sessionID]![i] = instrument
            }
        case .instrumentRemoved(let id, let sessionID):
            instrumentsBySession[sessionID]?.removeAll { $0.id == id }
            removeChildRow(kind: .instrument(sessionID: sessionID, instrumentID: id))
        case .insightAdded(let insight):
            insightsBySession[insight.sessionID, default: []].append(insight)
            insertChildRow(makeInsightRow(insight), kind: .insight(sessionID: insight.sessionID, insightID: insight.id), sessionID: insight.sessionID)
        case .insightRemoved(let id, let sessionID):
            insightsBySession[sessionID]?.removeAll { $0.id == id }
            removeChildRow(kind: .insight(sessionID: sessionID, insightID: id))
            if case .insight(_, let iid) = selection, iid == id {
                select(.repl(sessionID))
            }
        case .captureAdded(let capture):
            capturesBySession[capture.sessionID, default: []].append(capture)
            insertChildRow(makeCaptureRow(capture), kind: .itraceCapture(sessionID: capture.sessionID, captureID: capture.id), sessionID: capture.sessionID)
        case .captureRemoved(let id, let sessionID):
            capturesBySession[sessionID]?.removeAll { $0.id == id }
            removeChildRow(kind: .itraceCapture(sessionID: sessionID, captureID: id))
            if case .itraceCapture(_, let cid) = selection, cid == id {
                select(.repl(sessionID))
            }
        }
        sessionsHeaderLabel?.label = "SESSIONS (\(sessions.count))"
        sessionsEmptyHint?.visible = sessions.isEmpty
        sessionsList.visible = !sessions.isEmpty
    }

    private func insertSessionRows(_ session: LumaCore.ProcessSession, at sessionIndex: Int) {
        var pos = 0
        for i in 0..<sessionIndex {
            pos += rowCount(forSessionID: sessions[i].id)
        }

        let headerRow = ListBoxRow()
        let headerBox = Box(orientation: .horizontal, spacing: 8)
        headerBox.marginStart = 8
        headerBox.marginEnd = 12
        headerBox.marginTop = 4
        headerBox.marginBottom = 4

        let icon = makeSessionIcon(for: session, node: engine?.node(forSessionID: session.id))
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
        sessionNameLabels[session.id] = nameLabel
        sessionDeviceLabels[session.id] = deviceLabel

        headerRow.set(child: headerBox)
        attachSessionContextMenu(row: headerRow, anchor: headerBox, session: session)
        sessionsList.insert(child: headerRow, position: pos)
        sessionsRowKinds.insert(.session(session.id), at: pos)

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
        sessionsList.insert(child: replRow, position: pos + 1)
        sessionsRowKinds.insert(.repl(session.id), at: pos + 1)
    }

    private func removeSessionRows(_ sessionID: UUID) {
        if let rootPtr = sessionsList.root?.ptr {
            Gtk.WindowRef(raw: rootPtr).focus = nil
        }
        while let idx = sessionsRowKinds.firstIndex(where: { $0.sessionID == sessionID }) {
            if let row = sessionsList.getRowAt(index: idx) {
                sessionsList.remove(child: row)
            }
            sessionsRowKinds.remove(at: idx)
        }
    }

    private func insertChildRow(_ row: ListBoxRow, kind: SessionsRow, sessionID: UUID) {
        let pos = insertPosition(for: kind, sessionID: sessionID)
        sessionsList.insert(child: row, position: pos)
        sessionsRowKinds.insert(kind, at: pos)
    }

    private func removeChildRow(kind: SessionsRow) {
        guard let idx = sessionsRowKinds.firstIndex(where: { $0 == kind }) else { return }
        if let row = sessionsList.getRowAt(index: idx) {
            sessionsList.remove(child: row)
        }
        sessionsRowKinds.remove(at: idx)
    }

    private func rowCount(forSessionID id: UUID) -> Int {
        sessionsRowKinds.filter { $0.sessionID == id }.count
    }

    private func insertPosition(for kind: SessionsRow, sessionID: UUID) -> Int {
        guard let start = sessionsRowKinds.firstIndex(where: { if case .session(let id) = $0 { return id == sessionID }; return false }) else {
            return sessionsRowKinds.count
        }
        let kindOrder: (SessionsRow) -> Int = { k in
            switch k {
            case .session: return 0
            case .repl: return 1
            case .instrument: return 2
            case .insight: return 3
            case .itraceCapture: return 4
            }
        }
        let target = kindOrder(kind)
        var pos = start + 1
        while pos < sessionsRowKinds.count {
            let existing = sessionsRowKinds[pos]
            guard existing.sessionID == sessionID else { break }
            if kindOrder(existing) > target { break }
            pos += 1
        }
        return pos
    }

    private func makeInstrumentRow(_ instrument: LumaCore.InstrumentInstance) -> ListBoxRow {
        let row = ListBoxRow()
        let descriptor = engine?.descriptor(for: instrument)
        let title = descriptor?.displayName ?? "Instrument"
        let rowBox = Box(orientation: .horizontal, spacing: 6)
        rowBox.halign = .start
        rowBox.marginStart = 28
        rowBox.marginEnd = 12
        rowBox.marginTop = 2
        rowBox.marginBottom = 2
        if let descriptor {
            rowBox.append(child: InstrumentIconView.make(for: descriptor))
        } else {
            let fallbackIcon = Gtk.Image(iconName: instrumentIconName(for: instrument.kind))
            fallbackIcon.pixelSize = 16
            rowBox.append(child: fallbackIcon)
        }
        let ilabel = Label(str: title)
        ilabel.halign = .start
        rowBox.append(child: ilabel)
        if !instrument.isEnabled {
            rowBox.opacity = 0.3
        }
        row.set(child: rowBox)
        attachInstrumentContextMenu(row: row, anchor: rowBox, instrument: instrument)
        return row
    }

    private func makeInsightRow(_ insight: LumaCore.AddressInsight) -> ListBoxRow {
        let row = ListBoxRow()
        let rowBox = Box(orientation: .horizontal, spacing: 6)
        rowBox.halign = .start
        rowBox.marginStart = 28
        rowBox.marginEnd = 12
        rowBox.marginTop = 2
        rowBox.marginBottom = 2
        let iconName = insight.kind == .memory ? "text-x-generic-symbolic" : "applications-engineering-symbolic"
        let iconImage = Gtk.Image(iconName: iconName)
        iconImage.pixelSize = 16
        rowBox.append(child: iconImage)
        let lbl = Label(str: insight.title)
        lbl.halign = .start
        rowBox.append(child: lbl)
        row.set(child: rowBox)
        attachInsightContextMenu(row: row, anchor: rowBox, insight: insight)
        return row
    }

    private func makeCaptureRow(_ capture: LumaCore.ITraceCaptureRecord) -> ListBoxRow {
        let row = ListBoxRow()
        let rowBox = Box(orientation: .horizontal, spacing: 6)
        rowBox.halign = .start
        rowBox.marginStart = 28
        rowBox.marginEnd = 12
        rowBox.marginTop = 2
        rowBox.marginBottom = 2
        let iconImage = Gtk.Image(iconName: "system-run-symbolic")
        iconImage.pixelSize = 16
        rowBox.append(child: iconImage)
        let lbl = Label(str: capture.displayName)
        lbl.halign = .start
        rowBox.append(child: lbl)
        row.set(child: rowBox)
        attachCaptureContextMenu(row: row, anchor: rowBox, capture: capture)
        return row
    }

    private func makeSessionIcon(
        for session: LumaCore.ProcessSession,
        node: LumaCore.ProcessNode?
    ) -> Gtk.Image {
        if let lastIcon = node?.process.icons.last,
            let image = IconPixbuf.makeImage(from: lastIcon, pixelSize: 24)
        {
            return image
        }
        if let data = session.iconPNGData,
            let image = IconPixbuf.makeImage(fromPNGData: data, pixelSize: 24)
        {
            return image
        }
        return Gtk.Image(iconName: "application-x-executable-symbolic")
    }

    private func instrumentIconName(for kind: LumaCore.InstrumentKind) -> String {
        switch kind {
        case .tracer: return "media-playlist-consecutive-symbolic"
        case .hookPack: return "application-x-addon-symbolic"
        case .codeShare: return "cloud-symbolic"
        }
    }

    // MARK: - Sidebar context menus

    private func attachSessionContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        session: LumaCore.ProcessSession
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentSessionContextMenu(anchor: anchor, x: x, y: y, session: session)
            }
        }
        row.install(controller: click)
    }

    private func presentSessionContextMenu(anchor: Widget, x: Double, y: Double, session: LumaCore.ProcessSession) {
        let node = engine?.node(forSessionID: session.id)
        var topSection: [ContextMenu.Item] = []
        if node != nil {
            topSection.append(.init("Kill Process", destructive: true) { [weak self] in
                self?.confirmKillProcess(session: session)
            })
            topSection.append(.init("Detach Session") { [weak self] in
                if let node = self?.engine?.node(forSessionID: session.id) {
                    self?.engine?.removeNode(node)
                    self?.showToast("Detached \(session.processName)")
                }
            })
        } else {
            topSection.append(.init("Reestablish…") { [weak self] in
                self?.reestablishSession(id: session.id)
            })
        }
        ContextMenu.present([
            topSection,
            [.init("Delete Session", destructive: true) { [weak self] in self?.confirmDeleteSession(session) }],
        ], at: anchor, x: x, y: y)
    }

    private func attachInstrumentContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        instrument: LumaCore.InstrumentInstance
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentInstrumentContextMenu(anchor: anchor, x: x, y: y, instrument: instrument)
            }
        }
        row.install(controller: click)
    }

    private func presentInstrumentContextMenu(
        anchor: Widget,
        x: Double,
        y: Double,
        instrument: LumaCore.InstrumentInstance
    ) {
        let toggleLabel = instrument.isEnabled ? "Disable" : "Enable"
        ContextMenu.present([
            [.init(toggleLabel) { [weak self] in self?.toggleInstrument(instrument) }],
            [.init("Delete Instrument", destructive: true) { [weak self] in self?.confirmDeleteInstrument(instrument) }],
        ], at: anchor, x: x, y: y)
    }

    private func attachInsightContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        insight: LumaCore.AddressInsight
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentInsightContextMenu(anchor: anchor, x: x, y: y, insight: insight)
            }
        }
        row.install(controller: click)
    }

    private func presentInsightContextMenu(
        anchor: Widget,
        x: Double,
        y: Double,
        insight: LumaCore.AddressInsight
    ) {
        ContextMenu.present([
            [.init("Delete Insight", destructive: true) { [weak self] in self?.confirmDeleteInsight(insight) }],
        ], at: anchor, x: x, y: y)
    }

    private func attachCaptureContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        capture: LumaCore.ITraceCaptureRecord
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentCaptureContextMenu(anchor: anchor, x: x, y: y, capture: capture)
            }
        }
        row.install(controller: click)
    }

    private func presentCaptureContextMenu(
        anchor: Widget,
        x: Double,
        y: Double,
        capture: LumaCore.ITraceCaptureRecord
    ) {
        ContextMenu.present([
            [.init("Delete Capture", destructive: true) { [weak self] in self?.confirmDeleteCapture(capture) }],
        ], at: anchor, x: x, y: y)
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
            self?.engine?.deleteSession(id: session.id)
            self?.showToast("Deleted \(session.processName)")
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
            message: "Delete insight \(insight.title)?",
            detail: nil,
            destructiveLabel: "Delete"
        ) { [weak self] in
            self?.engine?.deleteInsight(id: insight.id, sessionID: insight.sessionID)
            self?.showToast("Deleted insight")
        }
    }

    private func confirmDeleteCapture(_ capture: LumaCore.ITraceCaptureRecord) {
        confirmDestructive(
            message: "Delete capture \(capture.displayName)?",
            detail: "This removes the recorded ITrace data from the project.",
            destructiveLabel: "Delete"
        ) { [weak self] in
            self?.engine?.deleteCapture(id: capture.id, sessionID: capture.sessionID)
            self?.showToast("Deleted capture")
        }
    }

    private func confirmDestructive(
        message: String,
        detail: String?,
        destructiveLabel: String,
        action: @escaping () -> Void
    ) {
        let dialog = Adw.AlertDialog(heading: message, body: detail)
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "confirm", label: destructiveLabel)
        dialog.setResponseAppearance(response: "confirm", appearance: .destructive)
        dialog.setDefault(response: "cancel")
        dialog.setClose(response: "cancel")
        dialog.onResponse { _, responseID in
            MainActor.assumeIsolated {
                if responseID == "confirm" {
                    action()
                }
            }
        }
        dialog.present(parent: window)
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

    func managePackages() {
        openPackageSearch(anchor: installPackageButton)
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

    private func makeSharedTracerEditor() -> MonacoEditor {
        let installedPackages = (try? engine?.store.fetchPackagesState().packages) ?? []
        let profile = EditorProfile.fridaTracerHook(packages: installedPackages)
        let editor = MonacoEditor(profile: profile)
        if let engine {
            Task { @MainActor in
                await engine.rebuildEditorFSSnapshotIfNeeded()
                editor.setFSSnapshot(engine.editorFSSnapshot)
            }
        }
        return editor
    }

    private func makeSharedCodeShareEditor() -> MonacoEditor {
        return MonacoEditor(profile: EditorProfile.fridaCodeShare())
    }
}
