import SwiftUI
import LumaCore

struct InstrumentEventMenuItem: Identifiable {
    enum Role {
        case normal
        case destructive
    }

    let id = UUID()
    let title: String
    let systemImage: String?
    let role: Role
    let action: () -> Void
}
