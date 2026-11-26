import Foundation

public struct InstrumentAgentState: Sendable, Equatable {
    public var isLive: Bool
    public var disabledActions: [String: Set<String>]
    public var awaitsApproval: Bool
    public var allowedCode: String?

    public init(
        isLive: Bool = false, disabledActions: [String: Set<String>] = [:], awaitsApproval: Bool = false, allowedCode: String? = nil
    ) {
        self.isLive = isLive
        self.disabledActions = disabledActions
        self.awaitsApproval = awaitsApproval
        self.allowedCode = allowedCode
    }

    public func isEnabled(_ action: String, of widget: String) -> Bool {
        isLive && disabledActions[widget]?.contains(action) != true
    }

    func toWireJSON() -> [String: Any] {
        var obj: [String: Any] = ["live": isLive, "disabled_actions": disabledActions.mapValues { $0.sorted() }, "awaits_approval": awaitsApproval]
        obj["allowed_code"] = allowedCode
        return obj
    }

    static func fromWireJSON(_ obj: [String: Any]) -> InstrumentAgentState? {
        guard let isLive = obj["live"] as? Bool,
            let disabled = obj["disabled_actions"] as? [String: [String]],
            let awaitsApproval = obj["awaits_approval"] as? Bool
        else { return nil }
        return InstrumentAgentState(
            isLive: isLive, disabledActions: disabled.mapValues(Set.init), awaitsApproval: awaitsApproval,
            allowedCode: obj["allowed_code"] as? String)
    }
}

public enum InstrumentActionStateChange: Sendable {
    case reset(instanceID: UUID)
    case set(instanceID: UUID, widget: String, action: String, isEnabled: Bool)
}
