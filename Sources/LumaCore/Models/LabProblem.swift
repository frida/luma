import Foundation

public struct LabProblem: Identifiable, Sendable, Equatable {
    public enum Concern: Sendable, Equatable {
        case objectChat(ObjectChatProblem)
        case missionDeletedInLab(missionID: UUID, title: String)
        case missionStoppedByOwner(missionID: UUID, title: String)
        case copyKeptFromLab(LabSubject, name: String)
        case keptFromLab(LabSubject, name: String)
    }

    public let id: UUID
    public let concern: Concern
    public let reason: String
    public let date: Date

    public init(_ concern: Concern, reason: String) {
        self.id = UUID()
        self.concern = concern
        self.reason = reason
        self.date = Date()
    }

    init(_ problem: ObjectChatProblem) {
        self.id = problem.id
        self.concern = .objectChat(problem)
        self.reason = problem.reason
        self.date = problem.date
    }
}
