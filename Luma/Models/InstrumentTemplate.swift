import SwiftUI

struct InstrumentTemplate: Identifiable, Hashable {
    let id: String
    let kind: InstrumentKind
    let sourceIdentifier: String

    let displayName: String
    let icon: InstrumentIcon

    let makeInitialConfigJSON: () throws -> Data

    let makeConfigEditor:
        (
            _ configJSON: Binding<Data>,
            _ selection: Binding<SidebarItemID?>
        ) -> AnyView

    let renderEvent:
        (
            _ event: RuntimeEvent,
            _ workspace: Workspace,
            _ selection: Binding<SidebarItemID?>
        ) -> AnyView

    let makeEventContextMenuItems:
        (
            _ event: RuntimeEvent,
            _ workspace: Workspace,
            _ selection: Binding<SidebarItemID?>
        ) -> [InstrumentEventMenuItem]

    let summarizeEvent: (_ event: RuntimeEvent) -> String

    static func == (lhs: InstrumentTemplate, rhs: InstrumentTemplate) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
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
