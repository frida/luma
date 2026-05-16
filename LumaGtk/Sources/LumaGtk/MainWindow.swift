import Adw
import CLuma
import Foundation
import Frida
import Gtk
import LumaCore
import Observation
import Pango

@MainActor
final class MainWindow: InstrumentUIHost {
    private let app: Gtk.Application
    private weak var application: LumaApplication?
    let window: Adw.ApplicationWindow
    private(set) var document: LumaDocument

    private var engine: Engine?

    private let sessionsList: ListBox
    private let packagesList: ListBox
    private let packagesSection: Box
    private let customInstrumentsList: ListBox = ListBox()
    private var customInstrumentsHeaderLabel: Label!
    private var customInstrumentDefs: [LumaCore.CustomInstrumentDef] = []
    private var customInstrumentRows: [CustomInstrumentRow] = []
    private var sessionsHeaderLabel: Label!
    private var packagesHeaderLabel: Label!
    private var sessionsSection: Box!
    private var customInstrumentsSection: Box!
    private var packagesSidebarSection: Box!
    private let notebookListBox: ListBox
    private let notebookRow: ListBoxRow
    private let missionsListBox: ListBox
    private let missionsHeaderRow: ListBoxRow
    private var missionsExpansionChevron: Gtk.Image!
    private var missionsExpansionButton: Button!
    private var missionsExpanded: Bool = true
    private var isReconcilingSidebar: Bool = false
    private var missions: [Mission] = []
    private var missionRowIDs: [UUID] = []
    private var missionSidebarRows: [UUID: ListBoxRow] = [:]
    private var currentMissionsListPane: MissionsListPane?
    private var currentMissionDetailPane: MissionDetailPane?
    private let detailContainer: Box
    private let eventStreamPane: EventStreamPane
    private var notebookPane: NotebookPane?
    private let desktopNotifier: DesktopNotifier
    private var currentInstrumentDetail: InstrumentDetailPane?
    private var currentCustomInstrumentDefPane: CustomInstrumentDefPane?
    private var currentREPLPane: REPLPane?
    private var currentREPLSessionID: UUID?
    private var currentInsightDetail: InsightDetailView?
    private var currentInsightID: UUID?
    private var currentITraceDetail: ITraceDetailView?
    private var currentITraceID: UUID?
    private var sessionDetailViews: [UUID: SessionDetailView] = [:]
    private(set) lazy var sharedTracerEditor: MonacoEditor = makeSharedTracerEditor()
    private(set) lazy var sharedCodeShareEditor: MonacoEditor = makeSharedCodeShareEditor()
    private(set) lazy var sharedCustomInstrumentEditor: MonacoEditor = makeSharedCustomInstrumentEditor()

    private var sessions: [LumaCore.ProcessSession] = []
    private var installedPackages: [LumaCore.InstalledPackage] = []
    private var instrumentsBySession: [UUID: [LumaCore.InstrumentInstance]] = [:]
    private var insightsBySession: [UUID: [LumaCore.AddressInsight]] = [:]
    private var tracesBySession: [UUID: [LumaCore.ITrace]] = [:]
    private var sessionsRowKinds: [SessionsRow] = []
    private var sessionNameLabels: [UUID: Label] = [:]
    private var sessionDeviceLabels: [UUID: Label] = [:]
    private var sessionArmIcons: [UUID: Gtk.Image] = [:]
    private var sessionDetachedHosts: [UUID: Box] = [:]
    private var sessionChevronImages: [UUID: Gtk.Image] = [:]
    private var instrumentChildActions: [String: @MainActor () -> Void] = [:]
    private var instrumentChildKeyByComponent: [InstrumentComponentReference: String] = [:]

    private struct InstrumentComponentReference: Hashable {
        let instrumentID: UUID
        let componentID: UUID
    }
    private var instrumentRowLabels: [UUID: Label] = [:]
    private var instrumentRowIconHosts: [UUID: Box] = [:]
    private var instrumentRowWarningHosts: [UUID: Box] = [:]
    private var traceRowIcons: [UUID: Gtk.Image] = [:]
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

    private var isCollaborationPanelVisible: Bool {
        engine?.projectUIState.isCollaborationPanelVisible ?? false
    }

    private enum SidebarSelection: Equatable {
        case notebook
        case session(UUID)
        case repl(UUID)
        case instrument(sessionID: UUID, instrumentID: UUID)
        case instrumentComponent(sessionID: UUID, instrumentID: UUID, componentID: UUID)
        case insight(sessionID: UUID, insightID: UUID)
        case itrace(sessionID: UUID, traceID: UUID)
        case package(UUID)
        case customInstrumentDef(UUID)
        case customInstrumentFile(UUID, String)
        case missionsList
        case mission(UUID)
    }

    private enum CustomInstrumentRow: Equatable {
        case file(defID: UUID, path: String)
    }

    private enum SessionsRow: Equatable {
        case session(UUID)
        case repl(UUID)
        case instrument(sessionID: UUID, instrumentID: UUID)
        case instrumentChild(sessionID: UUID, instrumentID: UUID, key: String)
        case insight(sessionID: UUID, insightID: UUID)
        case itrace(sessionID: UUID, traceID: UUID)

        var sessionID: UUID {
            switch self {
            case .session(let id), .repl(let id): return id
            case .instrument(let id, _),
                .instrumentChild(let id, _, _),
                .insight(let id, _),
                .itrace(let id, _):
                return id
            }
        }
    }

    init(app: Gtk.Application, application: LumaApplication, document: LumaDocument) {
        self.app = app
        self.application = application
        self.document = document
        let window = Adw.ApplicationWindow(app: app)
        self.desktopNotifier = DesktopNotifier(app: app, window: window)
        self.window = window
        self.outerPaned = Paned(orientation: .horizontal)
        window.title = MainWindow.makeTitle(for: document)
        let state = LumaState.shared
        window.setDefaultSize(width: state.windowWidth, height: state.windowHeight)
        if state.windowMaximized {
            window.maximize()
        }

        let notebookListBox = ListBox()
        let notebookRow = ListBoxRow()
        let missionsListBox = ListBox()
        let missionsHeaderRow = ListBoxRow()
        let sessionsList = ListBox()
        let packagesList = ListBox()
        let packagesSection = Box(orientation: .vertical, spacing: 0)
        let detailContainer = Box(orientation: .vertical, spacing: 0)
        let eventStreamPane = EventStreamPane()
        self.notebookListBox = notebookListBox
        self.notebookRow = notebookRow
        self.missionsListBox = missionsListBox
        self.missionsHeaderRow = missionsHeaderRow
        self.sessionsList = sessionsList
        self.packagesList = packagesList
        self.packagesSection = packagesSection
        self.detailContainer = detailContainer
        self.eventStreamPane = eventStreamPane

        let header = Adw.HeaderBar()

        // Trailing toolbar group, GNOME HIG-style: symbolic icon buttons
        // pinned to the right, tooltips carry the action names. Ordered
        // left-to-right as new session / add instrument / resume /
        // install / collaboration, followed by the main-menu chevron at
        // the far right. `packEnd` stacks right-to-left so we register
        // them in reverse.
        let primaryMenuButton = MenuButton()
        primaryMenuButton.set(iconName: "open-menu-symbolic")
        primaryMenuButton.tooltipText = "Main menu"
        if let menuModelPtr = application.primaryMenuPtr,
            let menuButtonPtr = primaryMenuButton.menu_button_ptr.map(UnsafeMutableRawPointer.init)
        {
            luma_menu_button_set_menu(menuButtonPtr, menuModelPtr)
        }
        header.packEnd(child: primaryMenuButton)

        let collaborationButton = Button()
        collaborationButton.set(iconName: "system-users-symbolic")
        collaborationButton.tooltipText = "Collaboration"
        header.packEnd(child: collaborationButton)
        self.collaborationButton = collaborationButton

        let installPackageButton = Button()
        installPackageButton.set(iconName: "folder-download-symbolic")
        installPackageButton.tooltipText = "Install Package\u{2026}"
        header.packEnd(child: installPackageButton)
        self.installPackageButton = installPackageButton

        let resumeProcessButton = Button()
        resumeProcessButton.set(iconName: "media-playback-start-symbolic")
        resumeProcessButton.tooltipText = "Resume spawned process"
        resumeProcessButton.visible = false
        header.packEnd(child: resumeProcessButton)
        self.resumeProcessButton = resumeProcessButton

        let addInstrumentButton = Button()
        addInstrumentButton.set(iconName: "applications-engineering-symbolic")
        addInstrumentButton.tooltipText = "Add Instrument\u{2026}"
        addInstrumentButton.sensitive = false
        header.packEnd(child: addInstrumentButton)
        self.addInstrumentButton = addInstrumentButton

        let newSessionButton = Button()
        newSessionButton.set(iconName: "list-add-symbolic")
        newSessionButton.tooltipText = "New Session\u{2026}"
        newSessionButton.add(cssClass: "suggested-action")
        header.packEnd(child: newSessionButton)

        let sidebar = buildSidebar()
        let detail = buildDetailPane()
        let sidebarPage = Adw.NavigationPage(child: sidebar, title: "Luma")
        let contentPage = Adw.NavigationPage(child: detail, title: "Detail")
        let splitView = Adw.NavigationSplitView()
        splitView.set(sidebar: sidebarPage)
        splitView.set(content: contentPage)
        splitView.setMinSidebar(width: 240)
        splitView.setMaxSidebar(width: 400)
        splitView.hexpand = true
        splitView.vexpand = true
        self.splitView = splitView

        outerPaned.position = state.collaborationSashPosition
        outerPaned.resizeStartChild = true
        outerPaned.resizeEndChild = false
        outerPaned.shrinkStartChild = false
        outerPaned.shrinkEndChild = false
        outerPaned.startChild = WidgetRef(splitView)
        outerPaned.hexpand = true
        outerPaned.vexpand = true

        let eventStreamPaned = Paned(orientation: .vertical)
        eventStreamPaned.resizeStartChild = true
        eventStreamPaned.resizeEndChild = true
        eventStreamPaned.shrinkStartChild = true
        eventStreamPaned.shrinkEndChild = false
        eventStreamPaned.hexpand = true
        eventStreamPaned.vexpand = true
        self.eventStreamPaned = eventStreamPaned
        self.detailHost = outerPaned

        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true
        self.eventStreamHost = column
        applyEventStreamLayout()

        eventStreamPane.onCollapsedChanged = { [weak self] collapsed in
            guard let self else { return }
            self.applyEventStreamLayout()
            self.engine?.setEventStreamCollapsed(collapsed)
        }
        let toastOverlay = ToastOverlay(content: column)
        self.toastOverlay = toastOverlay

        registerInstrumentUIs()

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: toastOverlay.widget)
        window.set(content: toolbarView)

        newSessionButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestNewSession()
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
        engine?.setCollaborationPanelVisible(visible)
        collaborationPanel?.widget.visible = visible
    }

    func present() {
        window.present()
        renderDetail()
    }

    func showToast(_ message: String, durationSeconds: Double = 3.0) {
        toastOverlay?.show(message, durationSeconds: durationSeconds)
    }

    private func handleUserNotification(_ notification: LumaCore.UserNotification) {
        let summary: String
        if let message = notification.message, !message.isEmpty {
            summary = "\(notification.title) — \(message)"
        } else {
            summary = notification.title
        }
        let duration: Double = notification.severity == .error ? 8 : 3
        showToast(summary, durationSeconds: duration)
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
        let eventStreamSash: Int? = eventStreamPane.collapsed ? nil : Int(eventStreamPaned.position)
        state.saveSashes(
            collaboration: Int(outerPaned.position),
            eventStream: eventStreamSash
        )
    }

    private func applyEventStreamLayout() {
        let host = eventStreamHost!
        if eventStreamPaned.startChild == nil {
            eventStreamPaned.startChild = WidgetRef(detailHost!)
        }
        if host.firstChild == nil {
            host.append(child: eventStreamPaned)
        }
        let stream = eventStreamPane.widget
        if eventStreamPane.collapsed {
            if eventStreamPaned.endChild != nil {
                eventStreamPaned.endChild = nil
            }
            if stream.parent == nil {
                host.append(child: stream)
            }
        } else {
            if stream.parent != nil {
                host.remove(child: stream)
            }
            if eventStreamPaned.endChild == nil {
                eventStreamPaned.endChild = WidgetRef(stream)
            }
            var totalHeight = Int(eventStreamPaned.height)
            if totalHeight <= 0 {
                totalHeight = LumaState.shared.windowHeight
            }
            let saved = LumaState.shared.eventStreamSashPosition
            let defaultPosition = max(0, (totalHeight * 3) / 4)
            eventStreamPaned.position = Int(saved ?? defaultPosition)
        }
    }


    func attach(engine: Engine) {
        self.engine = engine
        eventStreamPane.setInitialCollapsed(engine.projectUIState.isEventStreamCollapsed)
        applyEventStreamLayout()
        engine.onSessionListChanged = { [weak self] change in self?.handleSessionListChange(change) }
        engine.onREPLCellAdded = { [weak self] cell in self?.currentREPLPane?.appendCell(cell) }
        engine.onNotebookChanged = { [weak self] change in
            guard let self else { return }
            self.notebookPane?.handleNotebookChange(change)
            guard
                case let .added(entry) = change,
                let engine = self.engine,
                let authorID = entry.author?.id,
                !engine.collaboration.isSelf(authorID)
            else { return }
            self.desktopNotifier.notifyEntryAdded(entry, labID: engine.collaboration.labID)
        }
        engine.onInstalledPackagesChanged = { [weak self] packages in self?.renderPackages(packages) }
        engine.onUserNotification = { [weak self] notification in
            self?.handleUserNotification(notification)
        }
        engine.customInstruments.observers.append { [weak self] in
            self?.renderCustomInstruments()
            self?.refreshInstrumentRowVisuals()
            self?.refreshCustomInstrumentDefPane()
        }
        renderCustomInstruments()
        _ = NotificationCenter.default.addObserver(
            forName: .lumaSelectCustomInstrumentDef,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let idStr = note.userInfo?["defID"] as? String,
                let id = UUID(uuidString: idStr)
            else { return }
            Task { @MainActor in
                guard let self else { return }
                self.select(self.selectionForCustomInstrument(defID: id))
            }
        }
        engine.populateSessionList()
        renderPackages(engine.installedPackages)
        let initialMissions = (try? engine.store.fetchMissions()) ?? []
        renderMissions(initialMissions)
        engine.onMissionsChanged = { [weak self] missions in
            self?.renderMissions(missions)
        }
        eventStreamPane.attach(engine: engine)
        eventStreamPane.onNavigateToHook = { [weak self] sessionID, instrumentID, hookID in
            self?.navigateToInstrumentComponent(sessionID: sessionID, instrumentID: instrumentID, componentID: hookID)
        }
        AddressActionMenu.navigator = { [weak self] sessionID, insightID in
            guard let self else { return }
            self.select(.insight(sessionID: sessionID, insightID: insightID))
        }
        AddressActionMenu.errorReporter = { [weak self] message in
            self?.showToast(message)
        }
        AddressActionMenu.navigateToTarget = { [weak self] target in
            self?.navigate(to: target)
        }
        InsightDetailView.copyFeedback = { [weak self] message in
            self?.showToast(message, durationSeconds: 1.0)
        }
        let panel = CollaborationPanel(
            engine: engine,
            desktopNotifier: desktopNotifier,
            onClose: { [weak self] in
                self?.setCollaborationVisible(false)
            }
        )
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
        requestNewSession()
    }

    private func requestNewSession() {
        guard let engine else { return }
        if engine.canHostNewSessions {
            openTargetPicker()
        } else {
            presentHostingBlockedAlert()
        }
    }

    private func presentHostingBlockedAlert() {
        let dialog = Adw.AlertDialog(
            heading: "Only lab owners can host sessions",
            body: "You're a member of this lab. Ask an owner to promote you before starting a session."
        )
        dialog.addResponse(id: "ok", label: "OK")
        dialog.defaultResponse = "ok"
        dialog.closeResponse = "ok"
        dialog.present(parent: window)
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
            },
            onArm: { [weak self] device, config, regex in
                self?.armForLaunch(device: device, config: config, regex: regex)
            }
        )
        picker.present()
    }

    private func armForLaunch(device: Frida.Device, config: SpawnConfig, regex: String) {
        guard let engine else { return }
        Task { @MainActor in
            let session = await engine.armNewSession(device: device, config: config, matchPattern: regex)
            self.select(.session(session.id))
        }
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
        select(.session(session.id))
        Task { @MainActor in
            _ = try? await engine.spawnAndAttach(device: device, session: session)
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
        select(.session(session.id))
        Task { @MainActor in
            _ = try? await engine.attach(device: device, process: process, session: session)
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
        let column = Box(orientation: .vertical, spacing: 0)
        column.marginTop = 8
        column.marginBottom = 8
        column.hexpand = true
        column.vexpand = true

        column.append(child: buildNotebookSection())
        column.append(child: buildMissionsSection())
        column.append(child: buildSessionsSection())
        column.append(child: buildCustomInstrumentsSection())
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
        notebookListBox.add(cssClass: "luma-flush-sidebar-list")
        notebookListBox.onRowActivated { [weak self] _, _ in
            MainActor.assumeIsolated { self?.select(.notebook) }
        }
        notebookListBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, row != nil else { return }
                if case .notebook = self.selection { return }
                self.notebookListBox.unselectAll()
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

    private func buildMissionsSection() -> Box {
        missionsListBox.selectionMode = .single
        missionsListBox.add(cssClass: "navigation-sidebar")
        missionsListBox.add(cssClass: "luma-flush-sidebar-list")
        missionsListBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                self.handleMissionsRowSelected(rowIndex: Int(row.index))
            }
        }
        missionsListBox.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                self?.handleMissionsRowSelected(rowIndex: Int(row.index))
            }
        }

        installMissionsHeaderRow()
        missionsListBox.append(child: missionsHeaderRow)

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: missionsListBox)
        return column
    }

    private func renderMissions(_ snapshot: [Mission]) {
        let visibleMissions = snapshot.filter { $0.providerID != "external" }
        diffMissionSidebarRows(visibleMissions)
        missions = visibleMissions
        missionRowIDs = visibleMissions.map(\.id)

        missionsExpansionButton.visible = !visibleMissions.isEmpty

        currentMissionsListPane?.updateMissions(visibleMissions)

        if case .mission(let id) = selection {
            if let mission = visibleMissions.first(where: { $0.id == id }) {
                currentMissionDetailPane?.updateMission(mission)
            } else {
                select(.missionsList)
            }
        }
    }

    private func diffMissionSidebarRows(_ missions: [Mission]) {
        let previousByID = Dictionary(uniqueKeysWithValues: self.missions.map { ($0.id, $0) })
        let nextIDs = Set(missions.map(\.id))

        for id in missionSidebarRows.keys where !nextIDs.contains(id) {
            if let row = missionSidebarRows.removeValue(forKey: id) {
                missionsListBox.remove(child: row)
            }
        }

        let orderChanged = self.missions.map(\.id) != missions.map(\.id)
        if orderChanged {
            rebuildMissionSidebarRows(missions)
            return
        }

        for (index, mission) in missions.enumerated() {
            if let previous = previousByID[mission.id],
                previous.updatedAt == mission.updatedAt,
                missionSidebarRows[mission.id] != nil {
                continue
            }
            if let stale = missionSidebarRows[mission.id] {
                missionsListBox.remove(child: stale)
            }
            let row = makeMissionSidebarRow(mission)
            row.visible = missionsExpanded
            missionSidebarRows[mission.id] = row
            missionsListBox.insert(child: row, position: index + 1)
        }
    }

    private func rebuildMissionSidebarRows(_ missions: [Mission]) {
        while let row = missionsListBox.getRowAt(index: 1) {
            missionsListBox.remove(child: row)
        }
        missionSidebarRows.removeAll()
        for mission in missions {
            let row = makeMissionSidebarRow(mission)
            row.visible = missionsExpanded
            missionSidebarRows[mission.id] = row
            missionsListBox.append(child: row)
        }
    }

    private func makeMissionsListPane() -> MissionsListPane {
        guard let engine else { fatalError("Engine not attached") }
        let pane = MissionsListPane(
            engine: engine,
            onSelectMission: { [weak self] id in
                self?.select(.mission(id))
            },
            onNewMission: { [weak self] in
                self?.openNewMissionDialog()
            },
            onCopied: { [weak self] message in
                self?.showToast(message, durationSeconds: 1.5)
            }
        )
        pane.updateMissions(missions)
        return pane
    }

    private func makeMissionDetailPane(for mission: Mission) -> MissionDetailPane {
        guard let engine else { fatalError("Engine not attached") }
        return MissionDetailPane(
            engine: engine,
            mission: mission,
            parentWindow: window,
            onCopied: { [weak self] message in
                self?.showToast(message, durationSeconds: 1.5)
            },
            onAddNotebookEntry: { [weak self] entry in
                self?.engine?.addNotebookEntry(entry)
                self?.showToast("Added to notebook")
            }
        )
    }

    private func installMissionsHeaderRow() {
        let box = Box(orientation: .horizontal, spacing: 8)
        box.marginStart = 12
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let icon = Gtk.Image(iconName: "applications-engineering-symbolic")
        icon.pixelSize = 16
        icon.add(cssClass: "accent")
        box.append(child: icon)

        let label = Label(str: "Missions")
        label.halign = .start
        label.hexpand = true
        box.append(child: label)

        let chevron = Gtk.Image(iconName: "pan-down-symbolic")
        chevron.pixelSize = 12
        chevron.add(cssClass: "dim-label")
        missionsExpansionChevron = chevron

        let chevronButton = Button()
        chevronButton.set(child: chevron)
        chevronButton.add(cssClass: "flat")
        chevronButton.add(cssClass: "circular")
        chevronButton.tooltipText = "Hide missions"
        chevronButton.visible = false
        chevronButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleMissionsExpansion() }
        }
        missionsExpansionButton = chevronButton
        box.append(child: chevronButton)

        missionsHeaderRow.set(child: box)
    }

    private func makeMissionSidebarRow(_ mission: Mission) -> ListBoxRow {
        let row = ListBoxRow()
        let box = Box(orientation: .horizontal, spacing: 8)
        box.marginStart = 28
        box.marginEnd = 12
        box.marginTop = 4
        box.marginBottom = 4

        let avatarSeed = mission.title?.isEmpty == false ? mission.title! : mission.goalText
        let avatar = Adw.Avatar(size: 18, text: avatarSeed, showInitials: true)
        box.append(child: avatar)

        let column = Box(orientation: .vertical, spacing: 1)
        column.hexpand = true

        let title = Label(str: missionDisplayTitle(mission))
        title.halign = .start
        title.ellipsize = EllipsizeMode.end
        title.maxWidthChars = 26
        title.xalign = 0
        column.append(child: title)

        let subtitle = Label(str: missionSubtitleText(mission))
        subtitle.halign = .start
        subtitle.add(cssClass: "dim-label")
        subtitle.add(cssClass: "caption")
        subtitle.ellipsize = EllipsizeMode.end
        subtitle.maxWidthChars = 26
        subtitle.xalign = 0
        column.append(child: subtitle)

        box.append(child: column)

        let statusIndicator = makeMissionStatusDot(for: mission)
        statusIndicator.valign = .center
        box.append(child: statusIndicator)

        row.set(child: box)
        attachMissionContextMenu(row: row, anchor: box, mission: mission)
        return row
    }

    private func openNewMissionDialog() {
        guard let engine else { return }
        let dialog = NewMissionDialog(
            parent: window,
            engine: engine
        ) { [weak self] mission in
            guard let self else { return }
            self.select(.mission(mission.id))
            self.showToast("Mission started")
        }
        dialog.present()
    }

    private func handleMissionsRowSelected(rowIndex: Int) {
        if rowIndex == 0 {
            select(.missionsList)
        } else {
            select(.mission(missionRowIDs[rowIndex - 1]))
        }
    }

    private func toggleMissionsExpansion() {
        missionsExpanded.toggle()
        let iconName = missionsExpanded ? "pan-down-symbolic" : "pan-end-symbolic"
        missionsExpansionChevron.set(name: iconName)
        missionsExpansionButton.tooltipText = missionsExpanded ? "Hide missions" : "Show missions"
        for index in missionRowIDs.indices {
            missionsListBox.getRowAt(index: index + 1)?.visible = missionsExpanded
        }
    }

    private func missionDisplayTitle(_ mission: Mission) -> String {
        if let title = mission.title, !title.isEmpty { return title }
        let trimmed = mission.goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mission" : firstLine(of: trimmed, max: 40)
    }

    private func missionSubtitleText(_ mission: Mission) -> String {
        switch mission.status {
        case .running: return "Running…"
        case .awaitingApproval: return "Awaiting approval"
        case .paused: return "Paused"
        case .completed: return "Completed · \(RelativeTime.string(from: mission.updatedAt))"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .drafting: return "Drafting"
        }
    }

    private func makeMissionStatusDot(for mission: Mission) -> Label {
        let color = MissionPalette.color(for: mission.status)
        let label = Label(str: "")
        label.useMarkup = true
        label.setMarkup(str: "<span foreground=\"\(color.hex)\">●</span>")
        label.tooltipText = MissionPalette.label(for: mission.status)
        return label
    }

    private func attachMissionContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        mission: Mission
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentMissionContextMenu(anchor: anchor, x: x, y: y, mission: mission)
            }
        }
        row.install(controller: click)
    }

    private func firstLine(of text: String, max: Int) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        if firstLine.count <= max { return firstLine }
        return String(firstLine.prefix(max - 1)) + "…"
    }

    private func presentMissionContextMenu(
        anchor: Widget,
        x: Double,
        y: Double,
        mission: Mission
    ) {
        var sections: [[ContextMenu.Item]] = []
        if mission.status.isLive {
            sections.append([
                .init("Stop Mission") { [weak self] in
                    self?.engine?.cancelMission(missionID: mission.id)
                }
            ])
        }
        sections.append([
            .init("Delete Mission", destructive: true) { [weak self] in
                self?.confirmDeleteMission(mission)
            }
        ])
        ContextMenu.present(sections, at: anchor, x: x, y: y)
    }

    private func confirmDeleteMission(_ mission: Mission) {
        let title = mission.title?.isEmpty == false ? mission.title! : "this mission"
        confirmDestructive(
            message: "Delete \(title)?",
            detail: "This removes the mission and its history from the project.",
            destructiveLabel: "Delete"
        ) { [weak self] in
            self?.engine?.deleteMission(missionID: mission.id)
            self?.showToast("Mission deleted")
        }
    }

    private func buildSessionsSection() -> Box {
        sessionsList.selectionMode = .single
        sessionsList.add(cssClass: "navigation-sidebar")
        sessionsList.add(cssClass: "luma-tight-sidebar")
        sessionsList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                guard !self.isReconcilingSidebar else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.sessionsRowKinds.count else { return }
                switch self.sessionsRowKinds[index] {
                case .session(let id):
                    self.select(.session(id))
                case .repl(let id):
                    self.select(.repl(id))
                case .instrument(let sid, let iid):
                    self.select(.instrument(sessionID: sid, instrumentID: iid))
                case .instrumentChild(let sid, let iid, let key):
                    self.activateInstrumentChild(sessionID: sid, instrumentID: iid, key: key)
                case .insight(let sid, let iid):
                    self.select(.insight(sessionID: sid, insightID: iid))
                case .itrace(let sid, let tid):
                    self.select(.itrace(sessionID: sid, traceID: tid))
                }
            }
        }

        let headerLabel = Label(str: "Sessions (0)")
        headerLabel.halign = .start
        headerLabel.add(cssClass: "caption-heading")
        headerLabel.add(cssClass: "dim-label")
        sessionsHeaderLabel = headerLabel

        let expander = Expander(label: "")
        expander.set(labelWidget: headerLabel)
        expander.set(child: sessionsList)
        expander.expanded = true
        expander.marginStart = 4
        expander.marginEnd = 4

        let column = Box(orientation: .vertical, spacing: 0)
        column.marginTop = 12
        column.append(child: expander)
        column.visible = false
        sessionsSection = column
        return column
    }

    private func buildCustomInstrumentsSection() -> Box {
        customInstrumentsList.selectionMode = .single
        customInstrumentsList.add(cssClass: "navigation-sidebar")
        customInstrumentsList.add(cssClass: "luma-tight-sidebar")
        customInstrumentsList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.customInstrumentRows.count else { return }
                if case .file(let defID, let path) = self.customInstrumentRows[index] {
                    self.select(.customInstrumentFile(defID, path))
                }
            }
        }

        let headerLabel = Label(str: "Custom Instruments (0)")
        headerLabel.halign = .start
        headerLabel.add(cssClass: "caption-heading")
        headerLabel.add(cssClass: "dim-label")
        customInstrumentsHeaderLabel = headerLabel

        let expander = Expander(label: "")
        expander.set(labelWidget: headerLabel)
        expander.set(child: customInstrumentsList)
        expander.expanded = true
        expander.marginStart = 4
        expander.marginEnd = 4

        let column = Box(orientation: .vertical, spacing: 0)
        column.marginTop = 12
        column.append(child: expander)
        column.visible = false
        customInstrumentsSection = column
        return column
    }

    private func renderCustomInstruments() {
        guard let engine else { return }
        let defs = engine.customInstruments.defs
        customInstrumentDefs = defs

        var child = customInstrumentsList.firstChild
        while let current = child {
            child = current.nextSibling
            customInstrumentsList.remove(child: current)
        }

        var rows: [CustomInstrumentRow] = []
        for def in defs {
            let auxiliaryFiles = CustomInstrumentFile.sortedByPath(
                engine.customInstruments.files(forDefID: def.id).filter { $0.path != def.entrypoint },
                entrypoint: def.entrypoint
            )
            let expansion = engine.sidebarExpansion(forCustomInstrumentDefID: def.id)
            let isExpanded = auxiliaryFiles.isEmpty || expansion == .expanded
            customInstrumentsList.append(child: makeCustomInstrumentDefRow(
                def: def,
                hasAuxiliaryFiles: !auxiliaryFiles.isEmpty,
                isExpanded: isExpanded
            ))
            rows.append(.file(defID: def.id, path: def.entrypoint))

            if isExpanded {
                for file in auxiliaryFiles {
                    customInstrumentsList.append(child: makeCustomInstrumentFileRow(def: def, file: file))
                    rows.append(.file(defID: def.id, path: file.path))
                }
            }
        }
        customInstrumentRows = rows
        customInstrumentsHeaderLabel?.label = "Custom Instruments (\(defs.count))"
        customInstrumentsSection?.visible = !defs.isEmpty

        invalidateStaleCustomInstrumentSelection(defs: defs, engine: engine)
    }

    private func invalidateStaleCustomInstrumentSelection(
        defs: [LumaCore.CustomInstrumentDef],
        engine: Engine
    ) {
        switch selection {
        case .customInstrumentDef(let id):
            if !defs.contains(where: { $0.id == id }) {
                select(.notebook)
                notebookListBox.select(row: notebookRow)
            }
        case .customInstrumentFile(let id, let path):
            if !defs.contains(where: { $0.id == id }) {
                select(.notebook)
                notebookListBox.select(row: notebookRow)
            } else if engine.customInstruments.file(defID: id, path: path) == nil {
                select(.customInstrumentDef(id))
            }
        default:
            break
        }
    }

    private func makeCustomInstrumentDefRow(
        def: LumaCore.CustomInstrumentDef,
        hasAuxiliaryFiles: Bool,
        isExpanded: Bool
    ) -> ListBoxRow {
        let row = ListBoxRow()
        let box = Box(orientation: .horizontal, spacing: 0)
        box.marginStart = MainWindow.sidebarRowLeadingPad
        box.marginEnd = 12
        box.marginTop = 4
        box.marginBottom = 4

        let chevronWidget: Widget
        if hasAuxiliaryFiles {
            chevronWidget = makeCustomInstrumentChevron(isExpanded: isExpanded) { [weak self] in
                self?.toggleCustomInstrumentExpansion(defID: def.id)
            }
        } else {
            chevronWidget = makeChevronSpacer()
        }
        chevronWidget.marginEnd = MainWindow.sidebarChevronToIconSpacing
        box.append(child: chevronWidget)

        let iconHost = MainWindow.makeParentIconHost()
        iconHost.marginEnd = MainWindow.sidebarIconToLabelSpacing
        let icon = InstrumentIconView.makeImage(for: def.icon, pixelSize: 16)
        MainWindow.centerInIconHost(icon)
        iconHost.append(child: icon)
        box.append(child: iconHost)

        let label = Label(str: def.name)
        label.halign = .start
        label.hexpand = true
        box.append(child: label)
        row.set(child: box)
        attachCustomInstrumentContextMenu(row: row, anchor: box, def: def)
        return row
    }

    private func makeChevronSpacer() -> Widget {
        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.setSizeRequest(width: MainWindow.sidebarChevronColumnWidth, height: -1)
        return spacer
    }

    private func toggleCustomInstrumentExpansion(defID: UUID) {
        guard let engine else { return }
        let current = engine.sidebarExpansion(forCustomInstrumentDefID: defID)
        let next: SidebarExpansion = current == .expanded ? .collapsed : .expanded
        engine.setSidebarExpansion(customInstrumentDefID: defID, next)
        Task { @MainActor [weak self] in
            self?.renderCustomInstruments()
        }
    }

    private func makeCustomInstrumentChevron(isExpanded: Bool, onToggle: @escaping () -> Void) -> Widget {
        let chevronImage = Gtk.Image(iconName: isExpanded ? "pan-down-symbolic" : "pan-end-symbolic")
        chevronImage.pixelSize = 12
        chevronImage.add(cssClass: "dim-label")
        let button = Button()
        button.set(child: chevronImage)
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-sidebar-chevron")
        button.valign = .center
        button.onClicked { _ in
            MainActor.assumeIsolated { onToggle() }
        }
        return button
    }

    private func makeCustomInstrumentFileRow(
        def: LumaCore.CustomInstrumentDef,
        file: LumaCore.CustomInstrumentFile
    ) -> ListBoxRow {
        let row = ListBoxRow()
        let (box, iconHost) = MainWindow.makeChildRowBox()
        let icon = Gtk.Image(iconName: "text-x-generic-symbolic")
        icon.pixelSize = 16
        MainWindow.centerInIconHost(icon)
        iconHost.append(child: icon)
        let label = Label(str: file.path)
        label.halign = .start
        label.hexpand = true
        if file.path == def.entrypoint {
            label.add(cssClass: "heading")
        }
        box.append(child: label)
        row.set(child: box)
        attachCustomInstrumentFileContextMenu(row: row, anchor: box, def: def, file: file)
        return row
    }

    private func refreshInstrumentRowVisuals() {
        guard let engine else { return }
        for (id, label) in instrumentRowLabels {
            guard let instrument = instrument(withID: id) else { continue }
            let descriptor = engine.descriptor(for: instrument)
            label.label = descriptor.displayName
            if let host = instrumentRowIconHosts[id] {
                replaceIconHostContents(host, with: descriptor.icon)
            }
            if let host = instrumentRowWarningHosts[id] {
                populateStatusWarning(host: host, status: instrumentRuntimeStatus(for: instrument))
            }
        }
    }

    private func populateStatusWarning(host: Box, status: InstrumentStatus?) {
        var child = host.firstChild
        while let cur = child {
            child = cur.nextSibling
            host.remove(child: cur)
        }
        guard let status else { return }
        host.append(child: InstrumentStatusPopover.makeIndicator(status: status))
    }

    private func replaceIconHostContents(_ host: Box, with icon: InstrumentIcon) {
        var child = host.firstChild
        while let cur = child {
            child = cur.nextSibling
            host.remove(child: cur)
        }
        host.append(child: InstrumentIconView.makeImage(for: icon, pixelSize: 16))
    }

    private func refreshCustomInstrumentDefPane() {
        guard let pane = currentCustomInstrumentDefPane,
            let engine,
            let updated = engine.customInstruments.def(withId: pane.def.id),
            let file = engine.customInstruments.file(defID: pane.def.id, path: pane.file.path)
                ?? engine.customInstruments.files(forDefID: pane.def.id).first
        else { return }
        pane.refresh(def: updated, file: file)
    }

    private func customInstrumentPaneWidget(defID: UUID, path: String?) -> Widget {
        guard let engine, let def = engine.customInstruments.def(withId: defID) else {
            return MainWindow.makeEmptyState(
                icon: "applications-utilities-symbolic",
                title: "Custom instrument unavailable",
                subtitle: "This custom instrument is no longer in the project."
            )
        }
        let resolvedPath = path ?? def.entrypoint
        guard let file = engine.customInstruments.file(defID: defID, path: resolvedPath)
            ?? engine.customInstruments.files(forDefID: defID).first
        else {
            return MainWindow.makeEmptyState(
                icon: "text-x-generic-symbolic",
                title: "File unavailable",
                subtitle: "This file no longer exists in the instrument."
            )
        }
        let pane: CustomInstrumentDefPane
        if let existing = currentCustomInstrumentDefPane, existing.def.id == defID {
            existing.refresh(def: def, file: file)
            pane = existing
        } else {
            pane = CustomInstrumentDefPane(
                engine: engine,
                def: def,
                file: file,
                sourceEditor: sharedCustomInstrumentEditor
            )
            pane.onRevertNavigation = { [weak self] revertedPath in
                self?.select(.customInstrumentFile(defID, revertedPath))
            }
            currentCustomInstrumentDefPane = pane
        }
        if pane.widget.parent != nil {
            pane.widget.unparent()
        }
        return pane.widget
    }

    private func instrument(withID id: UUID) -> LumaCore.InstrumentInstance? {
        for instruments in instrumentsBySession.values {
            if let match = instruments.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    private func attachCustomInstrumentContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        def: LumaCore.CustomInstrumentDef
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentCustomInstrumentContextMenu(anchor: anchor, x: x, y: y, def: def)
            }
        }
        row.install(controller: click)
    }

    private func presentCustomInstrumentContextMenu(
        anchor: Widget,
        x: Double,
        y: Double,
        def: LumaCore.CustomInstrumentDef
    ) {
        ContextMenu.present([
            [
                .init("Rename & Icon\u{2026}") { [weak self] in self?.presentCustomInstrumentRenameDialog(def: def) },
                .init("Compatibility\u{2026}") { [weak self] in self?.presentCustomInstrumentCompatibilityDialog(def: def) },
                .init("Features\u{2026}") { [weak self] in self?.presentCustomInstrumentFeaturesDialog(def: def) },
                .init("Widgets\u{2026}") { [weak self] in self?.presentCustomInstrumentWidgetsDialog(def: def) },
            ],
            [
                .init("Add File\u{2026}") { [weak self] in self?.presentAddCustomInstrumentFileDialog(def: def) },
                .init("Rename Entrypoint File\u{2026}") { [weak self] in
                    guard let self else { return }
                    self.presentRenameEntrypointFileDialog(def: def)
                },
            ],
            [
                .init("Export as Hookpack\u{2026}") { [weak self] in self?.presentExportHookPackDialog(def: def) },
            ],
            [.init("Delete Custom Instrument", destructive: true) { [weak self] in
                self?.confirmDeleteCustomInstrument(def: def)
            }],
        ], at: anchor, x: x, y: y)
    }

    private func attachCustomInstrumentFileContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        def: LumaCore.CustomInstrumentDef,
        file: LumaCore.CustomInstrumentFile
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentCustomInstrumentFileContextMenu(anchor: anchor, x: x, y: y, def: def, file: file)
            }
        }
        row.install(controller: click)
    }

    private func presentCustomInstrumentFileContextMenu(
        anchor: Widget,
        x: Double,
        y: Double,
        def: LumaCore.CustomInstrumentDef,
        file: LumaCore.CustomInstrumentFile
    ) {
        let isEntrypoint = file.path == def.entrypoint
        var sections: [[ContextMenu.Item]] = []
        if !isEntrypoint {
            sections.append([
                .init("Set as Entrypoint") { [weak self] in self?.setCustomInstrumentEntrypoint(defID: def.id, path: file.path) }
            ])
        }
        sections.append([
            .init("Rename\u{2026}") { [weak self] in self?.presentRenameCustomInstrumentFileDialog(def: def, file: file) }
        ])
        if !isEntrypoint {
            sections.append([
                .init("Delete", destructive: true) { [weak self] in
                    self?.confirmDeleteCustomInstrumentFile(def: def, file: file)
                }
            ])
        }
        ContextMenu.present(sections, at: anchor, x: x, y: y)
    }

    private func presentAddCustomInstrumentFileDialog(def: LumaCore.CustomInstrumentDef) {
        guard let engine else { return }
        CustomInstrumentFileDialogs.presentAdd(engine: engine, def: def, parent: window) { [weak self] newPath in
            self?.select(.customInstrumentFile(def.id, newPath))
        }
    }

    private func presentRenameCustomInstrumentFileDialog(
        def: LumaCore.CustomInstrumentDef,
        file: LumaCore.CustomInstrumentFile
    ) {
        guard let engine else { return }
        CustomInstrumentFileDialogs.presentRename(engine: engine, def: def, file: file, parent: window) { [weak self] newPath in
            if self?.selection == .customInstrumentFile(def.id, file.path) {
                self?.select(.customInstrumentFile(def.id, newPath))
            }
        }
    }

    private func selectionForCustomInstrument(defID: UUID) -> SidebarSelection {
        if let entrypoint = engine?.customInstruments.def(withId: defID)?.entrypoint {
            return .customInstrumentFile(defID, entrypoint)
        }
        return .customInstrumentDef(defID)
    }

    private func presentRenameEntrypointFileDialog(def: LumaCore.CustomInstrumentDef) {
        guard let engine,
            let file = engine.customInstruments.file(defID: def.id, path: def.entrypoint)
        else { return }
        presentRenameCustomInstrumentFileDialog(def: def, file: file)
    }

    private func setCustomInstrumentEntrypoint(defID: UUID, path: String) {
        guard let engine else { return }
        Task { @MainActor in
            await engine.setCustomInstrumentEntrypoint(defID: defID, path: path)
        }
    }

    private func confirmDeleteCustomInstrumentFile(
        def: LumaCore.CustomInstrumentDef,
        file: LumaCore.CustomInstrumentFile
    ) {
        confirmDestructive(
            message: "Delete \"\(file.path)\"?",
            detail: "Removes this file from the instrument.",
            destructiveLabel: "Delete"
        ) { [weak self] in
            guard let self, let engine = self.engine else { return }
            let defID = def.id
            let path = file.path
            let entrypoint = def.entrypoint
            Task { @MainActor in
                await engine.deleteCustomInstrumentFile(defID: defID, path: path)
                if self.selection == .customInstrumentFile(defID, path) {
                    self.select(.customInstrumentFile(defID, entrypoint))
                }
            }
        }
    }

    private func presentExportHookPackDialog(def: LumaCore.CustomInstrumentDef) {
        guard let parentPtr = window.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let context = HookPackExportContext(window: self, def: def)
        let opaque = Unmanaged.passRetained(context).toOpaque()
        let initialName = HookPackExportContext.suggestedFilename(for: def.name)
        "Export as Hookpack".withCString { title in
            initialName.withCString { initial in
                luma_file_dialog_save(parentPtr, title, initial, hookPackExportPathThunk, opaque)
            }
        }
    }

    fileprivate func handleHookPackExport(def: LumaCore.CustomInstrumentDef, path: String) {
        guard let engine else { return }
        let folderURL = URL(fileURLWithPath: path)
        do {
            try engine.exportCustomInstrumentAsHookPack(def, to: folderURL)
        } catch {
            presentExportError(message: error.localizedDescription)
        }
    }

    private func presentExportError(message: String) {
        let dialog = Adw.AlertDialog(heading: "Export failed", body: message)
        dialog.addResponse(id: "ok", label: "OK")
        dialog.setDefault(response: "ok")
        dialog.setClose(response: "ok")
        dialog.present(parent: window)
    }

    private func confirmDeleteCustomInstrument(def: LumaCore.CustomInstrumentDef) {
        confirmDestructive(
            message: "Delete \"\(def.name)\"?",
            detail: "This removes the custom instrument from the project and from any sessions where it is loaded.",
            destructiveLabel: "Delete"
        ) { [weak self] in
            guard let engine = self?.engine else { return }
            Task { @MainActor in
                await engine.deleteCustomInstrument(def.id)
            }
        }
    }

    private func presentCustomInstrumentFeaturesDialog(def: LumaCore.CustomInstrumentDef) {
        guard let engine else { return }
        CustomInstrumentFeaturesDialog(engine: engine, def: def).present(parent: window)
    }

    private func presentCustomInstrumentWidgetsDialog(def: LumaCore.CustomInstrumentDef) {
        guard let engine else { return }
        CustomInstrumentWidgetsDialog(engine: engine, def: def).present(parent: window)
    }

    private func presentCustomInstrumentRenameDialog(def: LumaCore.CustomInstrumentDef) {
        guard let engine else { return }
        CustomInstrumentRenameDialog(engine: engine, def: def, parentWindow: window).present()
    }

    private func presentCustomInstrumentCompatibilityDialog(def: LumaCore.CustomInstrumentDef) {
        guard let engine else { return }
        CustomInstrumentCompatibilityDialog(engine: engine, def: def).present(parent: window)
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

        let headerLabel = Label(str: "Packages (0)")
        headerLabel.halign = .start
        headerLabel.add(cssClass: "caption-heading")
        headerLabel.add(cssClass: "dim-label")
        packagesHeaderLabel = headerLabel

        let expander = Expander(label: "")
        expander.set(labelWidget: headerLabel)
        expander.set(child: packagesList)
        expander.expanded = true
        expander.marginStart = 4
        expander.marginEnd = 4

        packagesSection.marginTop = 12
        packagesSection.append(child: expander)
        packagesSection.visible = false
        packagesSidebarSection = packagesSection
        return packagesSection
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
        if let iid = activeInstrumentID(in: selection) {
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
        if case .itrace(_, let tid) = selection {
            if currentITraceID != tid {
                currentITraceDetail = nil
                currentITraceID = nil
            }
        } else {
            currentITraceDetail = nil
            currentITraceID = nil
        }
        switch selection {
        case .customInstrumentDef(let defID), .customInstrumentFile(let defID, _):
            if currentCustomInstrumentDefPane?.def.id != defID {
                currentCustomInstrumentDefPane?.flushDraftIfNeeded()
                currentCustomInstrumentDefPane = nil
            }
        default:
            currentCustomInstrumentDefPane?.flushDraftIfNeeded()
            currentCustomInstrumentDefPane = nil
        }
        if case .mission(let id) = selection {
            if currentMissionDetailPane?.missionID != id {
                currentMissionDetailPane?.stop()
                currentMissionDetailPane = nil
            }
        } else {
            currentMissionDetailPane?.stop()
            currentMissionDetailPane = nil
        }
        if case .missionsList = selection {
            // keep current
        } else {
            currentMissionsListPane = nil
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
        case .itrace(let sid, let tid):
            let cached = tracesBySession[sid]
            let allTraces = cached ?? (try? engine?.store.fetchITraces(sessionID: sid)) ?? []
            if let trace = allTraces.first(where: { $0.id == tid }), let engine {
                let detail: ITraceDetailView
                if let existing = currentITraceDetail, currentITraceID == tid {
                    detail = existing
                } else {
                    let others = allTraces.filter { $0.id != tid }
                    detail = ITraceDetailView(
                        trace: trace,
                        otherTraces: others,
                        engine: engine,
                        sessionID: sid
                    )
                    currentITraceDetail = detail
                    currentITraceID = tid
                }
                widget = detail.widget
            } else {
                widget = MainWindow.makeEmptyState(
                    icon: "system-run-symbolic",
                    title: "Trace unavailable",
                    subtitle: "This ITrace is no longer in the store."
                )
            }
        case .instrument(let sid, let iid),
            .instrumentComponent(let sid, let iid, _):
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
        case .customInstrumentDef(let defID):
            widget = customInstrumentPaneWidget(defID: defID, path: nil)
        case .customInstrumentFile(let defID, let path):
            widget = customInstrumentPaneWidget(defID: defID, path: path)
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
        case .missionsList:
            let pane = currentMissionsListPane ?? makeMissionsListPane()
            pane.refreshExternalMCP()
            currentMissionsListPane = pane
            widget = pane.widget
        case .mission(let id):
            if let mission = missions.first(where: { $0.id == id }) ?? (try? engine?.store.fetchMission(id: id)).flatMap({ $0 }) {
                let pane: MissionDetailPane
                if let existing = currentMissionDetailPane, existing.missionID == id {
                    pane = existing
                    pane.updateMission(mission)
                } else {
                    pane = makeMissionDetailPane(for: mission)
                    pane.start()
                    currentMissionDetailPane = pane
                }
                widget = pane.widget
            } else {
                widget = MainWindow.makeEmptyState(
                    icon: "applications-engineering-symbolic",
                    title: "Mission unavailable",
                    subtitle: "This mission is no longer in the project."
                )
            }
        }
        replaceDetail(with: wrapWithCollabHeader(widget))
        addInstrumentButton.sensitive = currentSessionID() != nil
        if case .insight = selection {
            currentInsightDetail?.requestFocus()
        }
    }

    private func wrapWithCollabHeader<T: WidgetProtocol>(_ widget: T) -> Box {
        let column = Box(orientation: .vertical, spacing: 0)
        column.hexpand = true
        column.vexpand = true

        widget.hexpand = true
        widget.vexpand = true
        column.append(child: widget)
        return column
    }

    private func currentSessionID() -> UUID? {
        switch selection {
        case .session(let id), .repl(let id):
            return id
        case .instrument(let id, _),
            .instrumentComponent(let id, _, _),
            .insight(let id, _),
            .itrace(let id, _):
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
            if existing.widget.parent != nil {
                existing.widget.unparent()
            }
            return existing.widget
        }
        let sessionID = session.id
        let instrumentID = instrument.id
        let pane = InstrumentDetailPane(
            engine: engine,
            session: session,
            instrument: instrument,
            owner: self,
            host: self,
            onComponentAdded: { [weak self] componentID in
                self?.navigateToInstrumentComponent(sessionID: sessionID, instrumentID: instrumentID, componentID: componentID)
            }
        )
        currentInstrumentDetail = pane
        return pane.widget
    }

    private func toggleInstrument(_ instrument: LumaCore.InstrumentInstance) {
        guard let engine else { return }
        let newState: LumaCore.InstrumentState = instrument.state == .enabled ? .disabled : .enabled
        Task { @MainActor in
            await engine.setInstrumentState(instrument, state: newState)
            self.renderDetail()
        }
    }

    private func deleteInstrument(_ instrument: LumaCore.InstrumentInstance) {
        guard let engine else { return }
        let title = engine.descriptor(for: instrument).displayName
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

        guard let engine else {
            if SessionDetachedBanner.shouldShow(for: session) {
                let banner = SessionDetachedBanner.make(
                    for: session,
                    gatingActive: false,
                    onReattach: { [weak self] in self?.reestablishSession(id: session.id) },
                    onDisarm: { },
                    onArm: { [weak self] in self?.presentArmDialog(session: session) },
                    onResumeGating: { }
                )
                column.append(child: banner)
            }
            let subtitle = "\(session.deviceName) · pid \(session.lastKnownPID)"
            column.append(child: makePlaceholder(title: session.processName, subtitle: subtitle))
            return column
        }

        let detail: SessionDetailView
        if let cached = sessionDetailViews[session.id] {
            detail = cached
            if detail.widget.parent != nil {
                detail.widget.unparent()
            }
        } else {
            detail = SessionDetailView(engine: engine, session: session)
            sessionDetailViews[session.id] = detail
        }
        detail.onReestablish = { [weak self] in
            self?.reestablishSession(id: session.id)
        }
        detail.onArmRequested = { [weak self] in
            self?.presentArmDialog(session: session)
        }
        detail.applySessionState()
        column.append(child: detail.widget)
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
        let disabledDescriptorIDs = Set(existing.map { engine.descriptor(for: $0).id })
        Task { @MainActor in
            let incompatibilityReasons = await self.resolveIncompatibilityReasons(
                engine: engine,
                sessionID: sessionID
            )
            let dialog = AddInstrumentDialog(
                parent: self.window,
                engine: engine,
                sessionID: sessionID,
                descriptors: engine.descriptors,
                disabledDescriptorIDs: disabledDescriptorIDs,
                incompatibilityReasons: incompatibilityReasons,
                tracerEditor: self.sharedTracerEditor,
                codeShareEditor: self.sharedCodeShareEditor
            ) { [weak self] instance in
                guard let self else { return }
                if instance.kind == .custom, let defID = UUID(uuidString: instance.sourceIdentifier) {
                    self.select(self.selectionForCustomInstrument(defID: defID))
                } else {
                    self.select(.instrument(sessionID: sessionID, instrumentID: instance.id))
                }
                self.showToast("Added \(engine.descriptor(for: instance).displayName)")
            }
            dialog.present()
        }
    }

    private func resolveIncompatibilityReasons(
        engine: Engine,
        sessionID: UUID
    ) async -> [String: String] {
        guard let session = engine.sessions.first(where: { $0.id == sessionID }) else { return [:] }
        let devices = await engine.deviceManager.currentDevices()
        guard let device = devices.first(where: { $0.id == session.deviceID }) else { return [:] }
        guard let params = await engine.systemParameters.parameters(for: device) else { return [:] }
        var reasons: [String: String] = [:]
        for descriptor in engine.descriptors {
            if let reason = descriptor.compatibility.incompatibilityReason(for: params) {
                reasons[descriptor.id] = reason
            }
        }
        return reasons
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
        page.set(iconName: icon)
        page.set(title: title)
        page.set(description: subtitle)

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

    private func registerInstrumentUIs() {
        let registry = InstrumentUIRegistry.shared
        registry.register(.tracer, ui: TracerUIKind(sharedMonaco: sharedTracerEditor))
        registry.register(.hookPack, ui: HookPackUIKind())
        registry.register(.codeShare, ui: CodeShareUIKind())
        registry.register(.custom, ui: CustomUIKind())
    }

    func navigateToInstrument(sessionID: UUID, instrumentID: UUID) {
        select(.instrument(sessionID: sessionID, instrumentID: instrumentID))
    }

    func selectedComponentID(sessionID: UUID, instrumentID: UUID) -> UUID? {
        guard case .instrumentComponent(let sid, let iid, let cid) = selection,
            sid == sessionID, iid == instrumentID
        else { return nil }
        return cid
    }

    func navigateToInstrumentComponent(sessionID: UUID, instrumentID: UUID, componentID: UUID) {
        if let engine, engine.sidebarExpansion(forSessionID: sessionID) == .collapsed {
            setSessionExpansion(sessionID: sessionID, .expanded)
        }
        isReconcilingSidebar = true
        select(.instrumentComponent(sessionID: sessionID, instrumentID: instrumentID, componentID: componentID))
        Task { @MainActor in
            await Task.yield()
            if let instrument = instrumentsBySession[sessionID]?.first(where: { $0.id == instrumentID }) {
                reconcileInstrumentChildren(for: instrument)
            }
            isReconcilingSidebar = false
            restoreSidebarSelectionVisual()
        }
    }

    private func instrumentComponentExistsInSidebar(sessionID: UUID, instrumentID: UUID, componentID: UUID) -> Bool {
        instrumentChildKeyByComponent[
            InstrumentComponentReference(instrumentID: instrumentID, componentID: componentID)
        ] != nil
    }

    func navigate(to target: LumaCore.NavigationTarget) {
        switch target {
        case .instrumentComponent(let sessionID, let instrumentID, let componentID):
            navigateToInstrumentComponent(sessionID: sessionID, instrumentID: instrumentID, componentID: componentID)
        case .itrace(let sessionID, let traceID):
            select(.itrace(sessionID: sessionID, traceID: traceID))
        }
    }

    private func select(_ newValue: SidebarSelection) {
        guard selection != newValue else { return }
        selection = newValue
        switch newValue {
        case .notebook:
            sessionsList.unselectAll()
            packagesList.unselectAll()
            customInstrumentsList.unselectAll()
            missionsListBox.unselectAll()
            notebookListBox.select(row: notebookRow)
        case .session, .repl, .instrument, .instrumentComponent, .insight, .itrace:
            notebookListBox.unselectAll()
            packagesList.unselectAll()
            customInstrumentsList.unselectAll()
            missionsListBox.unselectAll()
            if let idx = currentSelectionRowIndex(),
                let row = sessionsList.getRowAt(index: idx)
            {
                selectSessionsRow(row)
            }
        case .package:
            notebookListBox.unselectAll()
            sessionsList.unselectAll()
            customInstrumentsList.unselectAll()
            missionsListBox.unselectAll()
        case .customInstrumentDef(let defID):
            notebookListBox.unselectAll()
            sessionsList.unselectAll()
            packagesList.unselectAll()
            missionsListBox.unselectAll()
            if let def = engine?.customInstruments.def(withId: defID),
                let idx = customInstrumentRows.firstIndex(of: .file(defID: defID, path: def.entrypoint)),
                let row = customInstrumentsList.getRowAt(index: idx)
            {
                customInstrumentsList.select(row: row)
            }
        case .customInstrumentFile(let defID, let path):
            notebookListBox.unselectAll()
            sessionsList.unselectAll()
            packagesList.unselectAll()
            missionsListBox.unselectAll()
            if let idx = customInstrumentRows.firstIndex(of: .file(defID: defID, path: path)),
                let row = customInstrumentsList.getRowAt(index: idx)
            {
                customInstrumentsList.select(row: row)
            }
        case .missionsList:
            notebookListBox.unselectAll()
            sessionsList.unselectAll()
            packagesList.unselectAll()
            customInstrumentsList.unselectAll()
            missionsListBox.select(row: missionsHeaderRow)
        case .mission(let id):
            notebookListBox.unselectAll()
            sessionsList.unselectAll()
            packagesList.unselectAll()
            customInstrumentsList.unselectAll()
            if let idx = missionRowIDs.firstIndex(of: id),
                let row = missionsListBox.getRowAt(index: idx + 1)
            {
                missionsListBox.select(row: row)
            }
        }
        updateResumeButtonVisibility()
        renderDetail()
        switch newValue {
        case .instrument:
            currentInstrumentDetail?.showConfigurationView()
        case .instrumentComponent(_, _, let componentID):
            currentInstrumentDetail?.selectComponent(id: componentID)
        default:
            break
        }
        focusEditorIfNeeded(for: newValue)
    }

    private func focusEditorIfNeeded(for selection: SidebarSelection) {
        switch selection {
        case .customInstrumentDef, .customInstrumentFile:
            sharedCustomInstrumentEditor.focus()
        default:
            break
        }
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
            sessionArmIcons[session.id]?.visible = isArmed(session)
            refreshDetachedIndicator(for: session)
            if currentREPLSessionID == session.id {
                currentREPLPane?.applySessionState()
            }
            currentInstrumentDetail?.applySessionState()
            currentInsightDetail?.applySessionState()
            sessionDetailViews[session.id]?.applySessionState()
            updateResumeButtonVisibility()
        case .sessionRemoved(let id):
            removeSessionRows(id)
            sessions.removeAll { $0.id == id }
            for instrument in instrumentsBySession[id] ?? [] {
                instrumentRowLabels.removeValue(forKey: instrument.id)
                instrumentRowIconHosts.removeValue(forKey: instrument.id)
                instrumentRowWarningHosts.removeValue(forKey: instrument.id)
            }
            instrumentsBySession.removeValue(forKey: id)
            insightsBySession.removeValue(forKey: id)
            for trace in tracesBySession[id] ?? [] {
                traceRowIcons.removeValue(forKey: trace.id)
            }
            tracesBySession.removeValue(forKey: id)
            sessionDetailViews.removeValue(forKey: id)
            sessionNameLabels.removeValue(forKey: id)
            sessionDeviceLabels.removeValue(forKey: id)
            sessionArmIcons.removeValue(forKey: id)
            sessionDetachedHosts.removeValue(forKey: id)
            sessionChevronImages.removeValue(forKey: id)
            switch selection {
            case .session(let sid),
                .repl(let sid),
                .instrument(let sid, _),
                .instrumentComponent(let sid, _, _),
                .insight(let sid, _),
                .itrace(let sid, _):
                if sid == id {
                    select(.notebook)
                    notebookListBox.select(row: notebookRow)
                }
            default: break
            }
        case .instrumentAdded(let instrument):
            instrumentsBySession[instrument.sessionID, default: []].append(instrument)
            insertChildRow(makeInstrumentRow(instrument), kind: .instrument(sessionID: instrument.sessionID, instrumentID: instrument.id), sessionID: instrument.sessionID)
            reconcileInstrumentChildren(for: instrument)
        case .instrumentUpdated(let instrument):
            if let arr = instrumentsBySession[instrument.sessionID],
                let i = arr.firstIndex(where: { $0.id == instrument.id })
            {
                instrumentsBySession[instrument.sessionID]![i] = instrument
            }
            if let warningHost = instrumentRowWarningHosts[instrument.id] {
                populateStatusWarning(host: warningHost, status: instrumentRuntimeStatus(for: instrument))
            }
            reconcileInstrumentChildren(for: instrument)
            if let detail = currentInstrumentDetail, detail.instrumentID == instrument.id {
                detail.update(instrument)
            }
        case .instrumentRemoved(let id, let sessionID):
            instrumentsBySession[sessionID]?.removeAll { $0.id == id }
            instrumentRowLabels.removeValue(forKey: id)
            instrumentRowIconHosts.removeValue(forKey: id)
            instrumentRowWarningHosts.removeValue(forKey: id)
            removeInstrumentChildRows(sessionID: sessionID, instrumentID: id)
            removeChildRow(kind: .instrument(sessionID: sessionID, instrumentID: id))
            if case .instrumentComponent(let sid, let iid, _) = selection, sid == sessionID, iid == id {
                select(.session(sessionID))
            }
        case .insightAdded(let insight):
            insightsBySession[insight.sessionID, default: []].append(insight)
            insertChildRow(makeInsightRow(insight), kind: .insight(sessionID: insight.sessionID, insightID: insight.id), sessionID: insight.sessionID)
        case .insightRemoved(let id, let sessionID):
            insightsBySession[sessionID]?.removeAll { $0.id == id }
            removeChildRow(kind: .insight(sessionID: sessionID, insightID: id))
            if case .insight(_, let iid) = selection, iid == id {
                select(.session(sessionID))
            }
        case .traceUpdated(let trace):
            upsertTrace(trace)
        case .traceRemoved(let id, let sessionID):
            tracesBySession[sessionID]?.removeAll { $0.id == id }
            traceRowIcons.removeValue(forKey: id)
            removeChildRow(kind: .itrace(sessionID: sessionID, traceID: id))
            if case .itrace(_, let tid) = selection, tid == id {
                select(.session(sessionID))
            }
        case .descriptorsChanged, .customInstrumentDefsChanged:
            refreshInstrumentRowVisuals()
        }
        sessionsHeaderLabel?.label = "Sessions (\(sessions.count))"
        sessionsSection?.visible = !sessions.isEmpty
    }

    private func insertSessionRows(_ session: LumaCore.ProcessSession, at sessionIndex: Int) {
        var pos = 0
        for i in 0..<sessionIndex {
            pos += rowCount(forSessionID: sessions[i].id)
        }

        let headerRow = ListBoxRow()
        let headerBox = Box(orientation: .horizontal, spacing: 0)
        headerBox.marginStart = MainWindow.sidebarRowLeadingPad
        headerBox.marginEnd = 3
        headerBox.marginTop = 4
        headerBox.marginBottom = 4

        let expansion = engine?.sidebarExpansion(forSessionID: session.id) ?? .expanded
        let chevron = makeSessionChevron(expansion: expansion) { [weak self] in
            self?.toggleSessionExpansion(sessionID: session.id)
        }
        sessionChevronImages[session.id] = chevron.image
        chevron.button.marginEnd = MainWindow.sidebarChevronToIconSpacing
        headerBox.append(child: chevron.button)

        let icon = makeSessionIcon(for: session, node: engine?.node(forSessionID: session.id))
        icon.marginEnd = MainWindow.sidebarIconToLabelSpacing
        headerBox.append(child: icon)

        let titles = Box(orientation: .vertical, spacing: 2)
        titles.halign = .start
        titles.hexpand = true
        let nameRow = Box(orientation: .horizontal, spacing: 4)
        let nameLabel = Label(str: session.processName)
        nameLabel.halign = .start
        nameLabel.add(cssClass: "title-4")
        nameRow.append(child: nameLabel)
        let armIcon = Gtk.Image(iconName: "find-location-symbolic")
        armIcon.pixelSize = 12
        armIcon.add(cssClass: "accent")
        armIcon.tooltipText = "Armed for next matching launch"
        armIcon.visible = isArmed(session)
        nameRow.append(child: armIcon)
        titles.append(child: nameRow)
        let deviceLabel = Label(str: session.deviceName)
        deviceLabel.halign = .start
        deviceLabel.add(cssClass: "caption")
        deviceLabel.add(cssClass: "dim-label")
        titles.append(child: deviceLabel)
        headerBox.append(child: titles)

        let detachedHost = Box(orientation: .horizontal, spacing: 0)
        detachedHost.valign = .center
        headerBox.append(child: detachedHost)

        sessionNameLabels[session.id] = nameLabel
        sessionDeviceLabels[session.id] = deviceLabel
        sessionArmIcons[session.id] = armIcon
        sessionDetachedHosts[session.id] = detachedHost
        refreshDetachedIndicator(for: session)

        headerRow.set(child: headerBox)
        attachSessionContextMenu(row: headerRow, anchor: headerBox, session: session)
        sessionsList.insert(child: headerRow, position: pos)
        sessionsRowKinds.insert(.session(session.id), at: pos)

        let replRow = ListBoxRow()
        let (replBox, replIconHost) = MainWindow.makeChildRowBox()
        let replIcon = Gtk.Image(iconName: "utilities-terminal-symbolic")
        replIcon.pixelSize = 16
        MainWindow.centerInIconHost(replIcon)
        replIconHost.append(child: replIcon)
        let replLabel = Label(str: "REPL")
        replLabel.halign = .start
        replBox.append(child: replLabel)
        replRow.set(child: replBox)
        replRow.visible = expansion == .expanded
        sessionsList.insert(child: replRow, position: pos + 1)
        sessionsRowKinds.insert(.repl(session.id), at: pos + 1)
    }

    private func makeSessionChevron(
        expansion: SidebarExpansion,
        onToggle: @escaping () -> Void
    ) -> (button: Button, image: Gtk.Image) {
        let image = Gtk.Image(iconName: chevronIconName(for: expansion))
        image.pixelSize = 12
        image.add(cssClass: "dim-label")
        let button = Button()
        button.set(child: image)
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-sidebar-chevron")
        button.valign = .center
        button.tooltipText = "Toggle session"
        button.onClicked { _ in
            MainActor.assumeIsolated { onToggle() }
        }
        return (button, image)
    }

    private func chevronIconName(for expansion: SidebarExpansion) -> String {
        expansion == .expanded ? "pan-down-symbolic" : "pan-end-symbolic"
    }

    private func toggleSessionExpansion(sessionID: UUID) {
        guard let engine else { return }
        let current = engine.sidebarExpansion(forSessionID: sessionID)
        setSessionExpansion(sessionID: sessionID, current == .expanded ? .collapsed : .expanded)
    }

    private func setSessionExpansion(sessionID: UUID, _ expansion: SidebarExpansion) {
        guard let engine else { return }
        engine.setSidebarExpansion(sessionID: sessionID, expansion)
        sessionChevronImages[sessionID]?.setFrom(iconName: chevronIconName(for: expansion))
        for (index, kind) in sessionsRowKinds.enumerated() {
            guard kind.sessionID == sessionID,
                let row = sessionsList.getRowAt(index: index)
            else { continue }
            if case .session = kind { continue }
            row.visible = expansion == .expanded
        }
    }

    private func applySessionExpansionVisibility(row: ListBoxRow, sessionID: UUID) {
        let expansion = engine?.sidebarExpansion(forSessionID: sessionID) ?? .expanded
        row.visible = expansion == .expanded
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
        applySessionExpansionVisibility(row: row, sessionID: sessionID)
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
            case .instrument, .instrumentChild: return 2
            case .insight: return 3
            case .itrace: return 4
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

    private func activeInstrumentID(in selection: SidebarSelection) -> UUID? {
        switch selection {
        case .instrument(_, let iid):
            return iid
        case .instrumentComponent(_, let iid, _):
            return iid
        default:
            return nil
        }
    }

    private func reconcileInstrumentChildren(for instrument: LumaCore.InstrumentInstance) {
        let outerGuard = isReconcilingSidebar
        isReconcilingSidebar = true
        defer {
            if !outerGuard {
                isReconcilingSidebar = false
                restoreSidebarSelectionVisual()
            }
        }

        removeInstrumentChildRows(sessionID: instrument.sessionID, instrumentID: instrument.id)
        guard let engine else { return }

        let children = InstrumentUIRegistry.shared
            .ui(for: instrument.kind)
            .makeSidebarChildren(engine: engine, instrument: instrument, host: self)
        guard !children.isEmpty else { return }

        guard let instrumentIndex = sessionsRowKinds.firstIndex(where: { row in
            if case .instrument(let sid, let iid) = row {
                return sid == instrument.sessionID && iid == instrument.id
            }
            return false
        }) else { return }

        var insertAt = instrumentIndex + 1
        for child in children {
            applySessionExpansionVisibility(row: child.row, sessionID: instrument.sessionID)
            sessionsList.insert(child: child.row, position: insertAt)
            sessionsRowKinds.insert(
                .instrumentChild(sessionID: instrument.sessionID, instrumentID: instrument.id, key: child.key),
                at: insertAt
            )
            instrumentChildActions[instrumentChildActionKey(instrumentID: instrument.id, key: child.key)] = child.onActivate
            if let componentID = child.componentID {
                instrumentChildKeyByComponent[InstrumentComponentReference(instrumentID: instrument.id, componentID: componentID)] = child.key
            }
            insertAt += 1
        }
    }

    private func restoreSidebarSelectionVisual() {
        guard let idx = currentSelectionRowIndex(),
            let row = sessionsList.getRowAt(index: idx)
        else { return }
        selectSessionsRow(row)
    }

    private func selectSessionsRow<T: ListBoxRowProtocol>(_ row: T) {
        let wasGuarded = isReconcilingSidebar
        isReconcilingSidebar = true
        sessionsList.select(row: row)
        if !wasGuarded {
            isReconcilingSidebar = false
        }
    }

    private func removeInstrumentChildRows(sessionID: UUID, instrumentID: UUID) {
        var index = 0
        while index < sessionsRowKinds.count {
            if case .instrumentChild(let sid, let iid, let key) = sessionsRowKinds[index],
                sid == sessionID, iid == instrumentID
            {
                if let row = sessionsList.getRowAt(index: index) {
                    sessionsList.remove(child: row)
                }
                sessionsRowKinds.remove(at: index)
                instrumentChildActions.removeValue(forKey: instrumentChildActionKey(instrumentID: instrumentID, key: key))
            } else {
                index += 1
            }
        }
        instrumentChildKeyByComponent = instrumentChildKeyByComponent.filter { $0.key.instrumentID != instrumentID }
    }

    private func activateInstrumentChild(sessionID: UUID, instrumentID: UUID, key: String) {
        let actionKey = instrumentChildActionKey(instrumentID: instrumentID, key: key)
        instrumentChildActions[actionKey]?()
    }

    private func instrumentChildActionKey(instrumentID: UUID, key: String) -> String {
        "\(instrumentID.uuidString)/\(key)"
    }

    private static let sidebarRowLeadingPad = 3
    private static let sidebarChevronColumnWidth = 24
    private static let sidebarChevronToIconSpacing = 5
    private static let sidebarIconColumnWidth = 24
    private static let sidebarIconToLabelSpacing = 6
    private static let sidebarChildIconColumnWidth = 16
    static let sessionChildMarginStart = sidebarRowLeadingPad
        + sidebarChevronColumnWidth
        + sidebarChevronToIconSpacing
        + sidebarIconColumnWidth
    static let sessionGrandchildMarginStart = sessionChildMarginStart + sidebarChildIconColumnWidth

    private static func makeChildRowBox() -> (rowBox: Box, iconHost: Box) {
        let rowBox = Box(orientation: .horizontal, spacing: sidebarIconToLabelSpacing)
        rowBox.halign = .start
        rowBox.marginStart = sessionChildMarginStart
        rowBox.marginEnd = 12
        rowBox.marginTop = 2
        rowBox.marginBottom = 2
        let iconHost = makeChildIconHost()
        rowBox.append(child: iconHost)
        return (rowBox, iconHost)
    }

    private static func makeParentIconHost() -> Box {
        makeFixedWidthIconHost(width: sidebarIconColumnWidth)
    }

    private static func makeChildIconHost() -> Box {
        makeFixedWidthIconHost(width: sidebarChildIconColumnWidth)
    }

    private static func makeFixedWidthIconHost(width: Int) -> Box {
        let iconHost = Box(orientation: .horizontal, spacing: 0)
        iconHost.setSizeRequest(width: width, height: -1)
        iconHost.hexpand = false
        return iconHost
    }

    private static func centerInIconHost<T: WidgetProtocol>(_ icon: T) {
        icon.hexpand = true
        icon.halign = .center
    }

    private func makeInstrumentRow(_ instrument: LumaCore.InstrumentInstance) -> ListBoxRow {
        let row = ListBoxRow()
        let descriptor = engine!.descriptor(for: instrument)
        let (rowBox, iconHost) = MainWindow.makeChildRowBox()
        let instrumentImage = InstrumentIconView.makeImage(for: descriptor.icon, pixelSize: 16)
        MainWindow.centerInIconHost(instrumentImage)
        iconHost.append(child: instrumentImage)
        let ilabel = Label(str: descriptor.displayName)
        ilabel.halign = .start
        rowBox.append(child: ilabel)
        let warningHost = Box(orientation: .horizontal, spacing: 0)
        rowBox.append(child: warningHost)
        populateStatusWarning(host: warningHost, status: instrumentRuntimeStatus(for: instrument))
        instrumentRowLabels[instrument.id] = ilabel
        instrumentRowIconHosts[instrument.id] = iconHost
        instrumentRowWarningHosts[instrument.id] = warningHost
        if instrument.state == .disabled {
            rowBox.opacity = 0.3
        }
        row.set(child: rowBox)
        attachInstrumentContextMenu(row: row, anchor: rowBox, instrument: instrument)
        return row
    }

    private func instrumentRuntimeStatus(for instrument: LumaCore.InstrumentInstance) -> InstrumentStatus? {
        guard let node = engine?.node(forSessionID: instrument.sessionID) else { return nil }
        return node.instruments.first(where: { $0.id == instrument.id })?.status
    }

    private func makeInsightRow(_ insight: LumaCore.AddressInsight) -> ListBoxRow {
        let row = ListBoxRow()
        let (rowBox, iconHost) = MainWindow.makeChildRowBox()
        let iconName = insight.kind == .memory ? "memorychip-symbolic" : "cpu-symbolic"
        let iconImage = Gtk.Image(iconName: iconName)
        iconImage.pixelSize = 16
        MainWindow.centerInIconHost(iconImage)
        iconHost.append(child: iconImage)
        let lbl = Label(str: insight.title)
        lbl.halign = .start
        rowBox.append(child: lbl)
        row.set(child: rowBox)
        attachInsightContextMenu(row: row, anchor: rowBox, insight: insight)
        return row
    }

    private func makeTraceRow(_ trace: LumaCore.ITrace) -> ListBoxRow {
        let row = ListBoxRow()
        let (rowBox, iconHost) = MainWindow.makeChildRowBox()
        let iconImage = Gtk.Image(iconName: traceIconName(for: trace))
        iconImage.pixelSize = 16
        MainWindow.centerInIconHost(iconImage)
        traceRowIcons[trace.id] = iconImage
        iconHost.append(child: iconImage)
        let lbl = Label(str: trace.displayName)
        lbl.halign = .start
        rowBox.append(child: lbl)
        row.set(child: rowBox)
        attachTraceContextMenu(row: row, anchor: rowBox, trace: trace)
        return row
    }

    private func traceIconName(for trace: LumaCore.ITrace) -> String {
        trace.isRunning ? "media-record-symbolic" : "system-run-symbolic"
    }

    private func upsertTrace(_ trace: LumaCore.ITrace) {
        var traces = tracesBySession[trace.sessionID] ?? []
        if let idx = traces.firstIndex(where: { $0.id == trace.id }) {
            traces[idx] = trace
            tracesBySession[trace.sessionID] = traces
            traceRowIcons[trace.id]?.set(name: traceIconName(for: trace))
            if let detail = currentITraceDetail, currentITraceID == trace.id {
                detail.update(with: trace)
            }
            return
        }
        traces.append(trace)
        tracesBySession[trace.sessionID] = traces
        insertChildRow(
            makeTraceRow(trace),
            kind: .itrace(sessionID: trace.sessionID, traceID: trace.id),
            sessionID: trace.sessionID
        )
    }

    private func makeSessionIcon(
        for session: LumaCore.ProcessSession,
        node: LumaCore.ProcessNode?
    ) -> Widget {
        let pixelSize = 24

        if let lastIcon = node?.processIcons.last,
            let image = IconPixbuf.makeImage(from: lastIcon, pixelSize: pixelSize)
        {
            image.add(cssClass: "luma-session-icon")
            return image
        }

        if let data = session.iconPNGData,
            let image = IconPixbuf.makeImage(fromPNGData: data, pixelSize: pixelSize)
        {
            image.add(cssClass: "luma-session-icon")
            return image
        }

        return IconPlaceholderView.make(
            seed: "\(session.deviceID)/\(session.processName)",
            displayName: session.processName,
            pixelSize: pixelSize
        )
    }

    private func makeHostAvatar(
        host: LumaCore.CollaborationSession.UserInfo,
        size: Int
    ) -> Widget {
        let displayName = host.name.isEmpty ? "@\(host.id)" : host.name
        let avatar = Adw.Avatar(size: size, text: displayName, showInitials: true)
        avatar.tooltipText = displayName
        if let url = host.avatarURL.flatMap({ URL(string: "\($0.absoluteString)&s=\(size * 2)") }) {
            Task { @MainActor [avatar] in
                guard let texture = await AvatarCache.shared.texture(for: url) else { return }
                avatar.set(customImage: texture)
            }
        }
        return avatar
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
        if engine?.localUserHosts(session.id) == false {
            if engine?.collaboration.isOwner == true {
                ContextMenu.present([
                    [.init("Run on My Device…") { [weak self] in
                        self?.rehost(sessionID: session.id)
                    }]
                ], at: anchor, x: x, y: y)
            }
            return
        }

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
        } else if session.lastAttachedAt != nil {
            topSection.append(.init("Reestablish…") { [weak self] in
                self?.reestablishSession(id: session.id)
            })
        }

        let armingItem: ContextMenu.Item
        if isArmed(session) {
            armingItem = .init("Disarm") { [weak self] in self?.disarm(sessionID: session.id) }
        } else {
            armingItem = .init("Arm for Next Launch…") { [weak self] in self?.presentArmDialog(session: session) }
        }

        ContextMenu.present([
            topSection,
            [armingItem],
            [.init("Delete Session", destructive: true) { [weak self] in self?.confirmDeleteSession(session) }],
        ], at: anchor, x: x, y: y)
    }

    private func isArmed(_ session: LumaCore.ProcessSession) -> Bool {
        if case .armed = session.armingState { return true }
        return false
    }

    private func refreshDetachedIndicator(for session: LumaCore.ProcessSession) {
        guard let host = sessionDetachedHosts[session.id] else { return }
        if let rootPtr = host.root?.ptr {
            Gtk.WindowRef(raw: rootPtr).focus = nil
        }
        var child = host.firstChild
        while let cur = child {
            child = cur.nextSibling
            host.remove(child: cur)
        }

        if let badge = makeHostBadge(for: session) {
            host.append(child: badge)
        }

        guard shouldShowDetachedIndicator(session) else { return }
        if session.phase == .attaching {
            let spinner = Adw.Spinner()
            spinner.tooltipText = "\(session.kind.reestablishLabel)ing\u{2026}"
            host.append(child: spinner)
            return
        }
        let icon = Gtk.Image(iconName: "view-refresh-symbolic")
        icon.pixelSize = 14
        icon.add(cssClass: detachedTintCssClass(for: session))
        let button = Button()
        button.set(child: icon)
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-sidebar-detached")
        button.valign = .center
        button.tooltipText = "\(session.kind.reestablishLabel)\u{2026}"
        let sessionID = session.id
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.reestablishSession(id: sessionID) }
        }
        host.append(child: button)
    }

    private func makeHostBadge(for session: LumaCore.ProcessSession) -> Widget? {
        guard let engine,
              let host = session.host,
              engine.node(forSessionID: session.id) == nil
        else { return nil }
        let avatar = makeHostAvatar(host: host, size: 18)
        let tooltip: String
        if host.id == engine.collaboration.localUser?.id {
            tooltip = "Hosted by you on \(session.deviceName)"
        } else {
            tooltip = "Hosted by @\(host.id) on \(session.deviceName)"
        }
        avatar.tooltipText = tooltip
        return avatar
    }

    private func shouldShowDetachedIndicator(_ session: LumaCore.ProcessSession) -> Bool {
        guard engine?.node(forSessionID: session.id) == nil, !isArmed(session) else { return false }
        if session.lastAttachedAt != nil { return true }
        if case .attach = session.kind { return true }
        return false
    }

    private func detachedTintCssClass(for session: LumaCore.ProcessSession) -> String {
        switch session.detachReason {
        case .applicationRequested:
            return "warning"
        default:
            return "error"
        }
    }

    private func disarm(sessionID: UUID) {
        guard let engine else { return }
        Task { @MainActor in
            await engine.disarmSession(id: sessionID)
        }
    }

    func presentArmDialog(session: LumaCore.ProcessSession) {
        guard let engine else { return }
        let initialPattern = engine.defaultArmPattern(for: session)

        let dialog = Adw.Dialog()
        dialog.set(title: "Arm for Next Launch")
        dialog.set(contentWidth: 480)

        let headerBar = Adw.HeaderBar()
        let armActionButton = Button(label: "Arm")
        armActionButton.add(cssClass: "suggested-action")
        headerBar.packEnd(child: armActionButton)

        let body = Box(orientation: .vertical, spacing: 8)
        body.marginStart = 16
        body.marginEnd = 16
        body.marginTop = 12
        body.marginBottom = 12

        let intro = Label(str: "Match the next spawn whose identifier matches this regex on \(session.deviceName).")
        intro.halign = .start
        intro.add(cssClass: "dim-label")
        intro.wrap = true
        body.append(child: intro)

        let regexEntry = Entry()
        regexEntry.text = initialPattern
        regexEntry.hexpand = true
        body.append(child: regexEntry)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: headerBar)
        toolbarView.set(content: body)
        dialog.set(child: toolbarView)

        let dialogKey = ObjectIdentifier(dialog)
        MainWindow.armDialogRetainer[dialogKey] = dialog
        dialog.onClosed { _ in
            MainActor.assumeIsolated {
                MainWindow.armDialogRetainer[dialogKey] = nil
            }
        }

        let sessionID = session.id
        armActionButton.onClicked { [weak self, weak dialog, regexEntry] _ in
            MainActor.assumeIsolated {
                let pattern = regexEntry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pattern.isEmpty else { return }
                Task { @MainActor in
                    await self?.engine?.armSession(id: sessionID, matchPattern: pattern)
                }
                _ = dialog?.close()
            }
        }

        dialog.present(parent: window)
    }

    private static var armDialogRetainer: [ObjectIdentifier: Adw.Dialog] = [:]

    private func rehost(sessionID: UUID) {
        guard let engine else { return }
        Task { @MainActor in
            let result = await engine.reHost(sessionID: sessionID)
            if case .needsUserInput(let reason, let session) = result {
                self.openTargetPicker(reusing: session, reason: reason)
            }
        }
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
        let toggleLabel = instrument.state == .enabled ? "Disable" : "Enable"
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

    private func attachTraceContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        trace: LumaCore.ITrace
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentTraceContextMenu(anchor: anchor, x: x, y: y, trace: trace)
            }
        }
        row.install(controller: click)
    }

    private func presentTraceContextMenu(
        anchor: Widget,
        x: Double,
        y: Double,
        trace: LumaCore.ITrace
    ) {
        ContextMenu.present([
            [.init("Delete Trace", destructive: true) { [weak self] in self?.confirmDeleteTrace(trace) }],
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
            Task { @MainActor in
                do {
                    try await node.kill()
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
        let title = engine?.descriptor(for: instrument).displayName ?? "Instrument"
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

    private func confirmDeleteTrace(_ trace: LumaCore.ITrace) {
        confirmDestructive(
            message: "Delete trace \(trace.displayName)?",
            detail: "This removes the recorded ITrace data from the project.",
            destructiveLabel: "Delete"
        ) { [weak self] in
            self?.engine?.deleteITrace(id: trace.id, sessionID: trace.sessionID)
            self?.showToast("Deleted trace")
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
        case .instrumentComponent(_, let instrumentID, let componentID):
            guard let key = instrumentChildKeyByComponent[
                InstrumentComponentReference(instrumentID: instrumentID, componentID: componentID)
            ] else { return nil }
            return sessionsRowKinds.firstIndex {
                if case .instrumentChild(_, let iid, let k) = $0 {
                    return iid == instrumentID && k == key
                }
                return false
            }
        case .insight(_, let id):
            return sessionsRowKinds.firstIndex {
                if case .insight(_, let i) = $0 { return i == id }
                return false
            }
        case .itrace(_, let id):
            return sessionsRowKinds.firstIndex {
                if case .itrace(_, let t) = $0 { return t == id }
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
        packagesHeaderLabel?.label = "Packages (\(snapshot.count))"
        packagesSidebarSection?.visible = !snapshot.isEmpty
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

    private func makeSharedCustomInstrumentEditor() -> MonacoEditor {
        let packages = (try? engine?.store.fetchPackagesState().packages) ?? []
        return MonacoEditor(profile: EditorProfile.fridaCustomInstrument(packages: packages))
    }
}

@MainActor
fileprivate final class HookPackExportContext {
    let window: MainWindow
    let def: LumaCore.CustomInstrumentDef

    init(window: MainWindow, def: LumaCore.CustomInstrumentDef) {
        self.window = window
        self.def = def
    }

    static func suggestedFilename(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        let slug = trimmed.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(slug).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "hookpack" : collapsed
    }
}

private let hookPackExportPathThunk: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let context = Unmanaged<HookPackExportContext>.fromOpaque(userData).takeRetainedValue()
    guard let pathPtr else { return }
    let path = String(cString: pathPtr)
    Task { @MainActor in
        context.window.handleHookPackExport(def: context.def, path: path)
    }
}

extension InstrumentStatus {
    var gtkIconName: String {
        switch self {
        case .incompatible:
            return "dialog-warning-symbolic"
        case .loadFailed, .reloadFailed, .configInvalid:
            return "dialog-error-symbolic"
        }
    }
}
