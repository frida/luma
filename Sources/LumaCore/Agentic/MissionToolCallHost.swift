import Foundation

@MainActor
final class MissionToolCallHost: ToolCallHost {
    var trustsClientApprovals = false

    private weak var engine: Engine?
    private var actions: [UUID: MissionAction] = [:]
    private var pendingApprovals: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var endReason: String?

    init(engine: Engine) {
        self.engine = engine
    }

    func record(_ call: ToolCallRequest) -> UUID {
        var action = MissionAction(
            missionID: call.mission.id,
            turnID: nil,
            toolName: call.spec.name,
            argsJSON: call.argsJSON,
            isObserve: call.spec.isObserve,
            sessionID: call.sessionID,
            toolCallID: call.toolCallID
        )
        engine!.assignExecutor(to: &action, askedBy: call.mission.author)
        actions[action.id] = action
        if awaitsApproval(action) {
            persist(action)
        }
        return action.id
    }

    func decision(on callID: UUID) async -> ToolCallDecision {
        var action = actions[callID]!
        if let endReason {
            actions[callID] = nil
            return .settled(MissionTools.errorResult(endReason, code: .rejected))
        }
        if awaitsApproval(action) {
            let decision = await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
                pendingApprovals[callID] = continuation
            }
            switch decision {
            case .rejected(let reason):
                action.status = .rejected
                action.rejectionReason = reason
                action.decidedAt = Date()
                action.completedAt = Date()
                persist(action)
                actions[callID] = nil
                return .rejected(reason)
            case .cancelled:
                action.status = .failed
                action.error = "mission canceled while awaiting approval"
                action.completedAt = Date()
                persist(action)
                actions[callID] = nil
                return .cancelled
            case .ended(let reason):
                actions[callID] = nil
                return .settled(MissionTools.errorResult(reason, code: .rejected))
            case .settled(let elsewhere):
                actions[callID] = nil
                guard elsewhere.status != .rejected else { return .rejected(elsewhere.rejectionReason) }
                return .settled(
                    ActionResult(
                        summary: elsewhere.resultSummary ?? elsewhere.error ?? "",
                        resultJSON: elsewhere.resultJSON ?? MissionTools.errorResult(elsewhere.error ?? "failed").resultJSON,
                        isError: elsewhere.status != .succeeded))
            case .approved:
                break
            }
        }
        action.status = .running
        action.decidedAt = Date()
        persist(action)
        actions[callID] = action
        return .run
    }

    func finish(_ callID: UUID, with outcome: ToolCallOutcome) {
        var action = actions.removeValue(forKey: callID)!
        switch outcome {
        case .completed(let result):
            action.status = result.isError ? .failed : .succeeded
            action.resultJSON = result.resultJSON
            action.resultSummary = result.summary
            if result.isError { action.error = result.summary }
        case .failed(let message):
            action.status = .failed
            action.error = message
        }
        action.completedAt = Date()
        persist(action)
    }

    func approve(actionID: UUID) {
        pendingApprovals.removeValue(forKey: actionID)?.resume(returning: .approved)
    }

    func reject(actionID: UUID, reason: String?) {
        pendingApprovals.removeValue(forKey: actionID)?.resume(returning: .rejected(reason))
    }

    func settle(_ action: MissionAction) {
        pendingApprovals.removeValue(forKey: action.id)?.resume(returning: .settled(action))
    }

    var isWaitingForApproval: Bool {
        !pendingApprovals.isEmpty
    }

    func end(because reason: String) {
        endReason = reason
        for (_, continuation) in pendingApprovals {
            continuation.resume(returning: .ended(reason))
        }
        pendingApprovals.removeAll()
    }

    func cancelAll() {
        for (_, continuation) in pendingApprovals {
            continuation.resume(returning: .cancelled)
        }
        pendingApprovals.removeAll()
    }

    private func awaitsApproval(_ action: MissionAction) -> Bool {
        action.status == .pending && !(trustsClientApprovals && engine!.isExecutor(of: action))
    }

    private func persist(_ action: MissionAction) {
        try? engine?.store.save(action)
        engine?.collaboration.enqueueMissionAction(action)
    }

    private enum ApprovalDecision {
        case approved
        case rejected(String?)
        case settled(MissionAction)
        case ended(String)
        case cancelled
    }
}
