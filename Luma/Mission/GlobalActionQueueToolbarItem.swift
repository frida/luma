import LumaCore
import SwiftUI

struct GlobalActionQueueToolbarItem: View {
    let engine: Engine

    @State private var pending: [MissionAction] = []
    @State private var observation: LumaCore.StoreObservation?
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Action Queue", systemImage: pending.isEmpty ? "tray" : "tray.full")
                .overlay(alignment: .topTrailing) {
                    if !pending.isEmpty {
                        Text("\(pending.count)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .help(pending.isEmpty ? "No actions awaiting approval" : "\(pending.count) action\(pending.count == 1 ? "" : "s") awaiting approval")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            GlobalActionQueuePopover(engine: engine, actions: pending)
                .frame(width: 460, height: 480)
        }
        .onAppear {
            pending = (try? engine.store.fetchAllPendingMissionActions()) ?? []
            observation = engine.store.observeAllPendingMissionActions { rows in
                Task { @MainActor in applyPending(rows) }
            }
        }
        .onDisappear {
            observation = nil
        }
    }

    private func applyPending(_ rows: [MissionAction]) {
        let hadForeground = pending.contains { !engine.isAmbientMission($0.missionID) }
        pending = rows
        let hasForeground = rows.contains { !engine.isAmbientMission($0.missionID) }
        if hasForeground, !hadForeground, !isPresented {
            isPresented = true
        } else if rows.isEmpty, isPresented {
            isPresented = false
        }
    }
}

private struct GlobalActionQueuePopover: View {
    let engine: Engine
    let actions: [MissionAction]

    var body: some View {
        ActionQueueView(engine: engine, actions: actions)
    }
}
