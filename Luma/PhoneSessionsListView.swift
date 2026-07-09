#if canImport(UIKit)

import Frida
import LumaCore
import SwiftUI

struct PhoneSessionsListView: View {
    let engine: Engine
    @Binding var path: [PhoneRoute]
    @Binding var activeDrawer: DrawerKind?
    let eventsIndicator: Bool
    let collabIndicator: Bool
    let documentActions: PhoneDocumentActions

    @Environment(TargetPicker.self) private var picker

    @State private var pendingKillSession: LumaCore.ProcessSession?
    @State private var pendingDeleteSession: LumaCore.ProcessSession?
    @State private var isShowingNotebook = false
    @State private var isShowingMissions = false
    @State private var isShowingCustomInstruments = false
    @State private var isShowingHostingBlockedAlert = false

    private var sessions: [LumaCore.ProcessSession] { engine.sessions }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Section(documentActions.currentDisplayName) {
                    Button {
                        documentActions.saveAs()
                    } label: {
                        Label("Save a Copy\u{2026}", systemImage: "square.and.arrow.up")
                    }
                }
                Section {
                    Button {
                        documentActions.new()
                    } label: {
                        Label("New Document", systemImage: "doc.badge.plus")
                    }
                    Button {
                        documentActions.open()
                    } label: {
                        Label("Open Document\u{2026}", systemImage: "folder")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Menu")

            Button {
                isShowingNotebook = true
            } label: {
                Image(systemName: "book.pages")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Notebook")

            Button {
                isShowingMissions = true
            } label: {
                Image(systemName: "scope")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Missions")

            Button {
                isShowingCustomInstruments = true
            } label: {
                Image(systemName: "hammer")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Custom Instruments")

            Spacer()

            Button {
                requestNewSession()
            } label: {
                Image(systemName: "plus")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("New Session")

            DrawerTriggerButton(
                kind: .events,
                active: $activeDrawer,
                indicator: eventsIndicator
            )
            .font(.title3)
            .frame(width: 36, height: 36)

            DrawerTriggerButton(
                kind: .collab,
                active: $activeDrawer,
                indicator: collabIndicator
            )
            .font(.title3)
            .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingNotebook) {
            PhoneNotebookSheet(engine: engine)
        }
        .sheet(isPresented: $isShowingMissions) {
            PhoneMissionsSheet(engine: engine)
        }
        .sheet(isPresented: $isShowingCustomInstruments) {
            PhoneCustomInstrumentsSheet(engine: engine)
        }
        .sheet(
                item: Binding(
                    get: { picker.context },
                    set: { picker.context = $0 }
                ),
                onDismiss: { picker.context = nil }
            ) { ctx in
                TargetPickerView(
                    deviceManager: engine.deviceManager,
                    reason: {
                        if case .reestablish(_, let reason) = ctx { return reason }
                        return nil
                    }(),
                    onSpawn: handleSpawn,
                    onAttach: handleAttach,
                    onArm: handleArm
                )
            }
            .confirmationDialog(
                "Kill Process?",
                isPresented: Binding(
                    get: { pendingKillSession != nil },
                    set: { if !$0 { pendingKillSession = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingKillSession
            ) { session in
                Button("Kill Process", role: .destructive) { killProcess(session) }
                Button("Cancel", role: .cancel) {}
            } message: { session in
                Text("This will force-terminate \"\(session.processName)\".")
            }
            .confirmationDialog(
                "Delete Session?",
                isPresented: Binding(
                    get: { pendingDeleteSession != nil },
                    set: { if !$0 { pendingDeleteSession = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteSession
            ) { session in
                Button("Delete Session", role: .destructive) { deleteSession(session) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This will remove the session and its history.")
            }
            .alert(
                "Only lab owners can host sessions",
                isPresented: $isShowingHostingBlockedAlert
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You're a member of this lab. Ask an owner to promote you before starting a session.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if sessions.isEmpty {
            emptyState
        } else {
            List {
                ForEach(sessions) { session in
                    Button {
                        path.append(.session(session.id))
                    } label: {
                        PhoneSessionRow(session: session, engine: engine)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteSession = session
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        if engine.node(forSessionID: session.id) != nil {
                            Button {
                                detachSession(session)
                            } label: {
                                Label("Detach", systemImage: "bolt.slash")
                            }
                            .tint(.orange)

                            Button {
                                pendingKillSession = session
                            } label: {
                                Label("Kill", systemImage: "xmark.circle")
                            }
                            .tint(.red)
                        } else {
                            Button {
                                reestablish(session)
                            } label: {
                                Label("Reestablish", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        Group {
            if engine.collaboration.status == .connecting {
                joiningLabState
            } else {
                noSessionsState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var joiningLabState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Joining lab\u{2026}")
                .font(.headline)
            Text("Syncing this project's shared state.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var noSessionsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "target")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.headline)
            Text("Attach to a running process or spawn a new one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                requestNewSession()
            } label: {
                Label("New Session\u{2026}", systemImage: "target")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
    }

    private func handleSpawn(device: Device, config: SpawnConfig) {
        Task { @MainActor in
            let session = engine.prepareSpawnSession(device: device, config: config)
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
            path.append(.session(session.id))
        }
    }

    private func handleAttach(device: Device, proc: ProcessDetails) {
        let ctx = picker.context

        Task { @MainActor in
            if let existing = engine.processNodes.first(where: {
                $0.deviceID == device.id && $0.pid == proc.pid
            }) {
                let existingID = engine.sessionID(for: existing)
                path.append(.session(existingID))
                return
            }

            let reused: LumaCore.ProcessSession? = {
                if case .reestablish(let s, _) = ctx { return s }
                return nil
            }()

            let session = engine.prepareAttachSession(device: device, process: proc, reusing: reused)
            _ = try? await engine.attach(device: device, process: proc, session: session)

            path.append(.session(session.id))
        }
    }

    private func reestablish(_ session: LumaCore.ProcessSession) {
        let ownsHost = session.host.map { $0.id == engine.collaboration.localUser?.id } ?? true
        Task { @MainActor in
            let result: Engine.ReestablishResult
            if ownsHost {
                result = await engine.reestablishSession(id: session.id)
            } else {
                result = await engine.reHost(sessionID: session.id)
            }
            if case .needsUserInput(let reason, let s) = result {
                picker.context = .reestablish(session: s, reason: reason)
            }
        }
    }

    private func requestNewSession() {
        if engine.canHostNewSessions {
            picker.context = .newSession
        } else {
            isShowingHostingBlockedAlert = true
        }
    }

    private func killProcess(_ session: LumaCore.ProcessSession) {
        guard let node = engine.node(forSessionID: session.id) else { return }
        Task { @MainActor in
            do { try await node.kill() } catch {
                engine.updateSession(id: session.id) { $0.lastError = error.localizedDescription }
            }
        }
    }

    private func detachSession(_ session: LumaCore.ProcessSession) {
        guard let node = engine.node(forSessionID: session.id) else { return }
        engine.removeNode(node)
    }

    private func deleteSession(_ session: LumaCore.ProcessSession) {
        if let node = engine.node(forSessionID: session.id) {
            engine.removeNode(node)
        }
        try? engine.store.deleteSession(id: session.id)
    }
}

struct PhoneSessionRow: View {
    let session: LumaCore.ProcessSession
    let engine: Engine

    private var node: LumaCore.ProcessNode? {
        engine.node(forSessionID: session.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(node?.processName ?? session.processName)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(node?.deviceName ?? session.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            hostBadge
            statusBadge
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var hostBadge: some View {
        if let host = session.host,
           !engine.isHostingNode(session.id),
           host.id != engine.collaboration.localUser?.id
        {
            UserAvatarView(user: host, size: 18)
                .help("Hosted by @\(host.id) on \(session.deviceName)")
        }
    }

    private var isHostedRemotelyLive: Bool {
        engine.isHostedRemotelyLive(session.id)
    }

    @ViewBuilder
    private var icon: some View {
        if let data = session.iconPNGData {
            Icon.png(data: Array(data)).swiftUIImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .cornerRadius(6)
        } else {
            IconPlaceholderView(
                seed: "\(session.deviceID)/\(session.processName)",
                displayName: session.processName
            )
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isHostedRemotelyLive {
            EmptyView()
        } else if node == nil {
            Image(systemName: "bolt.slash")
                .foregroundStyle(.orange)
                .help("Detached")
        } else if session.phase == .awaitingInitialResume {
            Image(systemName: "pause.circle")
                .foregroundStyle(.blue)
                .help("Awaiting Resume")
        } else {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .help("Attached")
        }
    }
}

#endif
