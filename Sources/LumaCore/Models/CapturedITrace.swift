import Foundation

public struct CapturedITrace: Sendable {
    public let hookID: UUID
    public let callIndex: Int
    public let displayName: String
    public let traceData: Data
    public let metadataJSON: Data
    public let lost: Int

    public init(
        hookID: UUID,
        callIndex: Int,
        displayName: String,
        traceData: Data,
        metadataJSON: Data,
        lost: Int
    ) {
        self.hookID = hookID
        self.callIndex = callIndex
        self.displayName = displayName
        self.traceData = traceData
        self.metadataJSON = metadataJSON
        self.lost = lost
    }
}
