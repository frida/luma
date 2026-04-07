import Foundation
import LumaCore

enum TargetPickerContext: Equatable, Identifiable {
    case newSession
    case reestablish(session: LumaCore.ProcessSession, reason: String)

    var id: String {
        switch self {
        case .newSession:
            return "newSession"
        case .reestablish(let session, let reason):
            return "reestablish-\(session.id.uuidString)-\(reason)"
        }
    }

    static func == (lhs: TargetPickerContext, rhs: TargetPickerContext) -> Bool {
        lhs.id == rhs.id
    }
}
