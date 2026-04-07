import SwiftUI
import LumaCore

protocol InstrumentUI {
    func makeConfigEditor(
        configJSON: Binding<Data>,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> AnyView

    func renderEvent(
        _ event: RuntimeEvent,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> AnyView

    func makeEventContextMenuItems(
        _ event: RuntimeEvent,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentEventMenuItem]
}

extension InstrumentUI {
    func makeEventContextMenuItems(
        _ event: RuntimeEvent,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentEventMenuItem] {
        []
    }
}
