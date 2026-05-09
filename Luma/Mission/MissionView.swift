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
                        .frame(minWidth: 320)

                    VStack(alignment: .leading, spacing: 0) {
                        ActionQueueView(workspace: workspace, missionID: mission.id, actions: pendingActions)
                            .frame(maxHeight: 360)
                        Divider()
                        FindingsListView(workspace: workspace, missionID: mission.id, findings: findings)
                    }
                    .frame(minWidth: 240)
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

        turns = (try? workspace.store.fetchMissionTurns(missionID: m.id)) ?? []
        actions = (try? workspace.store.fetchMissionActions(missionID: m.id)) ?? []
        findings = (try? workspace.store.fetchMissionFindings(missionID: m.id)) ?? []

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
            VStack(alignment: .leading, spacing: 6) {
                Text(mission.goalText)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        statusIndicator
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
            .frame(maxWidth: .infinity, alignment: .leading)

            if mission.status.isLive {
                Button(role: .destructive) {
                    workspace.engine.cancelMission(missionID: mission.id)
                } label: {
                    Label("Stop Mission", systemImage: "stop.circle")
                }
                .help("Cancel this mission. Pending tool calls won't be approved or run.")
                .fixedSize()
            }
        }
        .padding()
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if mission.status == .running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                MissionStatusBadge(status: mission.status)
            }
        } else {
            MissionStatusBadge(status: mission.status)
        }
    }
}
