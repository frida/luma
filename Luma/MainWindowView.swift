import Frida
import SwiftUI
import LumaCore
#if canImport(AppKit)
    import AppKit
#endif

struct MainWindowView: View {
    @Binding private var document: LumaProject
    private let projectURL: URL
    private let fileURL: URL?

    @State private var engineResult: Result<Engine, any Swift.Error>
    @State private var picker = TargetPicker()
    @State private var isShowingHostingBlockedAlert = false

    init(document: Binding<LumaProject>, fileURL: URL? = nil) {
        self._document = document
        self.projectURL = document.wrappedValue.workingProjectURL
        self.fileURL = fileURL
        let result: Result<Engine, any Swift.Error>
        do {
            let engine = try EngineRegistry.shared.engine(
                for: projectURL,
                dataDirectory: LumaAppPaths.shared.dataDirectory,
                gitHubAuth: sharedGitHubAuth()
            )
            result = .success(engine)
        } catch {
            result = .failure(error)
        }
        self._engineResult = State(initialValue: result)
    }

    var body: some View {
        switch engineResult {
        case .success(let engine):
            ProjectContentView(
                engine: engine,
                picker: picker,
                projectURL: projectURL,
                restorationPath: restorationPath,
                markDocumentEdited: { document.unsavedChangeCount &+= 1 },
                isShowingHostingBlockedAlert: $isShowingHostingBlockedAlert
            )
        case .failure(let error):
            VStack(spacing: 12) {
                Text("Failed to open project")
                    .font(.title3)
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(minWidth: 480, minHeight: 240)
        }
    }

    private var restorationPath: String {
        (fileURL ?? projectURL).path
    }
}

private struct ProjectContentView: View {
    let engine: Engine
    let picker: TargetPicker
    let projectURL: URL
    let restorationPath: String
    let markDocumentEdited: () -> Void

    @Binding var isShowingHostingBlockedAlert: Bool

    @State private var availableHeight: CGFloat = 800
    @State private var dragStartHeight: Double?
    @State private var maxSidePanelWidth: CGFloat = Self.sidePanelWidthRange.upperBound
    @State private var sidePanelWidth: CGFloat = 300
    @State private var sidePanelResizingFrom: CGFloat?

