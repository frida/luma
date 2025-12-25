import Frida
import SwiftData
import SwiftUI

private let subrowIconWidth: CGFloat = 16

struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Query(sort: \ProcessSession.createdAt, order: .forward)
    private var sessions: [ProcessSession]

    @Query private var packageStates: [ProjectPackagesState]

    private var projectPackages: ProjectPackagesState? {
        packageStates.first
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                SidebarNotebookRow()
                    .tag(SidebarItemID.notebook)
            }

            Section("Sessions") {
                ForEach(sessions) { session in
                    let node = workspace.processNodes.first(where: { $0.sessionRecord == session })

                    SidebarSessionHeaderRow(
                        session: session,
                        node: node,
                        workspace: workspace,
                        selection: $selection
                    )

                    SidebarSessionREPLRow(sessionID: session.id)
                        .tag(SidebarItemID.repl(session.id))

                    ForEach(session.instruments) { instance in
                        let runtime = node?.instruments.first(where: { $0.id == instance.id })
                        SidebarInstrumentRow(
                            session: session,
                            node: node,
                            instance: instance,
                            runtime: runtime,
                            workspace: workspace,
                            selection: $selection
                        )
                        .tag(SidebarItemID.instrument(session.id, instance.id))
                    }

                    ForEach(session.insights.sorted(by: { $0.createdAt < $1.createdAt })) { insight in
                        SidebarInsightRow(
                            session: session,
                            insight: insight,
                            selection: $selection
                        )
                        .tag(SidebarItemID.insight(session.id, insight.id))
                    }
                }
            }

            if let projectPackages {
                Section("Packages") {
                    ForEach(projectPackages.packages) { pkg in
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
    let session: ProcessSession
    let node: ProcessNode?
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Environment(\.modelContext) private var modelContext

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
                        message: "This will force-terminate “\(displayProcessName)”.",
                        destructiveLabel: "Kill Process"
                    ) { killProcess() }
                } label: {
                    Label("Kill Process", systemImage: "xmark.circle")
                }

                Button {
                    workspace.removeNode(node)
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
            await workspace.reestablishSession(for: session, modelContext: modelContext)
        }
    }

    private func killProcess() {
        guard let node else { return }
        Task { @MainActor in
            let pid = node.sessionRecord.lastKnownPID
            do { try await node.device.kill(pid) } catch {
                node.sessionRecord.lastError =
                    error as? Error ?? .invalidOperation(error.localizedDescription)
            }
        }
    }

    private func deleteSession() {
        if let node { workspace.removeNode(node) }
        let sessionID = session.id

        switch selection {
        case .repl(let id) where id == sessionID,
            .instrument(let id, _) where id == sessionID,
            .insight(let id, _) where id == sessionID:
            selection = .notebook
        default:
            break
        }

        modelContext.delete(
            try! modelContext
                .fetch(
                    FetchDescriptor<ProcessSession>(
                        predicate: #Predicate { $0.id == sessionID }
                    )
                )
                .first!
        )
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
    let session: ProcessSession
    let node: ProcessNode?
    let instance: InstrumentInstance
    let runtime: InstrumentRuntime?
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Environment(\.modelContext) private var modelContext
    @State private var isShowingDeleteConfirm = false

    var body: some View {
        HStack(spacing: 6) {
            InstrumentIconView(icon: instance.displayIcon, pointSize: 12)
                .frame(width: subrowIconWidth, alignment: .center)
            Text(instance.displayName)
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, 20)
        .opacity(instance.isEnabled ? 1 : 0.3)
        .contextMenu {
            Button {
                Task { @MainActor in
                    await workspace.setInstrumentEnabled(instance, enabled: !instance.isEnabled)
                }
            } label: {
                Label(
                    instance.isEnabled
                        ? "Disable “\(instance.displayName)”"
                        : "Enable “\(instance.displayName)”",
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
            Text("This will remove “\(instance.displayName)” from this session.")
        }
    }

    private func deleteInstrument() {
        workspace.removeInstrument(instance, from: session)

        if selection == .instrument(session.id, instance.id) {
            selection = .repl(session.id)
        }
    }
}

private struct SidebarInsightRow: View {
    let session: ProcessSession
    let insight: AddressInsight
    @Binding var selection: SidebarItemID?

    @Environment(\.modelContext) private var modelContext

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
        if let idx = session.insights.firstIndex(where: { $0.id == insight.id }) {
            session.insights.remove(at: idx)
        }

        if selection == .insight(session.id, insight.id) {
            selection = .repl(session.id)
        }

        modelContext.delete(insight)
    }
}

private struct SidebarPackageRow: View {
    let package: InstalledPackage

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
