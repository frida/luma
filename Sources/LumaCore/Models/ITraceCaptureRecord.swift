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

    private static let wireEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.dataEncodingStrategy = .base64
        return e
    }()

    private static let wireDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.dataDecodingStrategy = .base64
        return d
    }()

    public func toWireJSON() -> [String: Any]? {
        guard let data = try? Self.wireEncoder.encode(self),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> ITraceCaptureRecord? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
            let record = try? wireDecoder.decode(ITraceCaptureRecord.self, from: data)
        else { return nil }
        return record
    }
}
