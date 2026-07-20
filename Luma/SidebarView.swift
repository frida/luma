import Frida
import LumaCore
import SwiftUI

let sidebarRowLeadingPad: CGFloat = 3
let sidebarChevronWidth: CGFloat = 14
let sidebarChevronToIconSpacing: CGFloat = 5
let sidebarIconToLabelSpacing: CGFloat = 6
let sidebarParentIconWidth: CGFloat = 24
let sidebarChildIconWidth: CGFloat = 16

let sidebarChildIndent: CGFloat =
    sidebarRowLeadingPad + sidebarChevronWidth + sidebarChevronToIconSpacing + sidebarParentIconWidth
let sidebarGrandchildIndent: CGFloat = sidebarChildIndent + sidebarChildIconWidth

private let subrowIconWidth: CGFloat = sidebarChildIconWidth

struct SidebarView: View {
    let engine: Engine
    @Binding var selection: SidebarItemID?

    var sessions: [LumaCore.ProcessSession] { engine.sessions }
    var packages: [LumaCore.InstalledPackage] { engine.installedPackages }
    var missions: [LumaCore.Mission] { engine.missions }

    var body: some View {
        List(selection: $selection) {
            Section {
                SidebarNotebookRow()
                    .tag(SidebarItemID.notebook)
                SidebarPharoRow()
                    .tag(SidebarItemID.pharo)
                SidebarMissionsRow(count: missions.count)
                    .tag(SidebarItemID.missions)
                ForEach(missions) { mission in
                    SidebarMissionRow(mission: mission, engine: engine, selection: $selection)
                        .tag(SidebarItemID.mission(mission.id))
                }
            }

            Section("Sessions") {
                ForEach(sessions) { session in
                    let node = engine.node(forSessionID: session.id)
                    let instruments = engine.instrumentsBySession[session.id] ?? []
                    let insights = engine.insightsBySession[session.id] ?? []
                    let traces = engine.tracesBySession[session.id] ?? []
                    let isExpanded = engine.sidebarExpansion(forSessionID: session.id) == .expanded

                    SidebarSessionHeaderRow(
                        session: session,
                        node: node,
                        engine: engine,
                        selection: $selection,
                        isExpanded: isExpanded,
                        onToggleExpansion: { toggleSessionExpansion(sessionID: session.id) }
                    )
                    .tag(SidebarItemID.session(session.id))

                    if isExpanded {
                        moduleGroup(session: session)
                        threadGroup(session: session)

                        SidebarSessionREPLRow(sessionID: session.id)
                            .tag(SidebarItemID.repl(session.id))

                        ForEach(instruments) { instance in
                            let hasChildren = hasInstrumentChildren(instance: instance)
                            let hooksExpanded = engine.hooksExpansion(forSessionID: session.id, instrumentID: instance.id) == .expanded
                            SidebarInstrumentRow(
                                session: session,
                                node: node,
                                instance: instance,
                                engine: engine,
                                hasChildren: hasChildren,
                                isExpanded: hooksExpanded,
                                onToggle: { toggleHooksExpansion(sessionID: session.id, instrumentID: instance.id) },
                                selection: $selection
                            )
                            .tag(SidebarItemID.instrument(session.id, instance.id))

                            if hasChildren, hooksExpanded {
                                instrumentChildren(sessionID: session.id, instance: instance)
                            }
                        }

                        ForEach(insights.sorted(by: { $0.createdAt < $1.createdAt })) { insight in
                            SidebarInsightRow(
                                session: session,
                                insight: insight,
                                engine: engine,
                                selection: $selection
                            )
                            .tag(SidebarItemID.insight(session.id, insight.id))
                        }

                        ForEach(traces.sorted(by: { $0.startedAt < $1.startedAt })) { trace in
                            SidebarITraceRow(
                                session: session,
                                trace: trace,
                                engine: engine,
                                selection: $selection
                            )
                            .tag(SidebarItemID.itrace(session.id, trace.id))
                        }
                    }
                }

            }

            CustomInstrumentsSidebarSection(engine: engine, selection: $selection)

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
        .onChange(of: selection) { _, newSelection in
            ensureSessionExpanded(for: newSelection)
        }
    }

    private func ensureSessionExpanded(for newSelection: SidebarItemID?) {
        guard let sessionID = sessionID(in: newSelection),
            engine.sidebarExpansion(forSessionID: sessionID) == .collapsed
        else { return }
        engine.setSidebarExpansion(sessionID: sessionID, .expanded)
    }

    private func sessionID(in selection: SidebarItemID?) -> UUID? {
        switch selection {
        case .session(let id),
            .repl(let id),
            .module(let id, _),
            .thread(let id, _),
            .instrument(let id, _),
            .instrumentComponent(let id, _, _),
            .insight(let id, _),
            .itrace(let id, _):
            return id
        default:
            return nil
        }
    }

    @ViewBuilder
    private func moduleGroup(session: LumaCore.ProcessSession) -> some View {
        let count = session.lastKnownModules?.count ?? 0
        let isExpanded = engine.sidebarExpansion(forSessionID: session.id, group: .modules) == .expanded
        SidebarGroupHeaderRow(
            title: "Modules",
            systemImage: "shippingbox",
            count: count,
            isExpanded: isExpanded,
            onToggle: { toggleGroupExpansion(sessionID: session.id, group: .modules) }
        )
        if isExpanded, count > 0 {
            ModuleSidebarChildren(sessionID: session.id, engine: engine, selection: $selection)
        }
    }

    @ViewBuilder
    private func threadGroup(session: LumaCore.ProcessSession) -> some View {
        let count = session.lastKnownThreads?.count ?? 0
        let isExpanded = engine.sidebarExpansion(forSessionID: session.id, group: .threads) == .expanded
        SidebarGroupHeaderRow(
            title: "Threads",
            systemImage: "cpu",
            count: count,
            isExpanded: isExpanded,
            onToggle: { toggleGroupExpansion(sessionID: session.id, group: .threads) }
        )
        if isExpanded, count > 0 {
            ThreadSidebarChildren(sessionID: session.id, engine: engine, selection: $selection)
        }
    }

    private func toggleGroupExpansion(sessionID: UUID, group: SessionSidebarGroup) {
        let current = engine.sidebarExpansion(forSessionID: sessionID, group: group)
        let next: SidebarExpansion = current == .expanded ? .collapsed : .expanded
        withAnimation(.easeInOut(duration: 0.18)) {
            engine.setSidebarExpansion(sessionID: sessionID, group: group, next)
        }
    }

    private func toggleSessionExpansion(sessionID: UUID) {
        let current = engine.sidebarExpansion(forSessionID: sessionID)
        let next: SidebarExpansion = current == .expanded ? .collapsed : .expanded
        withAnimation(.easeInOut(duration: 0.18)) {
            engine.setSidebarExpansion(sessionID: sessionID, next)
        }
    }

    @ViewBuilder
    private func instrumentChildren(sessionID: UUID, instance: LumaCore.InstrumentInstance) -> some View {
        if let ui = InstrumentUIRegistry.shared.ui(for: instance) {
            ui.sidebarChildren(
                sessionID: sessionID,
                instance: instance,
                engine: engine,
                selection: $selection
            )
        }
    }

    private func hasInstrumentChildren(instance: LumaCore.InstrumentInstance) -> Bool {
        InstrumentUIRegistry.shared.ui(for: instance)?.hasSidebarChildren(instance: instance) ?? false
    }

    private func toggleHooksExpansion(sessionID: UUID, instrumentID: UUID) {
        let current = engine.hooksExpansion(forSessionID: sessionID, instrumentID: instrumentID)
        let next: SidebarExpansion = current == .expanded ? .collapsed : .expanded
        withAnimation(.easeInOut(duration: 0.18)) {
            engine.setHooksExpansion(sessionID: sessionID, instrumentID: instrumentID, next)
        }
    }
}


private struct SidebarNotebookRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.pages")
                .frame(width: 18, alignment: .center)
            Text("Notebook")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.notebook")
    }
}

