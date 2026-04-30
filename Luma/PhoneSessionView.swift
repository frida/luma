#if canImport(UIKit)

import Frida
import LumaCore
import SwiftUI

struct PhoneSessionView: View {
    let sessionID: UUID
    @ObservedObject var workspace: Workspace
    @Binding var path: [PhoneRoute]
    @Binding var activeDrawer: DrawerKind?
    let eventsIndicator: Bool
    let collabIndicator: Bool

    @State private var segment: Segment = .repl
    @State private var isShowingAddInstrument = false
    @State private var isShowingSwitcher = false
    @State private var isShowingNotebook = false
    @State private var isShowingCodeShare = false
    @State private var pendingCodeShareAfterAddInstrumentDismiss = false
    @State private var pendingKill = false
    @State private var pendingDelete = false
    @State private var isShowingHostingBlockedAlert = false

    enum Segment: String, CaseIterable, Identifiable {
        case repl = "REPL"
        case instruments = "Instruments"
        case insights = "Insights"
        case captures = "Captures"

        var id: Self { self }

        var icon: String {
            switch self {
            case .repl: return "terminal"
            case .instruments: return "waveform.path.ecg"
            case .insights: return "doc.text.magnifyingglass"
            case .captures: return "waveform.path"
            }
        }
    }

    private var session: LumaCore.ProcessSession? {
        workspace.engine.sessions.first { $0.id == sessionID }
    }

