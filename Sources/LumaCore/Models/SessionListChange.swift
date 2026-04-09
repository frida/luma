import Foundation

public enum SessionListChange: Sendable {
    case sessionAdded(ProcessSession)
    case sessionUpdated(ProcessSession)
    case sessionRemoved(UUID)
    case instrumentAdded(InstrumentInstance)
    case instrumentUpdated(InstrumentInstance)
    case instrumentRemoved(id: UUID, sessionID: UUID)
    case insightAdded(AddressInsight)
    case insightRemoved(id: UUID, sessionID: UUID)
    case captureAdded(ITraceCaptureRecord)
    case captureRemoved(id: UUID, sessionID: UUID)
}
