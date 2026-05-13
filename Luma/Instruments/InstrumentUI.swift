import SwiftUI
import LumaCore

protocol InstrumentUI {
    func makeConfigEditor(
        configJSON: Binding<Data>,
        engine: Engine,
        selection: Binding<SidebarItemID?>
    ) -> AnyView

    func renderEvent(
        _ event: RuntimeEvent,
        engine: Engine,
        selection: Binding<SidebarItemID?>
    ) -> AnyView

    func makeEventContextMenuItems(
        _ event: RuntimeEvent,
        engine: Engine,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentEventMenuItem]

    func sidebarChildren(
        sessionID: UUID,
        instance: LumaCore.InstrumentInstance,
        engine: Engine,
        selection: Binding<SidebarItemID?>
    ) -> AnyView
}

extension InstrumentUI {
    func makeEventContextMenuItems(
        _ event: RuntimeEvent,
        engine: Engine,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentEventMenuItem] {
        []
    }

    func sidebarChildren(
        sessionID: UUID,
        instance: LumaCore.InstrumentInstance,
        engine: Engine,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        AnyView(EmptyView())
    }
}
