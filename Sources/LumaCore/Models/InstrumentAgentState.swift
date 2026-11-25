import Foundation

public struct InstrumentAgentState: Sendable, Equatable {
    public var isLive: Bool
    public var disabledActions: [String: Set<String>]
    public var awaitsApproval: Bool

    public init(isLive: Bool = false, disabledActions: [String: Set<String>] = [:], awaitsApproval: Bool = false) {
        self.isLive = isLive
        self.disabledActions = disabledActions
        self.awaitsApproval = awaitsApproval
    }

    public func isEnabled(_ action: String, of widget: String) -> Bool {
        isLive && disabledActions[widget]?.contains(action) != true
    }

    func toWireJSON() -> [String: Any] {
        ["live": isLive, "disabled_actions": disabledActions.mapValues { $0.sorted() }, "awaits_approval": awaitsApproval]
    }

    static func fromWireJSON(_ obj: [String: Any]) -> InstrumentAgentState? {
        guard let isLive = obj["live"] as? Bool else { return nil }
        let disabled = (obj["disabled_actions"] as? [String: [String]]) ?? [:]
        return InstrumentAgentState(isLive: isLive, disabledActions: disabled.mapValues(Set.init), awaitsApproval: obj["awaits_approval"] as? Bool ?? false)
    }
}

public enum InstrumentActionStateChange: Sendable {
    case reset(instanceID: UUID)
    case set(instanceID: UUID, widget: String, action: String, isEnabled: Bool)
}
