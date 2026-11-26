import Foundation

extension CollaborationSession {
    static let outcomeTimeout = Duration.seconds(30)

    func sendOutcome(sessionID: UUID, actionID: UUID, offersFile: Bool, error: String?) {
        guard case .joined(let labID) = status else { return }
        var payload: [String: Any] = ["file": offersFile]
        payload["error"] = error
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/widget-actions/\(actionID.uuidString)/outcome", type: "+outcome",
            payload: payload)
    }

    func awaitOutcome(of actionID: UUID) {
        outcomeDeadlines[actionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.outcomeTimeout)
            guard !Task.isCancelled else { return }
            self?.receiveOutcome(of: actionID, error: "the host's agent did not answer")
        }
    }

    func receiveOutcome(of actionID: UUID, error: String?) {
        outcomeDeadlines.removeValue(forKey: actionID)?.cancel()
        guard let error else { return }
        fail(actionID, error)
    }

    func failAwaitedOutcomes(_ reason: String) {
        let awaited = outcomeDeadlines
        outcomeDeadlines = [:]
        for (actionID, deadline) in awaited {
            deadline.cancel()
            fail(actionID, reason)
        }
    }

    private func fail(_ actionID: UUID, _ reason: String) {
        guard let index = sentWidgetActions.firstIndex(where: { $0.id == actionID }), !sentWidgetActions[index].action.failed else { return }
        sentWidgetActions[index].action.failed = true
        onWidgetActionFailed?(WidgetActionFailure(action: sentWidgetActions[index].action, reason: reason))
    }
}

struct WidgetActionFailure {
    let action: SentWidgetAction
    let reason: String
}
