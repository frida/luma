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

    func makeAddressDecorations(
        context: InstrumentAddressContext,
        workspace: Workspace
    ) -> [InstrumentAddressDecoration]

    func makeAddressContextMenuItems(
        context: InstrumentAddressContext,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentAddressMenuItem]
}

extension InstrumentUI {
    func makeAddressDecorations(
        context: InstrumentAddressContext,
        workspace: Workspace
    ) -> [InstrumentAddressDecoration] {
        []
    }

    func makeAddressContextMenuItems(
        context: InstrumentAddressContext,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentAddressMenuItem] {
        []
    }

    func makeEventContextMenuItems(
        _ event: RuntimeEvent,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentEventMenuItem] {
        []
    }
}
