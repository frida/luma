import LumaCore
import SwiftUI

struct GlobalActionQueueToolbarItem: View {
    let engine: Engine

    @State private var pending: [MissionAction] = []
    @State private var observation: LumaCore.StoreObservation?
    @State private var isPresented = false
    @State private var openedChat: UUID?

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Action Queue", systemImage: waitingCount == 0 ? "tray" : "tray.full")
                .overlay(alignment: .topTrailing) { ToolbarCountBadge(count: waitingCount) }
        }
        .help(waitingCount == 0 ? "No actions awaiting approval" : "\(waitingCount) action\(waitingCount == 1 ? "" : "s") awaiting approval")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            GlobalActionQueuePopover(engine: engine, actions: pending, onOpenChat: openChat)
                .frame(width: 460, height: 480)
        }
        .sheet(isPresented: Binding(get: { openedChat != nil }, set: { if !$0 { openedChat = nil } })) {
            if let openedChat {
                PharoInspectorSheet(
                    engine: engine,
                    first: { try await engine.objectChats.column(of: openedChat) },
                    onDone: { self.openedChat = nil })
            }
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

    private var waitingCount: Int {
        pending.filter(engine.waitsForMe).count + engine.objectChats.callsWaitingForMe.count
    }

    private func openChat(_ chatID: UUID) {
        isPresented = false
        openedChat = chatID
    }

    private func applyPending(_ rows: [MissionAction]) {
        let hadForeground = pending.contains(where: isForegroundForMe)
        pending = rows
        let hasForeground = rows.contains(where: isForegroundForMe)
        if hasForeground, !hadForeground, !isPresented {
            isPresented = true
        } else if pending.isEmpty, engine.objectChats.callsWaitingForMe.isEmpty, isPresented {
            isPresented = false
        }
    }

    private func isForegroundForMe(_ action: MissionAction) -> Bool {
        !engine.isAmbientMission(action.missionID) && engine.waitsForMe(action)
    }
}

private struct GlobalActionQueuePopover: View {
    let engine: Engine
    let actions: [MissionAction]
    let onOpenChat: (UUID) -> Void

    var body: some View {
        ActionQueueView(engine: engine, actions: actions, onOpenChat: onOpenChat)
    }
}
