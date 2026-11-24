#if os(macOS)
    import Foundation
    import LumaCore

    extension Engine {
        func attachLocalNotifier() {
            let key = ObjectIdentifier(self)
            if enginesWithLocalNotifier[key] != nil { return }
            let notifier = LocalNotifier()
            enginesWithLocalNotifier[key] = notifier

            onNotebookChanged = { [weak self] change in
                guard case let .added(entry) = change else { return }
                guard let self,
                    let authorID = entry.author?.id,
                    !self.collaboration.isSelf(authorID)
                else { return }
                notifier.notifyEntryAdded(entry, labID: self.collaboration.labID)
            }
            collaboration.onMemberAdded = { [weak self] member in
                guard let self,
                    !self.collaboration.isSelf(member.user.id)
                else { return }
                notifier.notifyMemberAdded(member, labID: self.collaboration.labID)
            }
            objectChats.onMessageArrived = { [weak self] chat, message in
                guard let self, chat.id == self.objectChats.conversationID else { return }
                notifier.notifyChatMessage(message, in: self.objectChats.displayTitle(of: chat), labID: self.collaboration.labID)
            }

            let seenPending = PendingActionTracker(
                initial: Set(((try? store.fetchAllPendingMissionActions()) ?? []).map(\.id))
            )
            let observation = store.observeAllPendingMissionActions { [weak self] rows in
                Task { @MainActor in
                    guard let self else { return }
                    let currentIDs = Set(rows.map(\.id))
                    let arrivals = rows.filter { !seenPending.ids.contains($0.id) && self.waitsForMe($0) }
                    seenPending.ids = currentIDs
                    guard let newest = arrivals.max(by: { $0.requestedAt < $1.requestedAt }) else { return }
                    notifier.notifyActionAwaitingApproval(newest, additionalPending: arrivals.count - 1)
                }
            }
            pendingActionObservations[key] = observation
        }
    }

    @MainActor
    private final class PendingActionTracker {
        var ids: Set<UUID>
        init(initial: Set<UUID>) { ids = initial }
    }

    @MainActor
    private var enginesWithLocalNotifier: [ObjectIdentifier: LocalNotifier] = [:]

    @MainActor
    private var pendingActionObservations: [ObjectIdentifier: LumaCore.StoreObservation] = [:]
#endif
