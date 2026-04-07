import SwiftUI
import LumaCore

struct InstrumentAddressDecoration: Identifiable {
    let id = UUID()
    let help: String?
}

struct InstrumentAddressMenuItem: Identifiable {
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
