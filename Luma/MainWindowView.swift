import Frida
import SwiftUI
import LumaCore

struct MainWindowView: View {
    private let projectURL: URL
    private let fileURL: URL?
    private let project: Binding<LumaProject>?

    @State private var engineResult: Result<Engine, any Swift.Error>
    @State private var picker = TargetPicker()
    @State private var collapsedEventBaselineVersion: Int = 0
    @State private var collapsedNewEvents: Int = 0
    @State private var isShowingHostingBlockedAlert = false

    init(projectURL: URL, fileURL: URL? = nil, project: Binding<LumaProject>? = nil) {
        self.projectURL = projectURL
        self.fileURL = fileURL
        self.project = project
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
                project: project,
                restorationPath: restorationPath,
                collapsedEventBaselineVersion: $collapsedEventBaselineVersion,
                collapsedNewEvents: $collapsedNewEvents,
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
    let project: Binding<LumaProject>?
    let restorationPath: String

    @Binding var collapsedEventBaselineVersion: Int
    @Binding var collapsedNewEvents: Int
    @Binding var isShowingHostingBlockedAlert: Bool

    var body: some View {
        CollapsibleVSplitView(
            isCollapsed: isEventStreamCollapsed,
            bottomHeight: eventStreamBottomHeight
        ) {
            mainContent
        } bottom: {
            eventStreamArea
        }
        .toolbarRole(.editor)
        .toolbar {
            ProjectToolbar(
                engine: engine,
                picker: picker,
                selection: selection,
                isShowingHostingBlockedAlert: $isShowingHostingBlockedAlert
            )
        }
        .alert(
            "Only lab owners can host sessions",
            isPresented: $isShowingHostingBlockedAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You're a member of this lab. Ask an owner to promote you before starting a session.")
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
        .environment(picker)
        .task {
            await EngineRegistry.shared.startIfNeeded(for: projectURL)
            engine.attachInstrumentUIs()
            #if os(macOS)
                engine.attachLocalNotifier()
            #endif
            if engine.collaboration.isCollaborative {
                engine.setCollaborationPanelVisible(true)
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
            guard
                let id = note.userInfo?["instanceID"] as? UUID,
                id == engine.store.instanceID
            else { return }
            project?.wrappedValue.revision &+= 1
        }
        .onChange(of: engine.eventLog.totalReceived) { _, newVersion in
            if engine.projectUIState.isEventStreamCollapsed {
                let delta = max(0, newVersion - collapsedEventBaselineVersion)
                collapsedNewEvents += delta
                collapsedEventBaselineVersion = newVersion
            } else {
                collapsedEventBaselineVersion = newVersion
                collapsedNewEvents = 0
            }
        }
        .onChange(of: engine.projectUIState.isEventStreamCollapsed) { _, isCollapsed in
            collapsedEventBaselineVersion = engine.eventLog.totalReceived
            if !isCollapsed {
                collapsedNewEvents = 0
            }
        }
    }

    private var isEventStreamCollapsed: Binding<Bool> {
        Binding(
            get: { engine.projectUIState.isEventStreamCollapsed },
            set: { engine.setEventStreamCollapsed($0) }
        )
    }

    private var eventStreamBottomHeight: Binding<Double> {
        Binding(
            get: { engine.projectUIState.eventStreamBottomHeight },
            set: { engine.setEventStreamBottomHeight($0) }
        )
    }

    private var selection: Binding<SidebarItemID?> {
        Binding(
            get: { engine.selectedSidebarItem },
            set: { engine.selectedSidebarItem = $0 }
        )
    }

    private var mainContent: some View {
        #if os(macOS)
            HSplitView {
                navigationAndDetail
                    .frame(minWidth: 560)

                if engine.projectUIState.isCollaborationPanelVisible {
                    CollaborationPanel(engine: engine)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 520)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        #else
            HStack(spacing: 0) {
                navigationAndDetail

                if engine.projectUIState.isCollaborationPanelVisible {
                    Divider()
                    CollaborationPanel(engine: engine)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 520)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        #endif
    }

    private var navigationAndDetail: some View {
        NavigationSplitView {
            SidebarView(
                engine: engine,
                selection: selection
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            DetailView(
                engine: engine,
                selection: selection
            )
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
    }

    private func targetPickerSheet(context: TargetPickerContext) -> some View {
        TargetPickerView(
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
            let sessionRecord = LumaCore.ProcessSession(
                kind: .spawn(config),
                deviceID: device.id,
                deviceName: device.name,
                processName: config.defaultDisplayName,
                lastKnownPID: 0
            )
            try? engine.store.save(sessionRecord)
            engine.selectedSidebarItem = .session(sessionRecord.id)

            _ = try? await engine.spawnAndAttach(
                device: device,
                session: sessionRecord
            )
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

            var sessionRecord: LumaCore.ProcessSession

            if let reused = reusedFromReestablish {
                sessionRecord = reused
            } else {
                sessionRecord = LumaCore.ProcessSession(
                    kind: .attach,
                    deviceID: device.id,
                    deviceName: device.name,
                    processName: proc.name,
                    lastKnownPID: proc.pid
                )
            }

            sessionRecord.deviceID = device.id
            sessionRecord.deviceName = device.name
            sessionRecord.processName = proc.name
            sessionRecord.lastKnownPID = proc.pid

            sessionRecord.adoptIcon(from: proc)

            try? engine.store.save(sessionRecord)
            engine.selectedSidebarItem = .session(sessionRecord.id)

            _ = try? await engine.attach(
                device: device,
                process: proc,
                session: sessionRecord
            )
        }
    }

    private var eventStreamArea: some View {
        ZStack(alignment: .bottomLeading) {
            EventStreamView(
                engine: engine,
                selection: selection,
                onCollapseRequested: {
                    engine.setEventStreamCollapsed(true)
                }
            )
            .opacity(engine.projectUIState.isEventStreamCollapsed ? 0 : 1)
            .clipped()

            collapsedEventStreamBar
                .opacity(engine.projectUIState.isEventStreamCollapsed ? 1 : 0)
        }
    }

    private var collapsedEventStreamBar: some View {
        HStack {
            Button {
                engine.setEventStreamCollapsed(false)
                collapsedNewEvents = 0
                collapsedEventBaselineVersion = engine.eventLog.totalReceived
            } label: {
                if collapsedNewEvents > 0 {
                    Label(
                        "Show Event Stream (\(collapsedNewEvents) new)",
                        systemImage: "chevron.up")
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
        .padding(.top, 4)
        .padding(.bottom, 11)
        .background(
            collapsedNewEvents > 0
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
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

            Button {
                engine.setCollaborationPanelVisible(!engine.projectUIState.isCollaborationPanelVisible)
            } label: {
                Label(
                    "Collaboration",
                    systemImage: engine.projectUIState.isCollaborationPanelVisible
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
        case .notebook, .missions, .mission(_), .package(_), .customInstrumentDef(_), .customInstrumentFile(_, _):
            return nil

        case .session(let sessionID),
            .repl(let sessionID),
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
        case .notebook, .missions, .mission(_), .package(_), .customInstrumentDef(_), .customInstrumentFile(_, _):
            return nil
        case .session(let sessionID),
            .repl(let sessionID),
            .instrument(let sessionID, _),
            .instrumentComponent(let sessionID, _, _),
            .insight(let sessionID, _),
            .itrace(let sessionID, _):
            return engine.node(forSessionID: sessionID)
        }
    }
}

#if os(macOS)
    import AppKit

    struct CollapsibleVSplitView<Top: View, Bottom: View>: NSViewRepresentable {
        @Binding var isCollapsed: Bool
        @Binding var bottomHeight: Double

        let top: Top
        let bottom: Bottom

        private static var collapsedHeight: CGFloat { 32 }
        private static var minBottomHeight: CGFloat { 120 }
        private static var minTopHeight: CGFloat { 160 }

        init(
            isCollapsed: Binding<Bool>,
            bottomHeight: Binding<Double>,
            @ViewBuilder top: () -> Top,
            @ViewBuilder bottom: () -> Bottom
        ) {
            self._isCollapsed = isCollapsed
            self._bottomHeight = bottomHeight
            self.top = top()
            self.bottom = bottom()
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(
                isCollapsed: _isCollapsed,
                bottomHeight: _bottomHeight
            )
        }

        func makeNSView(context: Context) -> NSSplitView {
            let split = NSSplitView()
            split.isVertical = false
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = false
            split.delegate = context.coordinator

            let topHost = NSHostingView(rootView: AnyView(top))
            topHost.translatesAutoresizingMaskIntoConstraints = true
            topHost.autoresizingMask = [.width, .height]
            topHost.setContentHuggingPriority(.defaultLow, for: .vertical)
            topHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

            let bottomHost = NSHostingView(rootView: AnyView(bottom))
            bottomHost.translatesAutoresizingMaskIntoConstraints = true
            bottomHost.autoresizingMask = [.width, .height]
            bottomHost.setContentHuggingPriority(.defaultLow, for: .vertical)
            bottomHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

            split.addArrangedSubview(topHost)
            split.addArrangedSubview(bottomHost)

            return split
        }

        func updateNSView(_ split: NSSplitView, context: Context) {
            guard split.subviews.count == 2 else { return }

            if let topHost = split.subviews[0] as? NSHostingView<AnyView> {
                topHost.rootView = AnyView(top)
            }
            if let bottomHost = split.subviews[1] as? NSHostingView<AnyView> {
                bottomHost.rootView = AnyView(bottom)
            }

            let totalHeight = split.bounds.height
            guard totalHeight > 0 else { return }

            let coordinator = context.coordinator

            let nowCollapsed = isCollapsed
            let previousCollapsed = coordinator.lastIsCollapsed
            let didToggle = (previousCollapsed != nowCollapsed)
            coordinator.lastIsCollapsed = nowCollapsed

            if didToggle {
                if previousCollapsed && !nowCollapsed {
                    let h = CGFloat(bottomHeight)
                    if h > 0 {
                        coordinator.lastBottomHeight = h
                    }
                }

                coordinator.didPerformInitialLayout = true

                coordinator.performProgrammaticLayout(
                    in: split,
                    totalHeight: totalHeight,
                    collapsedOverride: nowCollapsed
                )
            }
        }

        final class Coordinator: NSObject, NSSplitViewDelegate {
            @Binding var isCollapsed: Bool
            @Binding var bottomHeight: Double

            var lastIsCollapsed: Bool
            var lastBottomHeight: CGFloat

            var didPerformInitialLayout: Bool = false
            var isProgrammaticAdjustment: Bool = false

            init(
                isCollapsed: Binding<Bool>,
                bottomHeight: Binding<Double>
            ) {
                _isCollapsed = isCollapsed
                _bottomHeight = bottomHeight

                lastIsCollapsed = isCollapsed.wrappedValue
                lastBottomHeight = CGFloat(bottomHeight.wrappedValue)
            }

            private func syncOutStoredHeight() {
                let h = Double(lastBottomHeight)
                let previousBottomHeight = self.bottomHeight
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.bottomHeight == previousBottomHeight else {
                        return
                    }
                    self.bottomHeight = h
                }
            }

            func splitViewDidResizeSubviews(_ notification: Notification) {
                guard let split = notification.object as? NSSplitView else { return }
                guard split.subviews.count == 2 else { return }

                let totalHeight = split.bounds.height
                guard totalHeight > 0 else { return }

                if !didPerformInitialLayout {
                    performProgrammaticLayout(in: split, totalHeight: totalHeight)
                    didPerformInitialLayout = true
                    return
                }

                if !isCollapsed && !isProgrammaticAdjustment {
                    let newHeight = split.subviews[1].frame.height

                    guard newHeight > 0 else { return }

                    lastBottomHeight = newHeight
                    syncOutStoredHeight()
                }
            }

            func splitView(
                _ splitView: NSSplitView,
                constrainMinCoordinate proposedMinimumPosition: CGFloat,
                ofSubviewAt dividerIndex: Int
            ) -> CGFloat {
                let totalHeight = splitView.bounds.height

                if isProgrammaticAdjustment {
                    return proposedMinimumPosition
                }

                if isCollapsed {
                    return totalHeight - CollapsibleVSplitView.collapsedHeight
                }

                let minPos = CollapsibleVSplitView.minTopHeight
                let maxPos = totalHeight - CollapsibleVSplitView.minBottomHeight
                return max(minPos, min(proposedMinimumPosition, maxPos))
            }

            func splitView(
                _ splitView: NSSplitView,
                constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                ofSubviewAt dividerIndex: Int
            ) -> CGFloat {
                let totalHeight = splitView.bounds.height

                if isProgrammaticAdjustment {
                    return proposedMaximumPosition
                }

                if isCollapsed {
                    return totalHeight - CollapsibleVSplitView.collapsedHeight
                }

                let minPos = CollapsibleVSplitView.minTopHeight
                let maxPos = totalHeight - CollapsibleVSplitView.minBottomHeight
                return max(minPos, min(proposedMaximumPosition, maxPos))
            }

            func performProgrammaticLayout(
                in split: NSSplitView,
                totalHeight: CGFloat,
                collapsedOverride: Bool? = nil
            ) {
                let minBottomHeight = CollapsibleVSplitView.minBottomHeight
                let minTopHeight = CollapsibleVSplitView.minTopHeight
                let collapsedHeight = CollapsibleVSplitView.collapsedHeight

                let maxBottomHeight: CGFloat = max(minBottomHeight, totalHeight - minTopHeight)

                if lastBottomHeight <= 0 {
                    let source = CGFloat(bottomHeight)
                    if source > 0 {
                        lastBottomHeight = source
                    } else {
                        lastBottomHeight = min(
                            maxBottomHeight,
                            max(minBottomHeight, totalHeight * 0.25)
                        )
                    }
                }

                let clampedBottom = min(
                    maxBottomHeight,
                    max(minBottomHeight, lastBottomHeight)
                )

                let effectiveCollapsed = collapsedOverride ?? isCollapsed

                let targetBottomHeight = effectiveCollapsed ? collapsedHeight : clampedBottom

                let targetDividerPosition = totalHeight - targetBottomHeight
                let currentDividerPosition = split.subviews[0].frame.height

                guard abs(currentDividerPosition - targetDividerPosition) > 1.0 else { return }

                isProgrammaticAdjustment = true
                split.setPosition(targetDividerPosition, ofDividerAt: 0)
                isProgrammaticAdjustment = false
            }
        }
    }
#else

    struct CollapsibleVSplitView<Top: View, Bottom: View>: View {
        @Binding var isCollapsed: Bool
        let top: Top
        let bottom: Bottom

        init(
            isCollapsed: Binding<Bool>,
            bottomHeight: Binding<Double>,
            @ViewBuilder top: () -> Top,
            @ViewBuilder bottom: () -> Bottom
        ) {
            self._isCollapsed = isCollapsed
            self.top = top()
            self.bottom = bottom()
        }

        var body: some View {
            VStack(spacing: 0) {
                top
                Divider()
                if isCollapsed {
                    bottom.frame(height: 32)
                } else {
                    bottom.frame(minHeight: 120)
                }
            }
        }
    }
#endif
