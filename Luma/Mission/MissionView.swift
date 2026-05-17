import LumaCore
import SwiftUI

struct MissionView: View {
    let engine: Engine
    let missionID: UUID
    @Binding var selection: SidebarItemID?

    @State private var turns: [MissionTurn] = []
    @State private var actions: [MissionAction] = []
    @State private var findings: [MissionFinding] = []
    @State private var observations: [LumaCore.StoreObservation] = []
    @State private var liveText: String = ""
    @State private var compactPane: CompactPane = .transcript

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    enum CompactPane: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case actions = "Actions"
        case findings = "Findings"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let mission {
                MissionHeader(mission: mission, engine: engine, isCompactWidth: isCompactWidth)
                Divider()

                if isCompactWidth {
                    compactBody(mission: mission)
                } else {
                    PlatformHSplit {
                        MissionTranscriptView(turns: turns, actions: actions, liveText: liveText)
                            .frame(idealWidth: 480)

                        VStack(alignment: .leading, spacing: 0) {
                            ActionQueueView(engine: engine, missionID: mission.id, actions: pendingActions)
                                .frame(maxHeight: 360)
                            Divider()
                            FindingsListView(engine: engine, missionID: mission.id, findings: findings)
                        }
                        .frame(idealWidth: 280)
                    }
                }

                Divider()
                MissionInputBar(engine: engine, mission: mission)
            } else {
                ContentUnavailableView("Mission not found", systemImage: "scope")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: missionID) { startObservations() }
        .onChange(of: turns.count) { oldCount, newCount in
            if newCount > oldCount, !liveText.isEmpty {
                liveText = ""
            }
        }
    }

    @ViewBuilder
    private func compactBody(mission: Mission) -> some View {
        Picker("Pane", selection: $compactPane) {
            ForEach(CompactPane.allCases) { pane in
                Text(pane.rawValue).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        switch compactPane {
        case .transcript:
            MissionTranscriptView(turns: turns, actions: actions, liveText: liveText)
        case .actions:
            ActionQueueView(engine: engine, missionID: mission.id, actions: pendingActions)
        case .findings:
            FindingsListView(engine: engine, missionID: mission.id, findings: findings)
        }
    }

    private var mission: Mission? {
        engine.missions.first(where: { $0.id == missionID })
    }

    private var pendingActions: [MissionAction] {
        actions.filter { $0.status == .pending }
    }

    private func startObservations() {
        observations = []
        liveText = ""

        turns = (try? engine.store.fetchMissionTurns(missionID: missionID)) ?? []
        actions = (try? engine.store.fetchMissionActions(missionID: missionID)) ?? []
        findings = (try? engine.store.fetchMissionFindings(missionID: missionID)) ?? []

        observations.append(engine.store.observeMissionTurns(missionID: missionID) { rows in
            Task { @MainActor in turns = rows }
        })
        observations.append(engine.store.observeMissionActions(missionID: missionID) { rows in
            Task { @MainActor in actions = rows }
        })
        observations.append(engine.store.observeMissionFindings(missionID: missionID) { rows in
            Task { @MainActor in findings = rows }
        })

        engine.setMissionLiveDeltaSink { [missionID] eventMissionID, event in
            guard eventMissionID == missionID else { return }
            switch event {
            case .textDelta(let text):
                liveText.append(text)
            case .messageStop, .finalMessage:
                liveText = ""
            default:
                break
            }
        }
    }
}

private struct MissionHeader: View {
    let mission: Mission
    let engine: Engine
    var isCompactWidth: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let title = mission.title, !title.isEmpty {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(mission.goalText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(mission.goalText)
                        .font(.title3.weight(.semibold))
                }

                metadataRow
            }

            Spacer(minLength: 12)

            if mission.status.isLive {
                Button(role: .destructive) {
                    engine.cancelMission(missionID: mission.id)
                } label: {
                    if isCompactWidth {
                        Image(systemName: "stop.circle")
                    } else {
                        Label("Stop Mission", systemImage: "stop.circle")
                    }
                }
                .help("Cancel this mission. Pending tool calls won't be approved or run.")
            }
        }
        .padding()
    }

    @ViewBuilder
    private var metadataRow: some View {
        if isCompactWidth {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    metadataItems
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 1)
            }
        } else {
            HStack(spacing: 12) {
                metadataItems
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var metadataItems: some View {
        statusIndicator
        if !mission.editors.isEmpty {
            AuthorAvatarStack(authors: mission.editors, avatarSize: 18)
        }
        Label(mission.providerID, systemImage: "cpu")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        Label(mission.modelID, systemImage: "sparkles")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        Label("\(mission.tokensUsedInput)/\(mission.tokenBudgetInput) in", systemImage: "arrow.down.circle")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        Label("\(mission.tokensUsedOutput)/\(mission.tokenBudgetOutput) out", systemImage: "arrow.up.circle")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        if mission.cacheReadTokens > 0 {
            Label("\(mission.cacheReadTokens) cached", systemImage: "checkmark.seal")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if mission.status == .running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                MissionStatusBadge(status: mission.status)
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
            MissionStatusBadge(status: mission.status)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
