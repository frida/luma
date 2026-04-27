import Frida
import SwiftUI
import UniformTypeIdentifiers
import LumaCore

struct MainWindowView: View {
    @State private var uiState = ProjectUIStateValue()
    @StateObject private var workspace: Workspace

    private let dbURL: URL
    private let fileURL: URL?
    private let project: Binding<LumaProject>?

    init(dbURL: URL, fileURL: URL? = nil, project: Binding<LumaProject>? = nil) {
        self.dbURL = dbURL
        self.fileURL = fileURL
        self.project = project
        let store = try! ProjectStore(path: dbURL.path)
        self._workspace = StateObject(
            wrappedValue: Workspace(store: store, gitHubAuth: sharedGitHubAuth())
        )
    }

    private var restorationPath: String {
        (fileURL ?? dbURL).path
    }

    @State private var collapsedEventBaselineVersion: Int = 0
    @State private var collapsedNewEvents: Int = 0

    var body: some View {
        CollapsibleVSplitView(
            isCollapsed: $uiState.isEventStreamCollapsed,
            bottomHeight: $uiState.eventStreamBottomHeight
        ) {
            mainContent
        } bottom: {
            eventStreamArea
        }
        .toolbarRole(.editor)
        .toolbar {
            WorkspaceToolbar(
                workspace: workspace,
                selection: $uiState.selectedItemID
            )
        }
        .frame(
            minWidth: 800,
            idealWidth: 1100,
            maxWidth: .infinity,
            minHeight: 600,
            idealHeight: 680,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task {
            await workspace.configurePersistence()
            if uiState.selectedItemID == nil, !workspace.engine.notebookEntries.isEmpty {
                uiState.selectedItemID = .notebook
            }
        }
        .onChange(of: restorationPath, initial: true) { _, newPath in
            LumaAppState.shared.lastDocumentPath = newPath
        }
        .onDisappear {
            Task { @MainActor in
                await workspace.engine.collaboration.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProjectStore.didCommitNotification)) { note in
            guard
                let id = note.userInfo?["instanceID"] as? UUID,
                id == workspace.store.instanceID
            else { return }
            project?.wrappedValue.revision &+= 1
        }
        .onChange(of: workspace.engine.eventLog.totalReceived) { _, newVersion in
            if uiState.isEventStreamCollapsed {
                let delta = max(0, newVersion - collapsedEventBaselineVersion)
                collapsedNewEvents += delta
                collapsedEventBaselineVersion = newVersion
            } else {
                collapsedEventBaselineVersion = newVersion
                collapsedNewEvents = 0
            }
        }
        .onChange(of: uiState.isEventStreamCollapsed) { _, isCollapsed in
            collapsedEventBaselineVersion = workspace.engine.eventLog.totalReceived
            if !isCollapsed {
                collapsedNewEvents = 0
            }
        }
    }

    private var mainContent: some View {
        #if os(macOS)
            HSplitView {
                navigationAndDetail
                    .frame(minWidth: 560)

                if workspace.isCollaborationPanelVisible {
                    CollaborationPanel(workspace: workspace)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 520)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        #else
            HStack(spacing: 0) {
                navigationAndDetail

                if workspace.isCollaborationPanelVisible {
                    Divider()
                    CollaborationPanel(workspace: workspace)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 520)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        #endif
    }

    private var navigationAndDetail: some View {
        NavigationSplitView {
            SidebarView(
                workspace: workspace,
                selection: $uiState.selectedItemID
            )
            .navigationSplitViewColumnWidth(ideal: 180)
        } detail: {
            DetailView(
                workspace: workspace,
                selection: $uiState.selectedItemID
            )
        }
        .sheet(
            item: Binding(
                get: { workspace.targetPickerContext },
                set: { newValue in
                    Task { @MainActor in
                        workspace.targetPickerContext = newValue
                    }
                }
            ),
            onDismiss: {
                workspace.targetPickerContext = nil
            },
            content: { context in
                targetPickerSheet(context: context)
            }
        )
    }

    private func targetPickerSheet(context: TargetPickerContext) -> some View {
        TargetPickerView(
            deviceManager: workspace.deviceManager,
            reason: {
                if case .reestablish(_, let reason) = context {
                    reason
                } else {
                    nil
                }
            }(),
            onSpawn: handleSpawn(device:config:),
            onAttach: handleAttach(device:proc:)
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
            try? workspace.store.save(sessionRecord)

            await workspace.engine.spawnAndAttach(
                device: device,
                session: sessionRecord
            )
        }
    }

    private func handleAttach(device: Device, proc: ProcessDetails) {
        let targetPickerContext = workspace.targetPickerContext

        Task { @MainActor in
            if let existingNode = workspace.engine.processNodes.first(where: {
                $0.device.id == device.id && $0.process.pid == proc.pid
            }) {
                uiState.selectedItemID = .repl(workspace.engine.sessionID(for: existingNode))
                return
            }

            let reusedFromReestablish: LumaCore.ProcessSession? =
                if case .reestablish(let session, _) = targetPickerContext { session } else { nil }

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

            if sessionRecord.iconPNGData == nil,
                let icon = proc.icons.last
            {
                sessionRecord.iconPNGData = pngData(for: icon)
            }

            try? workspace.store.save(sessionRecord)

            await workspace.engine.attach(
                device: device,
                process: proc,
                session: sessionRecord
            )

            uiState.selectedItemID = .repl(sessionRecord.id)
        }
    }

    private var eventStreamArea: some View {
        ZStack(alignment: .bottomLeading) {
            EventStreamView(
                workspace: workspace,
                selection: $uiState.selectedItemID,
                onCollapseRequested: {
                    uiState.isEventStreamCollapsed = true
                }
            )
            .opacity(uiState.isEventStreamCollapsed ? 0 : 1)
            .clipped()

            collapsedEventStreamBar
                .opacity(uiState.isEventStreamCollapsed ? 1 : 0)
        }
    }

    private var collapsedEventStreamBar: some View {
        HStack {
            Button {
                uiState.isEventStreamCollapsed = false
                collapsedNewEvents = 0
                collapsedEventBaselineVersion = workspace.engine.eventLog.totalReceived
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

struct WorkspaceToolbar: ToolbarContent {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State var showingAddInstrumentSheetForProcess: LumaCore.ProcessSession?
    @State private var showingCodeShareSheetForProcess: LumaCore.ProcessSession?
    @State private var pendingCodeShareAfterAddInstrumentDismiss: LumaCore.ProcessSession?
    @State private var isShowingPackageManager = false

    var selectedProcessSession: LumaCore.ProcessSession? {
        guard let id = selection else { return nil }

        switch id {
        case .notebook, .package(_):
            return nil

        case .repl(let sessionID),
            .instrument(let sessionID, _),
            .instrumentComponent(let sessionID, _, _, _),
            .insight(let sessionID, _),
            .itraceCapture(let sessionID, _):
            return workspace.engine.session(id: sessionID)
        }
    }

    var selectedProcessNode: LumaCore.ProcessNode? {
        guard let id = selection else { return nil }

        switch id {
        case .notebook, .package(_):
            return nil
        case .repl(let sessionID),
            .instrument(let sessionID, _),
            .instrumentComponent(let sessionID, _, _, _),
            .insight(let sessionID, _),
            .itraceCapture(let sessionID, _):
            return workspace.engine.node(forSessionID: sessionID)
        }
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.targetPickerContext = .newSession
            } label: {
                Label("New Session…", systemImage: "target")
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

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
                    workspace: workspace,
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
                    workspace: workspace,
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
                        await workspace.engine.resumeSpawnedProcess(node: node)
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

                    PackageSearchView(workspace: workspace, selection: $selection)
                }
                .padding()
            }

            Button {
                workspace.isCollaborationPanelVisible.toggle()
            } label: {
                Label(
                    "Collaboration",
                    systemImage: workspace.isCollaborationPanelVisible
                        ? "person.2.wave.2.fill"
                        : "person.2.wave.2"
                )
            }
            .help("Show or hide the collaboration panel")
            .keyboardShortcut("c", modifiers: [.command, .option])
        }
    }
}

private struct ProjectUIStateValue: Equatable {
    var selectedItemID: SidebarItemID?
    var isEventStreamCollapsed: Bool
    var eventStreamBottomHeight: Double

    init(
        selectedItemID: SidebarItemID? = nil,
        isEventStreamCollapsed: Bool = true,
        eventStreamBottomHeight: Double = 0
    ) {
        self.selectedItemID = selectedItemID
        self.isEventStreamCollapsed = isEventStreamCollapsed
        self.eventStreamBottomHeight = eventStreamBottomHeight
    }
}

func pngData(for icon: Icon) -> Data? {
    switch icon {
    case .png(let bytes):
        return Data(bytes)

    case .rgba:
        let image = icon.cgImage  // from Icon+CGImage
        let data = NSMutableData()

        guard
            let dest = CGImageDestinationCreateWithData(
                data as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }

        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
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
