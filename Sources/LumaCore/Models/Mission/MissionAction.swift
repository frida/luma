import Foundation
import GRDB

public struct MissionAction: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mission_action"

    public var id: UUID
    public var missionID: UUID
    public var turnID: UUID?
    public var toolName: String
    public var argsJSON: String
    public var status: MissionActionStatus
    public var isObserve: Bool
    public var sessionID: UUID?
    public var requestedAt: Date
    public var decidedAt: Date?
    public var completedAt: Date?
    public var resultJSON: String?
    public var resultSummary: String?
    public var error: String?
    public var rationale: String?
    public var rejectionReason: String?
    public var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case missionID = "mission_id"
        case turnID = "turn_id"
        case toolName = "tool_name"
        case argsJSON = "args_json"
        case status
        case isObserve = "is_observe"
        case sessionID = "session_id"
        case requestedAt = "requested_at"
        case decidedAt = "decided_at"
        case completedAt = "completed_at"
        case resultJSON = "result_json"
        case resultSummary = "result_summary"
        case error
        case rationale
        case rejectionReason = "rejection_reason"
        case toolCallID = "tool_call_id"
    }

    public init(
        id: UUID = UUID(),
        missionID: UUID,
        turnID: UUID?,
        toolName: String,
        argsJSON: String,
        isObserve: Bool,
        sessionID: UUID?,
        rationale: String? = nil,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.turnID = turnID
        self.toolName = toolName
        self.argsJSON = argsJSON
        self.status = isObserve ? .approved : .pending
        self.isObserve = isObserve
        self.sessionID = sessionID
        self.requestedAt = Date()
        self.decidedAt = isObserve ? Date() : nil
        self.completedAt = nil
        self.resultJSON = nil
        self.resultSummary = nil
        self.error = nil
        self.rationale = rationale
        self.rejectionReason = nil
        self.toolCallID = toolCallID
    }
}
