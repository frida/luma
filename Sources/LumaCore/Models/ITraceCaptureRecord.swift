import Foundation
import GRDB

public struct ITraceCaptureRecord: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "itrace_capture"

    public var id: UUID
    public var sessionID: UUID
    public var hookID: UUID
    public var callIndex: Int
    public var capturedAt: Date
    public var displayName: String
    public var traceData: Data
    public var metadataJSON: Data
    public var lost: Int

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case hookID = "hook_id"
        case callIndex = "call_index"
        case capturedAt = "captured_at"
        case displayName = "display_name"
        case traceData = "trace_data"
        case metadataJSON = "metadata_json"
        case lost
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        hookID: UUID,
        callIndex: Int,
        displayName: String,
        traceData: Data,
        metadataJSON: Data,
        lost: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.hookID = hookID
        self.callIndex = callIndex
        self.capturedAt = Date()
        self.displayName = displayName
        self.traceData = traceData
        self.metadataJSON = metadataJSON
        self.lost = lost
    }

    public init(from capture: CapturedITrace, sessionID: UUID) {
        self.init(
            sessionID: sessionID,
            hookID: capture.hookID,
            callIndex: capture.callIndex,
            displayName: capture.displayName,
            traceData: capture.traceData,
            metadataJSON: capture.metadataJSON,
            lost: capture.lost
        )
    }
}
