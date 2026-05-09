import LumaCore
import SwiftUI

struct MissionsListView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var isShowingNewSheet = false

    var missions: [Mission] { workspace.engine.missions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Missions")
                    .font(.title2.bold())
                Spacer()
                Button {
                    isShowingNewSheet = true
                } label: {
                    Label("New Mission", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.top)

            if missions.isEmpty {
                ContentUnavailableView(
                    "No missions yet",
                    systemImage: "scope",
                    description: Text("Click \"New Mission\" to give the agent a goal to work on.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(missions) { mission in
                        Button {
                            selection = .mission(mission.id)
                        } label: {
                            MissionListRow(mission: mission)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .sheet(isPresented: $isShowingNewSheet) {
            NewMissionSheet(workspace: workspace, isPresented: $isShowingNewSheet) { mission in
                selection = .mission(mission.id)
            }
        }
    }
}

private struct MissionListRow: View {
    let mission: Mission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(mission.goalText)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer()
                MissionStatusBadge(status: mission.status)
            }
            HStack(spacing: 12) {
                Label(mission.providerID, systemImage: "cpu")
                Label(mission.modelID, systemImage: "sparkles")
                Spacer()
                Text(mission.createdAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct MissionStatusBadge: View {
    let status: MissionStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .drafting: "Drafting"
        case .running: "Running"
        case .awaitingApproval: "Awaiting"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var color: Color {
        switch status {
        case .drafting: .gray
        case .running: .blue
        case .awaitingApproval: .orange
        case .paused: .yellow
        case .completed: .green
        case .failed: .red
        case .cancelled: .gray
        }
    }
}
