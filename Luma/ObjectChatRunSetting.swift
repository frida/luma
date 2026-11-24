import LumaCore
import Observation

@Observable
@MainActor
final class ObjectChatRunSetting {
    static let shared = ObjectChatRunSetting()

    var runsWithoutAsking = LumaAppState.shared.objectChatRunsWithoutAsking {
        didSet { LumaAppState.shared.objectChatRunsWithoutAsking = runsWithoutAsking }
    }
}
