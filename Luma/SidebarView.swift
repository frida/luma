import Frida
import LumaCore
import SwiftUI

private let subrowIconWidth: CGFloat = 16

struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    var sessions: [LumaCore.ProcessSession] { workspace.engine.sessions }

    @State private var packages: [LumaCore.InstalledPackage] = []

    var body: some View {
        List(selection: $selection) {
            Section {
                SidebarNotebookRow()
                    .tag(SidebarItemID.notebook)
            }

            Section("Sessions") {
                ForEach(sessions) { session in
                    let node = workspace.engine.node(forSessionID: session.id)
                    let instruments = workspace.engine.instrumentsBySession[session.id] ?? []
                    let insights = workspace.engine.insightsBySession[session.id] ?? []
                    let captures = workspace.engine.capturesBySession[session.id] ?? []

                    SidebarSessionHeaderRow(
                        session: session,
                        node: node,
                        workspace: workspace,
                        selection: $selection
                    )

                    SidebarSessionREPLRow(sessionID: session.id)
                        .tag(SidebarItemID.repl(session.id))

                    ForEach(instruments) { instance in
                        SidebarInstrumentRow(
                            session: session,
                            node: node,
                            instance: instance,
                            workspace: workspace,
                            selection: $selection
                        )
                        .tag(SidebarItemID.instrument(session.id, instance.id))
                    }

                    ForEach(insights.sorted(by: { $0.createdAt < $1.createdAt })) { insight in
                        SidebarInsightRow(
                            session: session,
                            insight: insight,
                            workspace: workspace,
                            selection: $selection
                        )
                        .tag(SidebarItemID.insight(session.id, insight.id))
                    }

                    ForEach(captures.sorted(by: { $0.capturedAt < $1.capturedAt })) { capture in
                        SidebarITraceCaptureRow(
                            session: session,
                            capture: capture,
                            workspace: workspace,
                            selection: $selection
                        )
                        .tag(SidebarItemID.itraceCapture(session.id, capture.id))
                    }
                }
            }

            if !packages.isEmpty {
                Section("Packages") {
                    ForEach(packages) { pkg in
                        SidebarPackageRow(package: pkg)
                            .tag(SidebarItemID.package(pkg.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarNotebookRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.pages")
                .foregroundStyle(.tint)
            Text("Notebook")
        }
    }
}

private struct SidebarSessionHeaderRow: View {
    let session: LumaCore.ProcessSession
    let node: LumaCore.ProcessNode?
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var isShowingConfirmation = false
    @State private var confirmationTitle: String = ""
    @State private var confirmationMessage: String?
    @State private var confirmationDestructiveLabel: String = "Confirm"
    @State private var pendingConfirmation: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayProcessName).font(.headline)
                Text(displayDeviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let node {
                Button(role: .destructive) {
                    presentConfirmation(
                        title: "Kill Process?",
                        message: "This will force-terminate \"\(displayProcessName)\".",
                        destructiveLabel: "Kill Process"
                    ) { killProcess() }
                } label: {
                    Label("Kill Process", systemImage: "xmark.circle")
                }

                Button {
                    workspace.engine.removeNode(node)
                } label: {
                    Label("Detach Session", systemImage: "bolt.slash")
                }
            } else {
                Button {
                    reestablish()
                } label: {
                    Label("\(session.kind.reestablishLabel)…", systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Button(role: .destructive) {
                presentConfirmation(
                    title: "Delete Session?",
                    message: "This will remove the session and its history.",
                    destructiveLabel: "Delete Session"
                ) { deleteSession() }
            } label: {
                Label("Delete Session", systemImage: "trash")
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button(confirmationDestructiveLabel, role: .destructive) {
                pendingConfirmation?()
                pendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                pendingConfirmation = nil
            }
        } message: {
            if let confirmationMessage { Text(confirmationMessage) }
        }
    }

    private var displayProcessName: String { node?.process.name ?? session.processName }
    private var displayDeviceName: String { node?.device.name ?? session.deviceName }

    @ViewBuilder
    private var iconView: some View {
        if let node, let lastIcon = node.process.icons.last {
            lastIcon.swiftUIImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .cornerRadius(4)
        } else if let data = session.iconPNGData {
            Icon.png(data: Array(data)).swiftUIImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                )
        } else {
            Image(systemName: "app")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .opacity(0.7)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                )
        }
    }

    private func reestablish() {
        Task { @MainActor in
            let result = await workspace.engine.reestablishSession(id: session.id)
            if case .needsUserInput(let reason, let session) = result {
                workspace.targetPickerContext = .reestablish(session: session, reason: reason)
            }
        }
    }

    private func killProcess() {
        guard let node else { return }
        Task { @MainActor in
            let pid = session.lastKnownPID
            do { try await node.device.kill(pid) } catch {
                workspace.engine.updateSession(id: session.id) { $0.lastError = error.localizedDescription }
            }
        }
    }

    private func deleteSession() {
        if let node { workspace.engine.removeNode(node) }
        let sessionID = session.id

        try? workspace.store.deleteSession(id: sessionID)

        switch selection {
        case .repl(let id) where id == sessionID,
            .instrument(let id, _) where id == sessionID,
            .insight(let id, _) where id == sessionID,
            .itraceCapture(let id, _) where id == sessionID:
            selection = .notebook
        default:
            break
        }
    }

    private func presentConfirmation(
        title: String,
        message: String? = nil,
        destructiveLabel: String,
        action: @escaping () -> Void
    ) {
        confirmationTitle = title
        confirmationMessage = message
        confirmationDestructiveLabel = destructiveLabel
        pendingConfirmation = action
        isShowingConfirmation = true
    }
}

private struct SidebarSessionREPLRow: View {
    let sessionID: UUID
    private let iconWidth: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .frame(width: iconWidth, alignment: .center)
                .font(.system(size: 12))
            Text("REPL")
            Spacer()
        }
        .font(.callout)
        .padding(.leading, 20)
        .contentShape(Rectangle())
    }
}

private struct SidebarInstrumentRow: View {
    let session: LumaCore.ProcessSession
    let node: LumaCore.ProcessNode?
    let instance: LumaCore.InstrumentInstance
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var isShowingDeleteConfirm = false

    private var descriptor: InstrumentDescriptor? {
        workspace.engine.descriptor(for: instance)
    }

    private var displayName: String {
        descriptor?.displayName ?? "Instrument"
    }

    var body: some View {
        HStack(spacing: 6) {
            InstrumentIconView(icon: descriptor?.icon ?? .system("puzzlepiece.extension"), pointSize: 12)
                .frame(width: subrowIconWidth, alignment: .center)
            Text(displayName)
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, 20)
        .opacity(instance.isEnabled ? 1 : 0.3)
        .contextMenu {
            Button {
                Task { @MainActor in
                    await workspace.engine.setInstrumentEnabled(instance, enabled: !instance.isEnabled)
                }
            } label: {
                Label(
                    instance.isEnabled
                        ? "Disable \"\(displayName)\""
                        : "Enable \"\(displayName)\"",
                    systemImage: instance.isEnabled ? "pause.circle" : "play.circle"
                )
            }

            Divider()

            Button(role: .destructive) {
                isShowingDeleteConfirm = true
            } label: {
                Label("Delete Instrument", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete Instrument?",
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Instrument", role: .destructive) {
                deleteInstrument()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(displayName)\" from this session.")
        }
    }

    private func deleteInstrument() {
        Task {
            await workspace.engine.removeInstrument(instance)
        }

        if selection == .instrument(session.id, instance.id) {
            selection = .repl(session.id)
        }
    }
}

private struct SidebarInsightRow: View {
    let session: LumaCore.ProcessSession
    let insight: LumaCore.AddressInsight
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: insight.kind == .memory ? "doc.text.magnifyingglass" : "hammer")
                .frame(width: subrowIconWidth, alignment: .center)
                .font(.system(size: 12))
            Text(insight.title)
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, 20)
        .help(insight.anchor.displayString)
        .contextMenu {
            Button(role: .destructive) {
                deleteInsight()
            } label: {
                Label("Delete Insight", systemImage: "trash")
            }
        }
    }

    private func deleteInsight() {
        try? workspace.store.deleteInsight(id: insight.id)

        if selection == .insight(session.id, insight.id) {
            selection = .repl(session.id)
        }
    }
}

private struct SidebarITraceCaptureRow: View {
    let session: LumaCore.ProcessSession
    let capture: LumaCore.ITraceCaptureRecord
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path")
                .frame(width: subrowIconWidth, alignment: .center)
                .font(.system(size: 12))
            Text(capture.displayName)
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, 20)
        .contextMenu {
            Button(role: .destructive) {
                deleteCapture()
            } label: {
                Label("Delete Capture", systemImage: "trash")
            }
        }
    }

    private func deleteCapture() {
        // ITraceCaptureRecord doesn't have a store.delete yet,
        // but we can at least clean up the selection
        if selection == .itraceCapture(session.id, capture.id) {
            selection = .repl(session.id)
        }
    }
}

private struct SidebarPackageRow: View {
    let package: LumaCore.InstalledPackage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                    .font(.headline)
                Text(package.version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

