import Foundation

extension Engine {
    func toolCallHost(forMission missionID: UUID) -> (any ToolCallHost)? {
        objectChats.turn(of: missionID)
    }
}
