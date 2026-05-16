#if canImport(UIKit)

import Frida
import LumaCore
import SwiftUI
import UIKit

struct PhoneMainView: View {
    private let projectURL: URL
    private let documentActions: PhoneDocumentActions

    @State private var engineResult: Result<Engine, any Swift.Error>
    @State private var picker = TargetPicker()

    init(projectURL: URL, documentActions: PhoneDocumentActions = .noop) {
        self.projectURL = projectURL
        self.documentActions = documentActions
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
            PhoneContentView(
                engine: engine,
                picker: picker,
                projectURL: projectURL,
                documentActions: documentActions
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
        }
    }
}

private struct PhoneContentView: View {
    let engine: Engine
    let picker: TargetPicker
    let projectURL: URL
    let documentActions: PhoneDocumentActions

    @State private var path: [PhoneRoute] = []
    @State private var activeDrawer: DrawerKind?
    @State private var eventsBaseline: Int = 0
    @State private var collabChatBaseline: Int = 0

    var body: some View {
        DrawerHost(
            active: $activeDrawer,
            engine: engine,
            onEventsOpened: { eventsBaseline = engine.eventLog.totalReceived },
            onCollabOpened: { collabChatBaseline = engine.collaboration.chatMessages.count }
        ) {
            NavigationStack(path: $path) {
                PhoneSessionsListView(
                    engine: engine,
                    path: $path,
                    activeDrawer: $activeDrawer,
                    eventsIndicator: eventsIndicator,
                    collabIndicator: collabIndicator,
                    documentActions: documentActions
                )
                .navigationDestination(for: PhoneRoute.self) { route in
                    switch route {
                    case .session(let id):
                        PhoneSessionView(
                            sessionID: id,
                            engine: engine,
                            path: $path,
                            activeDrawer: $activeDrawer,
                            eventsIndicator: eventsIndicator,
                            collabIndicator: collabIndicator
                        )

                    case .instrument(let sessionID, let instrumentID):
                        if engine.instrumentsBySession[sessionID]?
                            .contains(where: { $0.id == instrumentID }) == true
                        {
                            SessionContent(sessionID: sessionID, engine: engine) {
                                InstrumentDetailView(
                                    instanceID: instrumentID,
                                    sessionID: sessionID,
                                    engine: engine,
                                    selection: $path.asSidebarSelection()
                                )
                            }
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { drawerTriggers }
                        }

                    case .insight(let sessionID, let insightID):
                        if let session = engine.sessions.first(where: { $0.id == sessionID }),
                           let insight = engine.insightsBySession[sessionID]?
                               .first(where: { $0.id == insightID })
                        {
                            SessionContent(sessionID: sessionID, engine: engine) {
                                AddressInsightDetailView(
                                    session: session,
                                    insight: insight,
                                    engine: engine,
                                    selection: $path.asSidebarSelection()
                                )
                            }
                            .navigationTitle(insight.title)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { drawerTriggers }
                        }

                    case .trace(let sessionID, let traceID):
                        if let session = engine.sessions.first(where: { $0.id == sessionID }),
                           let trace = engine.tracesBySession[sessionID]?
                               .first(where: { $0.id == traceID })
                        {
                            SessionContent(sessionID: sessionID, engine: engine) {
                                ITraceDetailView(
                                    trace: trace,
                                    session: session,
                                    engine: engine,
                                    selection: $path.asSidebarSelection()
                                )
                            }
                            .navigationTitle(trace.displayName)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { drawerTriggers }
                        }
                    }
                }
            }
        }
        .environment(picker)
        .task {
            await EngineRegistry.shared.startIfNeeded(for: projectURL)
            engine.attachInstrumentUIs()
            if engine.collaboration.isCollaborative {
                engine.setCollaborationPanelVisible(true)
            }
            eventsBaseline = engine.eventLog.totalReceived
            collabChatBaseline = engine.collaboration.chatMessages.count
        }
        .onAppear {
            LumaAppState.shared.lastDocumentPath = projectURL.path
        }
        .onDisappear {
            let url = projectURL
            Task { @MainActor in
                await EngineRegistry.shared.release(workingProjectURL: url)
            }
        }
        .onOpenURL { url in
            LumaAppDelegate.handle(url: url)
        }
    }

