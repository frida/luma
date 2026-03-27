import Foundation
import SwiftData

@Model
final class ITraceCapture {
    var id = UUID()

    var hookID: UUID
    var callIndex: Int
    var capturedAt: Date
    var displayName: String

    @Attribute(.externalStorage)
    var traceData: Data

    @Attribute(.externalStorage)
    var metadataJSON: Data

    var lost: Int

    var session: ProcessSession?

    init(
        hookID: UUID,
        callIndex: Int,
        displayName: String,
        traceData: Data,
        metadataJSON: Data,
        lost: Int = 0
    ) {
        self.hookID = hookID
        self.callIndex = callIndex
        self.capturedAt = Date()
        self.displayName = displayName
        self.traceData = traceData
        self.metadataJSON = metadataJSON
        self.lost = lost
    }
}
