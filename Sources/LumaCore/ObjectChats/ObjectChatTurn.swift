import Foundation

@MainActor
final class ObjectChatTurn: ToolCallHost {
    let chatID: UUID
    let messageID = UUID()
    let question: ObjectChatMessage
    let mission: Mission

    private unowned let chats: ObjectChats
    private var nextIndex = 0
    private var refusals: [UUID: String] = [:]
    private var waiters: [UUID: CheckedContinuation<ToolCallDecision, Never>] = [:]

    init(chats: ObjectChats, question: ObjectChatMessage, mission: Mission) {
        self.chats = chats
        self.chatID = question.chatID
        self.question = question
        self.mission = mission
    }

    func record(_ call: ToolCallRequest) -> UUID {
        defer { nextIndex += 1 }
        switch chats.recordCall(call, in: self, at: nextIndex) {
        case .recorded(let callID):
            return callID
        case .refused(let reason):
            let callID = UUID()
            refusals[callID] = reason
            return callID
        }
    }

    func decision(on callID: UUID) async -> ToolCallDecision {
        if let reason = refusals.removeValue(forKey: callID) {
            return .settled(MissionTools.errorResult(reason, code: .rejected))
        }
        if let settled = chats.decision(on: chats.call(callID)!) {
            return settled
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    waiters[callID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.settle(callID, with: .cancelled) }
        }
    }

    func finish(_ callID: UUID, with outcome: ToolCallOutcome) {
        chats.finishCall(callID, with: outcome)
    }

    func isWaiting(on callID: UUID) -> Bool {
        waiters[callID] != nil
    }

    func settle(_ callID: UUID, with decision: ToolCallDecision) {
        waiters.removeValue(forKey: callID)?.resume(returning: decision)
    }
}
