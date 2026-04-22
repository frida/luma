#if canImport(UIKit)

import Frida
import LumaCore
import SwiftUI

struct PhoneSessionsListView: View {
    @ObservedObject var workspace: Workspace
    @Binding var path: [PhoneRoute]
    @Binding var activeDrawer: DrawerKind?
    let eventsIndicator: Bool
    let collabIndicator: Bool
    let documentActions: PhoneDocumentActions

    @State private var pendingKillSession: LumaCore.ProcessSession?
    @State private var pendingDeleteSession: LumaCore.ProcessSession?
    @State private var isShowingNotebook = false

    private var sessions: [LumaCore.ProcessSession] { workspace.engine.sessions }

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

            Spacer()

            Button {
                workspace.targetPickerContext = .newSession
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
            PhoneNotebookSheet(workspace: workspace)
        }
        .sheet(
                item: Binding(
                    get: { workspace.targetPickerContext },
                    set: { workspace.targetPickerContext = $0 }
                ),
                onDismiss: { workspace.targetPickerContext = nil }
            ) { ctx in
                TargetPickerView(
                    deviceManager: workspace.deviceManager,
                    reason: {
                        if case .reestablish(_, let reason) = ctx { return reason }
                        return nil
                    }(),
                    onSpawn: handleSpawn,
                    onAttach: handleAttach
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
                        PhoneSessionRow(session: session, workspace: workspace)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteSession = session
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        if workspace.engine.node(forSessionID: session.id) != nil {
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
                workspace.targetPickerContext = .newSession
            } label: {
                Label("New Session\u{2026}", systemImage: "target")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func handleSpawn(device: Device, config: SpawnConfig) {
        Task { @MainActor in
            let record = LumaCore.ProcessSession(
                kind: .spawn(config),
                deviceID: device.id,
                deviceName: device.name,
                processName: config.defaultDisplayName,
                lastKnownPID: 0
            )
            try? workspace.store.save(record)
            await workspace.engine.spawnAndAttach(device: device, session: record)
        }
    }

    private func handleAttach(device: Device, proc: ProcessDetails) {
        let ctx = workspace.targetPickerContext

        Task { @MainActor in
            if let existing = workspace.engine.processNodes.first(where: {
                $0.device.id == device.id && $0.process.pid == proc.pid
            }) {
                let existingID = workspace.engine.sessionID(for: existing)
                path.append(.session(existingID))
                return
            }

            let reused: LumaCore.ProcessSession? = {
                if case .reestablish(let s, _) = ctx { return s }
                return nil
            }()

            var record = reused ?? LumaCore.ProcessSession(
                kind: .attach,
                deviceID: device.id,
                deviceName: device.name,
                processName: proc.name,
                lastKnownPID: proc.pid
            )
            record.deviceID = device.id
            record.deviceName = device.name
            record.processName = proc.name
            record.lastKnownPID = proc.pid
            if record.iconPNGData == nil, let icon = proc.icons.last {
                record.iconPNGData = pngData(for: icon)
            }
            try? workspace.store.save(record)
            await workspace.engine.attach(device: device, process: proc, session: record)

            path.append(.session(record.id))
        }
    }

    private func reestablish(_ session: LumaCore.ProcessSession) {
        Task { @MainActor in
            let result = await workspace.engine.reestablishSession(id: session.id)
            if case .needsUserInput(let reason, let s) = result {
                workspace.targetPickerContext = .reestablish(session: s, reason: reason)
            }
        }
    }

    private func killProcess(_ session: LumaCore.ProcessSession) {
        guard let node = workspace.engine.node(forSessionID: session.id) else { return }
        Task { @MainActor in
            let pid = session.lastKnownPID
            do { try await node.device.kill(pid) } catch {
                workspace.engine.updateSession(id: session.id) { $0.lastError = error.localizedDescription }
            }
        }
    }

    private func detachSession(_ session: LumaCore.ProcessSession) {
        guard let node = workspace.engine.node(forSessionID: session.id) else { return }
        workspace.engine.removeNode(node)
    }

    private func deleteSession(_ session: LumaCore.ProcessSession) {
        if let node = workspace.engine.node(forSessionID: session.id) {
            workspace.engine.removeNode(node)
        }
        try? workspace.store.deleteSession(id: session.id)
    }
}

struct PhoneSessionRow: View {
    let session: LumaCore.ProcessSession
    @ObservedObject var workspace: Workspace

    private var node: LumaCore.ProcessNode? {
        workspace.engine.node(forSessionID: session.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(node?.process.name ?? session.processName)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(node?.device.name ?? session.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        if let node, let lastIcon = node.process.icons.last {
            lastIcon.swiftUIImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .cornerRadius(6)
        } else if let data = session.iconPNGData {
            Icon.png(data: Array(data)).swiftUIImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .cornerRadius(6)
        } else {
            SessionPlaceholderIcon(
                seed: "\(session.deviceID)/\(session.processName)",
                displayName: session.processName
            )
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if node == nil {
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
