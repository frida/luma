import Frida
import SwiftData
import SwiftUI

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
                    SidebarSessionRow(
                        session: session,
                        node: node,
                        workspace: workspace,
                        selection: $selection
                    )
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

struct SidebarPackageRow: View {
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

struct SidebarNotebookRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.pages")
                .foregroundStyle(.tint)
            Text("Notebook")
        }
    }
}

struct SidebarSessionRow: View {
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                iconView
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayProcessName)
                        .font(.headline)
                    Text(displayDeviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                    Text("REPL")
                    Spacer()
                }
                .font(.callout)
                .contentShape(Rectangle())
                .padding(.leading, 20)
                .background(
                    selection == .repl(session.id)
                        ? Color.accentColor.opacity(0.15).clipShape(RoundedRectangle(cornerRadius: 4))
                        : nil
                )
                .onTapGesture {
                    selection = .repl(session.id)
                }

                ForEach(session.instruments) { instance in
                    let runtime = node?.instruments.first(where: { $0.id == instance.id })
                    SidebarInstrumentRow(
                        sessionID: session.id,
                        instance: instance,
                        runtime: runtime,
                        selection: $selection,
                        workspace: workspace
                    )
                }

                if !session.insights.isEmpty {
                    Divider()
                        .padding(.leading, 20)
                        .padding(.vertical, 2)

                    ForEach(session.insights.sorted(by: { $0.createdAt < $1.createdAt })) { insight in
                        SidebarInsightRow(
                            sessionID: session.id,
                            insight: insight,
                            selection: $selection
                        )
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = .repl(session.id)
        }
        .contextMenu {
            if case .instrument(let sessionID, let instrumentID) = selection,
                sessionID == session.id,
                let instrument = session.instruments.first(where: { $0.id == instrumentID })
            {
                Button {
                    Task { @MainActor in
                        await workspace.setInstrumentEnabled(
                            instrument,
                            enabled: !instrument.isEnabled
                        )
                    }
                } label: {
                    Label(
                        instrument.isEnabled
                            ? "Disable “\(instrument.displayName)”"
                            : "Enable “\(instrument.displayName)”",
                        systemImage: instrument.isEnabled ? "pause.circle" : "play.circle"
                    )
                }

                Button(role: .destructive) {
                    presentConfirmation(
                        title: "Delete Instrument?",
                        message: "This will remove “\(instrument.displayName)” from this session.",
                        destructiveLabel: "Delete Instrument"
                    ) {
                        deleteInstrument(instrument)
                    }
                } label: {
                    Label("Delete Instrument", systemImage: "trash")
                }

                Divider()
            }

            if case .insight(let sessionID, let insightID) = selection,
                sessionID == session.id,
                let insight = session.insights.first(where: { $0.id == insightID })
            {
                Button(role: .destructive) {
                    deleteInsight(insight)
                } label: {
                    Label("Delete Insight", systemImage: "trash")
                }

                Divider()
            }

            if let node {
                Button(role: .destructive) {
                    presentConfirmation(
                        title: "Kill Process?",
                        message: "This will force-terminate “\(displayProcessName)”.",
                        destructiveLabel: "Kill Process"
                    ) {
                        killProcess()
                    }
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
                ) {
                    deleteSession()
                }
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
            if let confirmationMessage {
                Text(confirmationMessage)
            }
        }
    }

    private var displayProcessName: String {
        if let node {
            return node.process.name
        } else {
            return session.processName
        }
    }

    private var displayDeviceName: String {
        if let node {
            return node.device.name
        } else {
            return session.deviceName
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let node, let lastIcon = node.process.icons.last {
            lastIcon.swiftUIImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .cornerRadius(4)
        } else if let data = session.iconPNGData,
            let nsImage = NSImage(data: data)
        {
            Image(nsImage: nsImage)
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

            do {
                try await node.device.kill(pid)
            } catch {
                node.sessionRecord.lastError =
                    error as? Error ?? .invalidOperation(error.localizedDescription)
            }
        }
    }

    private func deleteInstrument(_ instrument: InstrumentInstance) {
        if let node,
            let idx = node.instruments.firstIndex(where: { $0.instance == instrument })
        {
            let runtime = node.instruments.remove(at: idx)
            Task { @MainActor in
                await runtime.dispose()
            }
        }

        if let idx = session.instruments.firstIndex(where: { $0.id == instrument.id }) {
            session.instruments.remove(at: idx)
        }

        if case .instrument(let sessionID, let instrumentID) = selection,
            sessionID == session.id,
            instrumentID == instrument.id
        {
            selection = .repl(session.id)
        }

        modelContext.delete(instrument)
    }

    private func deleteInsight(_ insight: AddressInsight) {
        if let idx = session.insights.firstIndex(where: { $0.id == insight.id }) {
            session.insights.remove(at: idx)
        }

        if case .insight(let sessionID, let insightID) = selection,
            sessionID == session.id,
            insightID == insight.id
        {
            selection = .repl(session.id)
        }

        modelContext.delete(insight)
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

    private func deleteSession() {
        if let node {
            workspace.removeNode(node)
        }

        let sessionID = session.id

        switch selection {
        case .repl(let id) where id == sessionID,
            .instrument(let id, _) where id == sessionID:
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
}

struct SidebarInstrumentRow: View {
    let sessionID: UUID
    let instance: InstrumentInstance
    let runtime: InstrumentRuntime?
    @Binding var selection: SidebarItemID?
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 6) {
            InstrumentIconView(icon: instance.displayIcon, pointSize: 12)
            Text(instance.displayName)

            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, 20)
        .opacity(instance.isEnabled ? 1 : 0.3)
        .background(
            (selection == .instrument(sessionID, instance.id)
                ? Color.accentColor.opacity(0.15)
                : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        )
        .onTapGesture {
            selection = .instrument(sessionID, instance.id)
        }
    }
}

private struct SidebarInsightRow: View {
    let sessionID: UUID
    let insight: AddressInsight
    @Binding var selection: SidebarItemID?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: insight.kind == .memory ? "doc.text.magnifyingglass" : "hammer")
                .font(.system(size: 12))
            Text(insight.title)
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, 20)
        .background(
            (selection == .insight(sessionID, insight.id)
                ? Color.accentColor.opacity(0.15)
                : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        )
        .onTapGesture {
            selection = .insight(sessionID, insight.id)
        }
        .help(insight.anchor.displayString)
    }
}