private struct SidebarPharoRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "curlybraces.square")
                .frame(width: 18, alignment: .center)
            Text("Pharo")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.pharo")
    }
}

private struct SidebarMissionsRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .frame(width: 18, alignment: .center)
            Text("Missions")
            Spacer()
            if count > 0 {
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.missions")
    }
}

private struct SidebarMissionRow: View {
    let mission: LumaCore.Mission
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: subrowIconWidth)
            Text(displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, sidebarChildIndent)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.mission.\(mission.id.uuidString)")
        .contextMenu {
            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                Label("Delete Mission", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete Mission?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Mission", role: .destructive) { deleteMission() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the mission and all of its turns, tool calls, and findings.")
        }
    }

    private func deleteMission() {
        if selection == .mission(mission.id) {
            selection = .missions
        }
        engine.deleteMission(missionID: mission.id)
    }

    private var displayTitle: String {
        if let title = mission.title, !title.isEmpty { return title }
        return mission.goalText.isEmpty ? "(untitled mission)" : mission.goalText
    }

    private var iconName: String {
        switch mission.status {
        case .running, .drafting: return "circle.dotted"
        case .awaitingApproval: return "hourglass"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon"
        case .cancelled: return "stop.circle"
        }
    }

    private var iconColor: Color {
        switch mission.status {
        case .running: return .blue
        case .awaitingApproval: return .orange
        case .completed: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

private struct SidebarDisclosure: View {
    let isExpanded: Bool
    var canToggle: Bool = true
    let onToggle: () -> Void

    var body: some View {
        chevron
            .padding(.leading, sidebarChildIndent - sidebarChevronWidth - sidebarChevronToIconSpacing)
            .padding(.trailing, sidebarChevronToIconSpacing)
    }

    @ViewBuilder
    private var chevron: some View {
        if canToggle {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: sidebarChevronWidth, height: sidebarChevronWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: sidebarChevronWidth, height: sidebarChevronWidth)
        }
    }
}

private struct SidebarGroupHeaderRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SidebarDisclosure(isExpanded: isExpanded, onToggle: onToggle)
                .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")

            Image(systemName: systemImage)
                .frame(width: sidebarChildIconWidth, alignment: .center)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.trailing, sidebarIconToLabelSpacing)

            Text(title)
                .font(.callout)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

