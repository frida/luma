import Foundation
import GRDB

public struct MissionFinding: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mission_finding"

    public var id: UUID
    public var missionID: UUID
    public var createdAt: Date
    public var title: String
    public var bodyMarkdown: String
    public var confidence: MissionFindingConfidence
    public var kind: String
    public var status: MissionFindingStatus
    public var sessionID: UUID?
    public var anchorJSON: String?
    public var pinnedInsightID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case missionID = "mission_id"
        case createdAt = "created_at"
        case title
        case bodyMarkdown = "body_markdown"
        case confidence
        case kind
        case status
        case sessionID = "session_id"
        case anchorJSON = "anchor_json"
        case pinnedInsightID = "pinned_insight_id"
    }

    public init(
        id: UUID = UUID(),
        missionID: UUID,
        title: String,
        bodyMarkdown: String,
        confidence: MissionFindingConfidence,
        kind: String,
        sessionID: UUID? = nil,
        anchorJSON: String? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.createdAt = Date()
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.confidence = confidence
        self.kind = kind
        self.status = .proposed
        self.sessionID = sessionID
        self.anchorJSON = anchorJSON
        self.pinnedInsightID = nil
    }
}
