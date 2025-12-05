import Foundation

enum TargetPickerContext: Equatable {
    case newSession
    case reestablish(session: ProcessSession, reason: String)
}

extension TargetPickerContext: Identifiable {
    var id: String {
        switch self {
        case .newSession:
            return "newSession"
        case .reestablish(let session, let reason):
            return "reestablish-\(session.id.uuidString)-\(reason)"
        }
    }
}