private struct SidebarSessionHeaderRow: View {
    let session: LumaCore.ProcessSession
    let node: LumaCore.ProcessNode?
    let engine: Engine
    @Binding var selection: SidebarItemID?
    let isExpanded: Bool
    let onToggleExpansion: () -> Void

    @Environment(TargetPicker.self) private var picker

    @State private var isShowingConfirmation = false
    @State private var confirmationTitle: String = ""
    @State private var confirmationMessage: String?
    @State private var confirmationDestructiveLabel: String = "Confirm"
    @State private var pendingConfirmation: (() -> Void)?

    @State private var isShowingArmPrompt = false
    @State private var armPatternDraft: String = ""

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggleExpansion) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: sidebarChevronWidth, height: sidebarChevronWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, sidebarRowLeadingPad)
            .padding(.trailing, sidebarChevronToIconSpacing)
            .accessibilityLabel(isExpanded ? "Collapse session" : "Expand session")

            iconView
                .frame(width: sidebarParentIconWidth, height: sidebarParentIconWidth)
                .padding(.trailing, sidebarIconToLabelSpacing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(displayProcessName).font(.headline)
                    if isArmed {
                        Image(systemName: "scope")
                            .font(.caption2)
                            .help("Armed for next matching launch")
                    }
                }
                Text(displayDeviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            hostBadge

            if isDetached {
                detachedIndicator
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !engine.localUserHosts(session.id) {
                if engine.canTakeHosting(session) {
                    Button {
                        rehost()
                    } label: {
                        Label("Run on My Device…", systemImage: "rectangle.connected.to.line.below")
                    }
                }
            } else if let node {
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
                    engine.removeNode(node)
                } label: {
                    Label("Detach Session", systemImage: "bolt.slash")
                }

                Divider()

                armingMenuButton

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
            } else {
                if session.lastAttachedAt != nil, engine.canTakeHosting(session) {
                    Button {
                        reestablish()
                    } label: {
                        Label("\(session.kind.reestablishLabel)…", systemImage: "arrow.clockwise")
                    }
                }

                armingMenuButton

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
        .alert("Arm for Next Launch", isPresented: $isShowingArmPrompt) {
            TextField("Identifier regex", text: $armPatternDraft)
                .disableAutocorrection(true)
            Button("Arm") { commitArm() }
                .disabled(armPatternDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Match the next spawn whose identifier matches this regex on \(session.deviceName).")
        }
    }

    @ViewBuilder
    private var armingMenuButton: some View {
        if isArmed {
            Button {
                disarm()
            } label: {
                Label("Disarm", systemImage: "scope")
            }
        } else if session.supportsArmForNextLaunch {
            Button {
                presentArmPrompt()
            } label: {
                Label("Arm for Next Launch…", systemImage: "scope")
            }
        }
    }

    private var isArmed: Bool {
        if case .armed = session.armingState { return true }
        return false
    }

    private var isDetached: Bool {
        guard node == nil, !isArmed else { return false }
        if isHostedRemotelyLive { return false }
        if session.lastAttachedAt != nil { return true }
        if case .attach = session.kind { return true }
        return false
    }

    private var isHostedRemotelyLive: Bool {
        engine.isHostedRemotelyLive(session.id)
    }

    @ViewBuilder
    private var detachedIndicator: some View {
        if session.phase == .attaching {
            ProgressView()
                .controlSize(.small)
                .help(session.kind.inProgressLabel)
        } else {
            Button(action: reestablish) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(detachedTint)
            }
            .buttonStyle(.plain)
            .help("\(session.kind.reestablishLabel)")
        }
    }

    private var detachedTint: Color {
        switch session.detachReason {
        case .applicationRequested:
            return .orange
        default:
            return .red
        }
    }

    private func presentArmPrompt() {
        armPatternDraft = engine.defaultArmPattern(for: session)
        isShowingArmPrompt = true
    }

    private func commitArm() {
        let pattern = armPatternDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        let sessionID = session.id
        Task { @MainActor in
            await engine.armSession(id: sessionID, matchPattern: pattern)
        }
    }

    private func disarm() {
        let sessionID = session.id
        Task { @MainActor in
            await engine.disarmSession(id: sessionID)
        }
    }

    private var displayProcessName: String { node?.processName ?? session.processName }
    private var displayDeviceName: String { node?.deviceName ?? session.deviceName }

    @ViewBuilder
    private var iconView: some View {
        if let data = session.iconPNGData {
            Icon.png(data: Array(data)).swiftUIImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .cornerRadius(4)
        } else {
            IconPlaceholderView(
                seed: placeholderSeed,
                displayName: displayProcessName,
                cornerRadius: 4
            )
        }
    }

    @ViewBuilder
    private var hostBadge: some View {
        if let host = session.host,
           !engine.isHostingNode(session.id),
           host.id != engine.collaboration.localUser?.id
        {
            UserAvatarView(user: host, size: 16)
                .help("Hosted by @\(host.id) on \(session.deviceName)")
        }
    }

    private var placeholderSeed: String {
        "\(session.deviceID)/\(displayProcessName)"
    }

    private func reestablish() {
        Task { @MainActor in
            let result: Engine.ReestablishResult
            if localUserOwnsHost {
                result = await engine.reestablishSession(id: session.id)
            } else {
                result = await engine.reHost(sessionID: session.id)
            }
            if case .needsUserInput(let reason, let session) = result {
                picker.context = .reestablish(session: session, reason: reason)
            }
        }
    }

    private func rehost() {
        Task { @MainActor in
            let result = await engine.reHost(sessionID: session.id)
            if case .needsUserInput(let reason, let session) = result {
                picker.context = .reestablish(session: session, reason: reason)
            }
        }
    }

    private var localUserOwnsHost: Bool {
        guard let host = session.host else { return true }
        return host.id == engine.collaboration.localUser?.id
    }

    private func killProcess() {
        guard let node else { return }
        Task { @MainActor in
            do { try await node.kill() } catch {
                engine.updateSession(id: session.id) { $0.lastError = error.localizedDescription }
            }
        }
    }

    private func deleteSession() {
        if let node { engine.removeNode(node) }
        let sessionID = session.id

        try? engine.store.deleteSession(id: sessionID)

        switch selection {
        case .session(let id) where id == sessionID,
            .repl(let id) where id == sessionID,
            .instrument(let id, _) where id == sessionID,
            .insight(let id, _) where id == sessionID,
            .itrace(let id, _) where id == sessionID:
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
        .padding(.leading, sidebarChildIndent)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.repl")
    }
}

private struct SidebarInstrumentRow: View {
    let session: LumaCore.ProcessSession
    let node: LumaCore.ProcessNode?
    let instance: LumaCore.InstrumentInstance
    let engine: Engine
    let hasChildren: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    @Binding var selection: SidebarItemID?

    @State private var isShowingDeleteConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarDisclosure(isExpanded: isExpanded, canToggle: hasChildren, onToggle: onToggle)

            InstrumentIconView(icon: descriptor.icon, pointSize: 12)
                .frame(width: subrowIconWidth, alignment: .center)
                .padding(.trailing, sidebarIconToLabelSpacing)
            Text(descriptor.displayName)
            if let status = runtimeStatus {
                InstrumentStatusIndicator(status: status)
                    .padding(.leading, 6)
            }
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .opacity(instance.state == .enabled ? 1 : 0.3)
        .contextMenu {
            Button {
                let newState: LumaCore.InstrumentState = instance.state == .enabled ? .disabled : .enabled
                Task { @MainActor in
                    await engine.setInstrumentState(instance, state: newState)
                }
            } label: {
                Label(
                    instance.state == .enabled
                        ? "Disable \"\(descriptor.displayName)\""
                        : "Enable \"\(descriptor.displayName)\"",
                    systemImage: instance.state == .enabled ? "pause.circle" : "play.circle"
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
            Text("This will remove \"\(descriptor.displayName)\" from this session.")
        }
    }

    private var descriptor: InstrumentDescriptor {
        engine.descriptor(for: instance)
    }

    private var runtimeStatus: InstrumentStatus? {
        node?.instruments.first(where: { $0.id == instance.id })?.status
    }

    private func deleteInstrument() {
        Task {
            await engine.removeInstrument(instance)
        }

        if selection == .instrument(session.id, instance.id) {
            selection = .repl(session.id)
        }
    }
}

private struct SidebarInsightRow: View {
    let session: LumaCore.ProcessSession
    let insight: LumaCore.AddressInsight
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var isRenaming = false
    @State private var renameDraft = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: insight.kind == .memory ? "memorychip" : "cpu")
                .frame(width: subrowIconWidth, alignment: .center)
                .font(.system(size: 12))
            Text(engine.displayTitle(for: insight))
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, sidebarChildIndent)
        .help(insight.anchor.displayString)
        .contextMenu {
            Button {
                renameDraft = engine.displayTitle(for: insight)
                isRenaming = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                deleteInsight()
            } label: {
                Label("Delete Insight", systemImage: "trash")
            }
        }
        .alert("Rename Insight", isPresented: $isRenaming) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != engine.displayTitle(for: insight) else { return }
                engine.renameInsight(insight, to: trimmed)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func deleteInsight() {
        try? engine.store.deleteInsight(id: insight.id)

        if selection == .insight(session.id, insight.id) {
            selection = .repl(session.id)
        }
    }
}

private struct SidebarITraceRow: View {
    let session: LumaCore.ProcessSession
    let trace: LumaCore.ITrace
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var isShowingDeleteConfirm = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: trace.isRunning ? "record.circle" : "waveform.path")
                .frame(width: subrowIconWidth, alignment: .center)
                .font(.system(size: 12))
                .foregroundStyle(trace.isRunning ? .red : .primary)
            Text(trace.displayName)
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, sidebarChildIndent)
        .contextMenu {
            Button(role: .destructive) {
                isShowingDeleteConfirm = true
            } label: {
                Label("Delete Trace", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete trace \(trace.displayName)?",
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteTrace()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the recorded ITrace data from the project.")
        }
    }

    private func deleteTrace() {
        engine.deleteITrace(id: trace.id, sessionID: session.id)
        if selection == .itrace(session.id, trace.id) {
            selection = .repl(session.id)
        }
    }
}


private struct SidebarPackageRow: View {
    let package: LumaCore.InstalledPackage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
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

