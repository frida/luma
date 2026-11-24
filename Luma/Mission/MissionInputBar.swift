import LumaCore
import SwiftUI

struct MissionInputBar: View {
    let engine: Engine
    let mission: Mission

    @State private var draft: String = ""
    @State private var pendingSteering: [MissionSteer] = []
    @State private var myPendingSteeringIDs: Set<UUID> = []
    @State private var steeringObservation: LumaCore.StoreObservation?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let otherStarter {
                Text("The agent runs in \(otherStarter.name)’s Luma and reads what you send at its next step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !pendingSteering.isEmpty {
                pendingSteeringList
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .frame(minHeight: 36, maxHeight: 96)
                    .focused($isFocused)

                sendControl
                    .disabled(trimmedDraft.isEmpty)
            }
        }
        .padding(8)
        .background(.thinMaterial)
        .task(id: mission.id) { observeSteering() }
        .onDisappear { steeringObservation = nil }
    }

    private var otherStarter: Author? {
        engine.isStartedByMe(mission) ? nil : mission.author
    }

    private var pendingSteeringList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Not yet read by the agent", systemImage: "clock")
            ForEach(pendingSteering) { steer in
                Text("\(myPendingSteeringIDs.contains(steer.id) ? "You" : steer.author!.name): \(steer.text)")
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var sendControl: some View {
        if mission.status == .running, otherStarter == nil {
            Menu {
                Button("Send & Interrupt") { send(interrupt: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
            } label: {
                Text("Send")
            } primaryAction: {
                send(interrupt: false)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .menuStyle(.button)
        } else {
            Button("Send") { send(interrupt: false) }
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(interrupt: Bool) {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        if interrupt {
            engine.sendMissionUserMessageNow(missionID: mission.id, text: text)
        } else {
            engine.appendMissionUserMessage(missionID: mission.id, text: text)
        }
        draft = ""
        isFocused = true
    }

    private func observeSteering() {
        steeringObservation = engine.store.observeMissionSteering(missionID: mission.id) { rows in
            Task { @MainActor in showSteering(rows) }
        }
    }

    private func showSteering(_ rows: [MissionSteer]) {
        myPendingSteeringIDs = Set(engine.myPendingSteering(missionID: mission.id).map(\.id))
        pendingSteering = engine.isStartedByMe(mission) ? rows : rows.filter { myPendingSteeringIDs.contains($0.id) }
    }
}