    private static let collapsedEventStreamHeight: CGFloat = 32
    private static let minEventStreamHeight: Double = 120
    private static let minMainContentHeight: CGFloat = 160
    private static let minDetailWidth: CGFloat = 480
    private static let sidePanelWidthRange: ClosedRange<CGFloat> = 260...520

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(engine: engine, selection: selection)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
            } detail: {
                detailWithSidePanel
            }
            .sheet(
                item: Binding(
                    get: { picker.context },
                    set: { newValue in
                        Task { @MainActor in
                            picker.context = newValue
                        }
                    }
                ),
                onDismiss: {
                    picker.context = nil
                },
                content: { context in
                    targetPickerSheet(context: context)
                }
            )
            .toolbarRole(.editor)
            .toolbar {
                ProjectToolbar(
                    engine: engine,
                    picker: picker,
                    selection: selection,
                    isShowingHostingBlockedAlert: $isShowingHostingBlockedAlert
                )
            }
            #if os(macOS)
                .toolbarBackground(.hidden, for: .windowToolbar)
            #endif
            .alert(
                "Only lab owners can host sessions",
                isPresented: $isShowingHostingBlockedAlert
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You're a member of this lab. Ask an owner to promote you before starting a session.")
            }
            .frame(minHeight: Self.minMainContentHeight, maxHeight: .infinity, alignment: .topLeading)
            .environment(picker)
            .task {
                await EngineRegistry.shared.startIfNeeded(for: projectURL)
                engine.attachInstrumentUIs()
                #if os(macOS)
                    engine.attachLocalNotifier()
                #endif
                if engine.collaboration.isCollaborative {
                    engine.setSidePanel(.collaboration)
                }
                if engine.selectedSidebarItem == nil {
                    engine.selectedSidebarItem = .notebook
                }
            }
            .onChange(of: restorationPath, initial: true) { _, newPath in
                LumaAppState.shared.lastDocumentPath = newPath
            }
            .onDisappear {
                let url = projectURL
                Task { @MainActor in
                    await EngineRegistry.shared.release(workingProjectURL: url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ProjectStore.didCommitNotification)) { note in
                guard let id = note.userInfo?["instanceID"] as? UUID,
                    id == engine.store.instanceID
                else { return }
                markDocumentEdited()
            }
            eventStreamBottomBar
        }
        .frame(
            minWidth: 900,
            idealWidth: 1100,
            maxWidth: .infinity,
            minHeight: 600,
            idealHeight: 680,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) { _, height in
                        availableHeight = height
                    }
            }
        }
    }

    private var selection: Binding<SidebarItemID?> {
        Binding(
            get: { engine.selectedSidebarItem },
            set: { engine.selectedSidebarItem = $0 }
        )
    }

    private var detailWithSidePanel: some View {
        HStack(spacing: 0) {
            DetailView(engine: engine, selection: selection)
                .frame(maxWidth: .infinity)
                .clipped()

            if let panel = engine.projectUIState.sidePanel {
                Divider()
                sidePanel(panel)
                    .frame(width: displayedSidePanelWidth)
                    .overlay(alignment: .leading) { sidePanelResizeHandle }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { Self.maxSidePanelWidth(forDetailWidth: $0.size.width) } action: {
            maxSidePanelWidth = $0
        }
    }

    @ViewBuilder
    private func sidePanel(_ panel: SidePanel) -> some View {
        switch panel {
        case .collaboration:
            CollaborationPanel(engine: engine)
        case .virtualMachines:
            #if canImport(AppKit)
            VirtualMachinePanel(engine: engine)
            #endif
        }
    }

    private var displayedSidePanelWidth: CGFloat {
        min(sidePanelWidth, maxSidePanelWidth)
    }

    private var sidePanelResizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .platformPointer(.columnResize)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { drag in
                        let base = sidePanelResizingFrom ?? displayedSidePanelWidth
                        sidePanelResizingFrom = base
                        sidePanelWidth = min(max(base - drag.translation.width, Self.sidePanelWidthRange.lowerBound), maxSidePanelWidth)
                    }
                    .onEnded { _ in sidePanelResizingFrom = nil })
    }

    private static func maxSidePanelWidth(forDetailWidth detailWidth: CGFloat) -> CGFloat {
        let range = sidePanelWidthRange
        return min(max(detailWidth - minDetailWidth, range.lowerBound), range.upperBound)
    }

    private func targetPickerSheet(context: TargetPickerContext) -> some View {
        TargetPickerView(
            engine: engine,
            deviceManager: engine.deviceManager,
            reason: {
                if case .reestablish(_, let reason) = context {
                    reason
                } else {
                    nil
                }
            }(),
            onSpawn: handleSpawn(device:config:),
            onAttach: handleAttach(device:proc:),
            onArm: handleArm(device:config:regex:)
        )
    }

    private func handleSpawn(device: Device, config: SpawnConfig) {
        Task { @MainActor in
            let session = engine.prepareSpawnSession(device: device, config: config)
            engine.selectedSidebarItem = .session(session.id)
            _ = try? await engine.spawnAndAttach(device: device, session: session)
        }
    }

    private func handleArm(device: Device, config: SpawnConfig, regex: String) {
        Task { @MainActor in
            let session = await engine.armNewSession(
                device: device,
                config: config,
                matchPattern: regex
            )
            engine.selectedSidebarItem = .session(session.id)
        }
    }

    private func handleAttach(device: Device, proc: ProcessDetails) {
        let pickerContext = picker.context

        Task { @MainActor in
            if let existingNode = engine.processNodes.first(where: {
                $0.deviceID == device.id && $0.pid == proc.pid
            }) {
                engine.selectedSidebarItem = .session(engine.sessionID(for: existingNode))
                return
            }

            let reusedFromReestablish: LumaCore.ProcessSession? =
                if case .reestablish(let session, _) = pickerContext { session } else { nil }

            let session = engine.prepareAttachSession(device: device, process: proc, reusing: reusedFromReestablish)
            engine.selectedSidebarItem = .session(session.id)

            _ = try? await engine.attach(device: device, process: proc, session: session)
        }
    }

    @ViewBuilder
    private var eventStreamBottomBar: some View {
        Group {
            if engine.projectUIState.isEventStreamCollapsed {
                VStack(spacing: 0) {
                    Divider()
                    CollapsedEventStreamBar(engine: engine)
                        .frame(height: Self.collapsedEventStreamHeight)
                }
            } else {
                VStack(spacing: 0) {
                    eventStreamResizeHandle
                    EventStreamView(
                        engine: engine,
                        selection: selection,
                        onCollapseRequested: {
                            engine.setEventStreamCollapsed(true)
                        }
                    )
                    .equatable()
                    .clipped()
                }
                .frame(height: currentEventStreamHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .background(eventStreamBackground)
    }

    private var eventStreamBackground: Color {
        #if canImport(AppKit)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }

    private var currentEventStreamHeight: CGFloat {
        let maxHeight = max(Self.minEventStreamHeight, Double(availableHeight - Self.minMainContentHeight))
        return CGFloat(min(max(engine.projectUIState.eventStreamBottomHeight, Self.minEventStreamHeight), maxHeight))
    }

    private var eventStreamResizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 11)
            .overlay { Divider() }
            .contentShape(Rectangle())
            .platformPointer(.rowResize)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? engine.projectUIState.eventStreamBottomHeight
                        dragStartHeight = start
                        let maxHeight = max(Self.minEventStreamHeight, Double(availableHeight - Self.minMainContentHeight))
                        let proposed = start - Double(value.translation.height)
                        engine.setEventStreamBottomHeight(min(max(proposed, Self.minEventStreamHeight), maxHeight))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
    }
}

private struct CollapsedEventStreamBar: View {
    let engine: Engine

    @State private var newEvents = 0
    @State private var baseline: Int

    init(engine: Engine) {
        self.engine = engine
        _baseline = State(initialValue: engine.eventLog.totalReceived)
    }

    var body: some View {
        HStack {
            Button {
                engine.setEventStreamCollapsed(false)
            } label: {
                if newEvents > 0 {
                    Label("Show Event Stream (\(newEvents) new)", systemImage: "chevron.up")
                } else {
                    Label("Show Event Stream", systemImage: "chevron.up")
                }
            }
            .buttonStyle(.borderless)
            .font(.footnote)
            .accessibilityIdentifier("eventStream.expand")

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(newEvents > 0 ? Color.accentColor.opacity(0.12) : Color.clear)
        .onChange(of: engine.eventLog.totalReceived) { _, newVersion in
            newEvents += max(0, newVersion - baseline)
            baseline = newVersion
        }
    }
}

struct ProjectToolbar: ToolbarContent {
    let engine: Engine
    let picker: TargetPicker
    @Binding var selection: SidebarItemID?
    @Binding var isShowingHostingBlockedAlert: Bool

    @State var showingAddInstrumentSheetForProcess: LumaCore.ProcessSession?
    @State private var showingCodeShareSheetForProcess: LumaCore.ProcessSession?
    @State private var pendingCodeShareAfterAddInstrumentDismiss: LumaCore.ProcessSession?
    @State private var isShowingPackageManager = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if engine.canHostNewSessions {
                    picker.context = .newSession
                } else {
                    isShowingHostingBlockedAlert = true
                }
            } label: {
                Label("New Session…", systemImage: "target")
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .accessibilityIdentifier("toolbar.newSession")

            let session = selectedProcessSession

            Button {
                showingAddInstrumentSheetForProcess = session
            } label: {
                Label("Add Instrument…", systemImage: "waveform.path.ecg")
            }
            .disabled(session == nil)
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .sheet(
                item: $showingAddInstrumentSheetForProcess,
                onDismiss: {
                    if let session = pendingCodeShareAfterAddInstrumentDismiss {
                        pendingCodeShareAfterAddInstrumentDismiss = nil
                        showingCodeShareSheetForProcess = session
                    }
                }
            ) { session in
                AddInstrumentSheet(
                    session: session,
                    engine: engine,
                    selection: $selection,
                    onInstrumentAdded: { instrument in
                        selection = .instrument(session.id, instrument.id)
                    },
                    onBrowseCodeShare: {
                        pendingCodeShareAfterAddInstrumentDismiss = session
                    }
                )
            }
            .sheet(item: $showingCodeShareSheetForProcess) { session in
                CodeShareBrowserView(
                    session: session,
                    engine: engine,
                    onInstrumentAdded: { instrument in
                        showingCodeShareSheetForProcess = nil
                        selection = .instrument(session.id, instrument.id)
                    }
                )
            }

            if let node = selectedProcessNode,
                let session = session,
                session.phase == .awaitingInitialResume
            {
                Button {
                    Task { @MainActor in
                        await engine.resumeSpawnedProcess(node: node)
                    }
                } label: {
                    Label("Resume Process", systemImage: "play.fill")
                }
                .help("Call resume(\(session.lastKnownPID)) on this device.")
                .keyboardShortcut("r", modifiers: [.command])
            }

            Button {
                isShowingPackageManager = true
            } label: {
                Label("Manage Packages…", systemImage: "shippingbox")
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .sheet(isPresented: $isShowingPackageManager) {
                VStack(alignment: .leading) {
                    Text("Add Package")
                        .font(.title2)
                        .bold()
                        .padding(.bottom, 8)

                    PackageSearchView(engine: engine, selection: $selection)
                }
                .padding()
            }

            GlobalActionQueueToolbarItem(engine: engine)

            Button {
                engine.toggleSidePanel(.virtualMachines)
            } label: {
                Label(
                    "Machines",
                    systemImage: engine.projectUIState.sidePanel == .virtualMachines
                        ? "desktopcomputer.and.arrow.down"
                        : "desktopcomputer"
                )
            }
            .help("Show or hide the virtual machines panel")

            Button {
                engine.toggleSidePanel(.collaboration)
            } label: {
                Label(
                    "Collaboration",
                    systemImage: engine.projectUIState.sidePanel == .collaboration
                        ? "person.2.wave.2.fill"
                        : "person.2.wave.2"
                )
            }
            .help("Show or hide the collaboration panel")
            .keyboardShortcut("c", modifiers: [.command, .option])
        }
    }

    var selectedProcessSession: LumaCore.ProcessSession? {
        guard let id = selection else { return nil }

        switch id {
        case .notebook, .pharo, .missions, .mission(_), .patterns, .pattern(_), .patternType(_, _), .package(_), .customInstrumentDef(_),
            .customInstrumentFile(_, _):
            return nil

        case .session(let sessionID),
            .repl(let sessionID),
            .files(let sessionID),
            .module(let sessionID, _),
            .thread(let sessionID, _),
            .instrument(let sessionID, _),
            .instrumentComponent(let sessionID, _, _),
            .insight(let sessionID, _),
            .itrace(let sessionID, _):
            return engine.session(id: sessionID)
        }
    }

    var selectedProcessNode: LumaCore.ProcessNode? {
        guard let id = selection else { return nil }

        switch id {
        case .notebook, .pharo, .missions, .mission(_), .patterns, .pattern(_), .patternType(_, _), .package(_), .customInstrumentDef(_),
            .customInstrumentFile(_, _):
            return nil
        case .session(let sessionID),
            .repl(let sessionID),
            .files(let sessionID),
            .module(let sessionID, _),
            .thread(let sessionID, _),
            .instrument(let sessionID, _),
            .instrumentComponent(let sessionID, _, _),
            .insight(let sessionID, _),
            .itrace(let sessionID, _):
            return engine.node(forSessionID: sessionID)
        }
    }
}

