#if canImport(UIKit)

import Frida
import LumaCore
import SwiftUI
import UIKit

struct PhoneMainView: View {
    @StateObject private var workspace: Workspace

    @State private var path: [PhoneRoute] = []

    @State private var activeDrawer: DrawerKind?

    @State private var eventsBaseline: Int = 0
    @State private var collabChatBaseline: Int = 0

    private let dbURL: URL
    private let documentActions: PhoneDocumentActions

    init(dbURL: URL, documentActions: PhoneDocumentActions = .noop) {
        self.dbURL = dbURL
        self.documentActions = documentActions
        let store = try! ProjectStore(path: dbURL.path)
        self._workspace = StateObject(
            wrappedValue: Workspace(store: store, gitHubAuth: sharedGitHubAuth())
        )
    }

    var body: some View {
        DrawerHost(
            active: $activeDrawer,
            workspace: workspace,
            onEventsOpened: { eventsBaseline = workspace.engine.eventLog.totalReceived },
            onCollabOpened: { collabChatBaseline = workspace.engine.collaboration.chatMessages.count }
        ) {
            NavigationStack(path: $path) {
                PhoneSessionsListView(
                    workspace: workspace,
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
                            workspace: workspace,
                            path: $path,
                            activeDrawer: $activeDrawer,
                            eventsIndicator: eventsIndicator,
                            collabIndicator: collabIndicator
                        )

                    case .instrument(let sessionID, let instrumentID):
                        if let instance = workspace.engine.instrumentsBySession[sessionID]?
                            .first(where: { $0.id == instrumentID })
                        {
                            SessionContent(sessionID: sessionID, workspace: workspace) {
                                InstrumentDetailView(
                                    instance: instance,
                                    workspace: workspace,
                                    selection: $path.asSidebarSelection()
                                )
                            }
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { drawerTriggers }
                        }

                    case .insight(let sessionID, let insightID):
                        if let session = workspace.engine.sessions.first(where: { $0.id == sessionID }),
                           let insight = workspace.engine.insightsBySession[sessionID]?
                               .first(where: { $0.id == insightID })
                        {
                            SessionContent(sessionID: sessionID, workspace: workspace) {
                                AddressInsightDetailView(
                                    session: session,
                                    insight: insight,
                                    workspace: workspace,
                                    selection: $path.asSidebarSelection()
                                )
                            }
                            .navigationTitle(insight.title)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { drawerTriggers }
                        }

                    case .capture(let sessionID, let captureID):
                        if let session = workspace.engine.sessions.first(where: { $0.id == sessionID }),
                           let capture = workspace.engine.capturesBySession[sessionID]?
                               .first(where: { $0.id == captureID })
                        {
                            SessionContent(sessionID: sessionID, workspace: workspace) {
                                ITraceDetailView(
                                    capture: capture,
                                    session: session,
                                    workspace: workspace,
                                    selection: $path.asSidebarSelection()
                                )
                            }
                            .navigationTitle(capture.displayName)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { drawerTriggers }
                        }
                    }
                }
            }
        }
        .task {
            await workspace.configurePersistence()
            eventsBaseline = workspace.engine.eventLog.totalReceived
            collabChatBaseline = workspace.engine.collaboration.chatMessages.count
        }
        .onAppear {
            LumaAppState.shared.lastDocumentPath = dbURL.path
        }
        .onDisappear {
            Task { @MainActor in
                await workspace.engine.collaboration.stop()
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
        workspace.engine.eventLog.totalReceived > eventsBaseline && activeDrawer != .events
    }

    private var collabIndicator: Bool {
        workspace.engine.collaboration.chatMessages.count > collabChatBaseline && activeDrawer != .collab
    }
}

enum PhoneRoute: Hashable {
    case session(UUID)
    case instrument(UUID, UUID)
    case insight(UUID, UUID)
    case capture(UUID, UUID)
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
                     .instrumentComponent(let sid, let iid, _, _):
                    self.wrappedValue.append(.instrument(sid, iid))
                case .itraceCapture(let sid, let cid):
                    self.wrappedValue.append(.capture(sid, cid))
                case .repl, .notebook, .package:
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
    @ObservedObject var workspace: Workspace
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
                        .ignoresSafeArea(edges: .bottom)
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
                    workspace: workspace,
                    selection: .constant(nil),
                    onCollapseRequested: close
                )

            case .collab:
                CollaborationPanel(workspace: workspace)
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
