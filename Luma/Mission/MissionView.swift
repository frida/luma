import LumaCore
import SwiftUI

struct MissionView: View {
    @ObservedObject var workspace: Workspace
    let missionID: UUID
    @Binding var selection: SidebarItemID?

    @State private var mission: Mission?
    @State private var turns: [MissionTurn] = []
    @State private var actions: [MissionAction] = []
    @State private var findings: [MissionFinding] = []
    @State private var observations: [LumaCore.StoreObservation] = []
    @State private var liveText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if let mission {
                MissionHeader(mission: mission, workspace: workspace)
                Divider()

                PlatformHSplit {
                    MissionTranscriptView(turns: turns, actions: actions, liveText: liveText)
                        .frame(minWidth: 480)

                    VStack(alignment: .leading, spacing: 0) {
                        ActionQueueView(workspace: workspace, missionID: mission.id, actions: pendingActions)
                            .frame(maxHeight: 360)
                        Divider()
                        FindingsListView(workspace: workspace, missionID: mission.id, findings: findings)
                    }
                    .frame(minWidth: 320)
                }

                Divider()
                MissionInputBar(workspace: workspace, mission: mission)
            } else {
                ContentUnavailableView("Mission not found", systemImage: "scope")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: missionID) { startObservations() }
    }

    private var pendingActions: [MissionAction] {
        actions.filter { $0.status == .pending }
    }

    private func startObservations() {
        observations = []
        liveText = ""
        mission = try? workspace.store.fetchMission(id: missionID)
        guard let m = mission else { return }

        observations.append(workspace.store.observeMissionTurns(missionID: m.id) { rows in
            Task { @MainActor in turns = rows }
        })
        observations.append(workspace.store.observeMissionActions(missionID: m.id) { rows in
            Task { @MainActor in actions = rows }
        })
        observations.append(workspace.store.observeMissionFindings(missionID: m.id) { rows in
            Task { @MainActor in findings = rows }
        })

        workspace.engine.setMissionLiveDeltaSink { [missionID = m.id] eventMissionID, event in
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
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mission.goalText)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        MissionStatusBadge(status: mission.status)
                        Label(mission.providerID, systemImage: "cpu")
                        Label(mission.modelID, systemImage: "sparkles")
                        Label("\(mission.tokensUsedInput)/\(mission.tokenBudgetInput) in", systemImage: "arrow.down.circle")
                        Label("\(mission.tokensUsedOutput)/\(mission.tokenBudgetOutput) out", systemImage: "arrow.up.circle")
                        if mission.cacheReadTokens > 0 {
                            Label("\(mission.cacheReadTokens) cached", systemImage: "checkmark.seal")
                        }
                    }
                    .fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if mission.status.isLive {
                Button(role: .destructive) {
                    workspace.engine.cancelMission(missionID: mission.id)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .layoutPriority(1)
            }
        }
        .padding()
    }
}