    @ToolbarContentBuilder
    private var drawerTriggers: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            DrawerTriggerButton(
                kind: .events,
                active: $activeDrawer,
                indicator: eventsIndicator
            )
            DrawerTriggerButton(
                kind: .collab,
                active: $activeDrawer,
                indicator: collabIndicator
            )
        }
    }

    private var eventsIndicator: Bool {
        engine.eventLog.totalReceived > eventsBaseline && activeDrawer != .events
    }

    private var collabIndicator: Bool {
        engine.collaboration.chatMessages.count > collabChatBaseline && activeDrawer != .collab
    }
}

enum PhoneRoute: Hashable {
    case session(UUID)
    case instrument(UUID, UUID)
    case insight(UUID, UUID)
    case trace(UUID, UUID)
}

extension Binding where Value == [PhoneRoute] {
    func asSidebarSelection() -> Binding<SidebarItemID?> {
        Binding<SidebarItemID?>(
            get: { nil },
            set: { newValue in
                guard let newValue else { return }
                switch newValue {
                case .insight(let sid, let iid):
                    self.wrappedValue.append(.insight(sid, iid))
                case .instrument(let sid, let iid),
                     .instrumentComponent(let sid, let iid, _):
                    self.wrappedValue.append(.instrument(sid, iid))
                case .itrace(let sid, let tid):
                    self.wrappedValue.append(.trace(sid, tid))
                case .session, .repl, .notebook, .missions, .mission, .package, .customInstrumentDef, .customInstrumentFile:
                    break
                }
            }
        )
    }
}

enum DrawerKind: Hashable {
    case events
    case collab
}

private struct DrawerHost<Content: View>: View {
    @Binding var active: DrawerKind?
    let engine: Engine
    let onEventsOpened: () -> Void
    let onCollabOpened: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var expanded = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let defaultWidth = min(width * 0.85, width - 40)
            let drawerWidth = expanded ? width : defaultWidth

            ZStack(alignment: .trailing) {
                content()

                if active != nil {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { close() }
                }

                if let kind = active {
                    drawerBody(for: kind)
                        .frame(width: drawerWidth)
                        .frame(maxHeight: .infinity)
                        .background(Color.platformWindowBackground)
                        .shadow(color: .black.opacity(0.3), radius: 12, x: -4, y: 0)
                        .offset(x: dragOffset)
                        .transition(.move(edge: .trailing))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    dragOffset = max(0, value.translation.width)
                                }
                                .onEnded { value in
                                    if value.translation.width > drawerWidth * 0.3 {
                                        close()
                                    } else {
                                        withAnimation(.spring(response: 0.25)) {
                                            dragOffset = 0
                                        }
                                    }
                                }
                        )
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: active)
            .onChange(of: active) { oldValue, newValue in
                switch oldValue {
                case .events:
                    onEventsOpened()
                case .collab:
                    onCollabOpened()
                case nil:
                    break
                }
                switch newValue {
                case .events:
                    onEventsOpened()
                case .collab:
                    onCollabOpened()
                case nil:
                    expanded = false
                    dragOffset = 0
                }
            }
        }
    }

    @ViewBuilder
    private func drawerBody(for kind: DrawerKind) -> some View {
        VStack(spacing: 0) {
            DrawerHeader(
                title: kind.title,
                expanded: $expanded,
                onClose: close
            )
            Divider()

            switch kind {
            case .events:
                EventStreamView(
                    engine: engine,
                    selection: .constant(nil),
                    onCollapseRequested: close
                )

            case .collab:
                CollaborationPanel(engine: engine)
            }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            active = nil
            dragOffset = 0
            expanded = false
        }
    }
}

private struct DrawerHeader: View {
    let title: String
    @Binding var expanded: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .font(.body)

            Text(title)
                .font(.headline)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .font(.body)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private extension DrawerKind {
    var title: String {
        switch self {
        case .events: return "Events"
        case .collab: return "Collaboration"
        }
    }
}

struct DrawerTriggerButton: View {
    let kind: DrawerKind
    @Binding var active: DrawerKind?
    let indicator: Bool

    var body: some View {
        Button {
            if active == kind {
                active = nil
            } else {
                active = kind
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: kind.icon)
                    .symbolVariant(active == kind ? .fill : .none)
                if indicator {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 3, y: -2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3), value: indicator)
    }
}

private extension DrawerKind {
    var icon: String {
        switch self {
        case .events: return "waveform"
        case .collab: return "person.2.wave.2"
        }
    }
}

#endif
