import Foundation
import GRDB

public struct MissionEvidence: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mission_evidence"

    public var id: UUID
    public var findingID: UUID
    public var kind: MissionEvidenceKind
    public var refJSON: String
    public var note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case findingID = "finding_id"
        case kind
        case refJSON = "ref_json"
        case note
    }

    public init(
        id: UUID = UUID(),
        findingID: UUID,
        kind: MissionEvidenceKind,
        refJSON: String,
        note: String? = nil
    ) {
        self.id = id
        self.findingID = findingID
        self.kind = kind
        self.refJSON = refJSON
        self.note = note
    }
}
