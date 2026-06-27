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
    @State private var pendingLiveText: String = ""
    @State private var liveFlushTask: Task<Void, Never>?
    @State private var compactPane: CompactPane = .transcript

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    enum CompactPane: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
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

                        FindingsListView(engine: engine, missionID: mission.id, findings: findings)
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
        .onDisappear { stopLiveObservation() }
        .onChange(of: turns.count) { oldCount, newCount in
            if newCount > oldCount, !liveText.isEmpty {
                pendingLiveText = ""
                liveFlushTask?.cancel()
                liveFlushTask = nil
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
        case .findings:
            FindingsListView(engine: engine, missionID: mission.id, findings: findings)
        }
    }

    private var mission: Mission? {
        engine.missions.first(where: { $0.id == missionID })
    }

    private func startObservations() {
        observations = []
        liveFlushTask?.cancel()
        liveFlushTask = nil
        liveText = engine.missionLiveText(missionID: missionID)
        pendingLiveText = liveText

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
                pendingLiveText.append(text)
                scheduleLiveFlush()
            case .messageStop, .finalMessage:
                pendingLiveText = ""
                liveFlushTask?.cancel()
                liveFlushTask = nil
                liveText = ""
            default:
                break
            }
        }
    }

    private func scheduleLiveFlush() {
        guard liveFlushTask == nil else { return }
        liveFlushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            liveText = pendingLiveText
            liveFlushTask = nil
        }
    }

    private func stopLiveObservation() {
        engine.setMissionLiveDeltaSink(nil)
        liveFlushTask?.cancel()
        liveFlushTask = nil
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