    private var node: LumaCore.ProcessNode? {
        workspace.engine.node(forSessionID: sessionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("Segment", selection: $segment) {
                ForEach(Segment.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if let session, session.phase == .awaitingInitialResume, let node {
                resumeBanner(session: session, node: node)
            }

            SessionContent(sessionID: sessionID, workspace: workspace) {
                segmentBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingNotebook) {
            PhoneNotebookSheet(workspace: workspace)
        }
        .sheet(
            isPresented: $isShowingAddInstrument,
            onDismiss: {
                if pendingCodeShareAfterAddInstrumentDismiss {
                    pendingCodeShareAfterAddInstrumentDismiss = false
                    isShowingCodeShare = true
                }
            }
        ) {
            if let session {
                AddInstrumentSheet(
                    session: session,
                    workspace: workspace,
                    selection: .constant(nil),
                    onInstrumentAdded: { _ in
                        isShowingAddInstrument = false
                    },
                    onBrowseCodeShare: {
                        pendingCodeShareAfterAddInstrumentDismiss = true
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingCodeShare) {
            if let session {
                NavigationStack {
                    CodeShareBrowserView(
                        session: session,
                        workspace: workspace,
                        onInstrumentAdded: { _ in
                            isShowingCodeShare = false
                        }
                    )
                }
            }
        }
        .confirmationDialog(
            "Kill Process?",
            isPresented: $pendingKill,
            titleVisibility: .visible
        ) {
            Button("Kill Process", role: .destructive) { killProcess() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let session {
                Text("This will force-terminate \"\(session.processName)\".")
            }
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) { deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
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

    @Environment(\.dismiss) private var dismiss

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Back")

            Button {
                isShowingSwitcher = true
            } label: {
                HStack(spacing: 4) {
                    Text(session?.processName ?? "Session")
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingSwitcher, arrowEdge: .top) {
                PhoneSessionSwitcher(
                    workspace: workspace,
                    current: sessionID,
                    onPick: { id in
                        isShowingSwitcher = false
                        if id != sessionID {
                            path.removeLast()
                            path.append(.session(id))
                        }
                    },
                    onNew: {
                        isShowingSwitcher = false
                        if workspace.engine.canHostNewSessions {
                            workspace.targetPickerContext = .newSession
                        } else {
                            isShowingHostingBlockedAlert = true
                        }
                    }
                )
                .presentationCompactAdaptation(.popover)
            }

            Button {
                isShowingNotebook = true
            } label: {
                Image(systemName: "book.pages")
                    .font(.body)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Notebook")

            Spacer()

            DrawerTriggerButton(
                kind: .events,
                active: $activeDrawer,
                indicator: eventsIndicator
            )
            .font(.body)
            .frame(width: 36, height: 36)

            DrawerTriggerButton(
                kind: .collab,
                active: $activeDrawer,
                indicator: collabIndicator
            )
            .font(.body)
            .frame(width: 36, height: 36)

            Menu {
                if segment == .instruments {
                    Button {
                        isShowingAddInstrument = true
                    } label: {
                        Label("Add Instrument…", systemImage: "plus")
                    }
                    Divider()
                }

                if node != nil {
                    Button {
                        detach()
                    } label: {
                        Label("Detach Session", systemImage: "bolt.slash")
                    }
                    Button(role: .destructive) {
                        pendingKill = true
                    } label: {
                        Label("Kill Process", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    pendingDelete = true
                } label: {
                    Label("Delete Session", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var segmentBody: some View {
        switch segment {
        case .repl:
            REPLView(
                sessionID: sessionID,
                workspace: workspace,
                selection: $path.asSidebarSelection()
            )

        case .instruments:
            instrumentsList

        case .insights:
            insightsList

        case .captures:
            capturesList
        }
    }

    @ViewBuilder
    private var instrumentsList: some View {
        let instruments = workspace.engine.instrumentsBySession[sessionID] ?? []
        if instruments.isEmpty {
            segmentEmptyState(
                icon: "waveform.path.ecg",
                title: "No instruments yet",
                hint: nil,
                actionTitle: "Add Instrument…",
                action: { isShowingAddInstrument = true }
            )
        } else {
            List {
                ForEach(instruments) { instance in
                    Button {
                        path.append(.instrument(sessionID, instance.id))
                    } label: {
                        InstrumentRow(instance: instance, workspace: workspace)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await workspace.engine.removeInstrument(instance) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            let newState: LumaCore.InstrumentState = instance.state == .enabled ? .disabled : .enabled
                            Task {
                                await workspace.engine.setInstrumentState(instance, state: newState)
                            }
                        } label: {
                            Label(
                                instance.state == .enabled ? "Disable" : "Enable",
                                systemImage: instance.state == .enabled ? "pause.circle" : "play.circle"
                            )
                        }
                        .tint(instance.state == .enabled ? .orange : .green)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var insightsList: some View {
        let insights = (workspace.engine.insightsBySession[sessionID] ?? [])
            .sorted { $0.createdAt < $1.createdAt }
        if insights.isEmpty {
            segmentEmptyState(
                icon: "doc.text.magnifyingglass",
                title: "No insights yet",
                hint: "Long-press a NativePointer value and choose Open Memory or Open Disassembly to create one.",
                actionTitle: nil,
                action: nil
            )
        } else {
            List {
                ForEach(insights) { insight in
                    Button {
                        path.append(.insight(sessionID, insight.id))
                    } label: {
                        InsightRow(insight: insight)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            try? workspace.store.deleteInsight(id: insight.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var capturesList: some View {
        let captures = (workspace.engine.capturesBySession[sessionID] ?? [])
            .sorted { $0.capturedAt < $1.capturedAt }
        if captures.isEmpty {
            segmentEmptyState(
                icon: "waveform.path",
                title: "No captures yet",
                hint: "Run an ITrace session to capture one.",
                actionTitle: nil,
                action: nil
            )
        } else {
            List {
                ForEach(captures) { capture in
                    Button {
                        path.append(.capture(sessionID, capture.id))
                    } label: {
                        CaptureRow(capture: capture)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
    }

    private func segmentEmptyState(
        icon: String,
        title: String,
        hint: String?,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let hint {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func resumeBanner(session: LumaCore.ProcessSession, node: LumaCore.ProcessNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle")
            Text("Spawned \(session.processName). Ready to resume.")
                .font(.subheadline)
            Spacer()
            Button {
                Task { @MainActor in
                    await workspace.engine.resumeSpawnedProcess(node: node)
                }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }

    private func detach() {
        guard let node else { return }
        workspace.engine.removeNode(node)
    }

    private func killProcess() {
        guard let node, let session else { return }
        Task { @MainActor in
            do { try await node.kill() } catch {
                workspace.engine.updateSession(id: session.id) { $0.lastError = error.localizedDescription }
            }
        }
    }

    private func deleteSession() {
        if let node { workspace.engine.removeNode(node) }
        try? workspace.store.deleteSession(id: sessionID)
        if !path.isEmpty { path.removeLast() }
    }
}

private struct InstrumentRow: View {
    let instance: LumaCore.InstrumentInstance
    @ObservedObject var workspace: Workspace

    private var descriptor: InstrumentDescriptor? {
        workspace.engine.descriptor(for: instance)
    }

    var body: some View {
        HStack(spacing: 12) {
            InstrumentIconView(icon: descriptor?.icon ?? .system("puzzlepiece.extension"), pointSize: 20)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor?.displayName ?? "Instrument")
                    .font(.body)
                if instance.state == .disabled {
                    Text("Disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .opacity(instance.state == .enabled ? 1 : 0.55)
        .contentShape(Rectangle())
    }
}

private struct InsightRow: View {
    let insight: LumaCore.AddressInsight

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: insight.kind == .memory ? "doc.text.magnifyingglass" : "hammer")
                .frame(width: 28, height: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.body)
                Text(insight.anchor.displayString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct CaptureRow: View {
    let capture: LumaCore.ITraceCaptureRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .frame(width: 28, height: 28)
                .foregroundStyle(.tint)
            Text(capture.displayName).font(.body)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct PhoneSessionSwitcher: View {
    @ObservedObject var workspace: Workspace
    let current: UUID
    let onPick: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(workspace.engine.sessions) { session in
                Button {
                    onPick(session.id)
                } label: {
                    HStack(spacing: 8) {
                        PhoneSessionRow(session: session, workspace: workspace)
                        if session.id == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
            Button(action: onNew) {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("New Session…")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .frame(minWidth: 260, maxWidth: 340)
    }
}

#endif
