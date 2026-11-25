import Foundation

@MainActor
public protocol ToolCallHost: AnyObject {
    func record(_ call: ToolCallRequest) -> UUID
    func decision(on callID: UUID) async -> ToolCallDecision
    func finish(_ callID: UUID, with outcome: ToolCallOutcome)
}

public struct ToolCallRequest: @unchecked Sendable {
    public let spec: ActionSpec
    public let args: [String: Any]
    public let argsJSON: String
    public let toolCallID: String
    public let sessionID: UUID?
    public let mission: Mission
}

public enum ToolCallDecision: Sendable {
    case run
    case settled(ActionResult)
    case rejected(String?)
    case cancelled
}

public enum ToolCallOutcome: Sendable {
    case completed(ActionResult)
    case failed(String)
}

public enum ToolCallSettlement: Sendable {
    case completed(ActionResult)
    case failed(String)
    case rejected(String?)
    case cancelled
}

extension ToolCallHost {
    func perform(_ call: ToolCallRequest, in catalog: ToolCatalog) async -> ToolCallSettlement {
        let callID = record(call)
        switch await decision(on: callID) {
        case .run:
            let invocation = ActionInvocation(
                args: call.args, mission: call.mission, sessionID: call.sessionID, toolCallID: call.toolCallID, callID: callID)
            do {
                let result = try await catalog.execute(call.spec.name, invocation: invocation)
                finish(callID, with: .completed(result))
                return .completed(result)
            } catch {
                finish(callID, with: .failed(error.localizedDescription))
                return .failed(error.localizedDescription)
            }
        case .settled(let result):
            return .completed(result)
        case .rejected(let reason):
            return .rejected(reason)
        case .cancelled:
            return .cancelled
        }
    }
}
