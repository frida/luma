import SwiftUI
import LumaCore

struct CustomInstrumentUI: InstrumentUI {
    let defID: UUID

    func makeConfigEditor(
        configJSON: Binding<Data>,
        engine: Engine,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        let id = defID
        let cfgBinding = Binding<CustomInstrumentConfig>(
            get: {
                (try? CustomInstrumentConfig.decode(from: configJSON.wrappedValue))
                    ?? CustomInstrumentConfig(defID: id)
            },
            set: { newValue in
                configJSON.wrappedValue = newValue.encode()
            }
        )
        return AnyView(
            CustomInstrumentConfigView(
                defID: id,
                config: cfgBinding,
                engine: engine,
                selection: selection
            )
        )
    }

    func renderEvent(
        _ event: RuntimeEvent,
        engine: Engine,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        if case .jsValue(let v) = event.payload {
            return AnyView(
                JSInspectValueView(
                    value: v,
                    sessionID: event.sessionID ?? UUID(),
                    engine: engine,
                    selection: selection
                )
                .font(.system(.footnote, design: .monospaced))
            )
        }
        return AnyView(Text(String(describing: event.payload)))
    }

    func sidebarChildren(
        sessionID: UUID,
        instance: LumaCore.InstrumentInstance,
        engine: Engine,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        AnyView(CustomInstrumentChildRows(sessionID: sessionID, instance: instance, engine: engine, selection: selection))
    }

    func hasSidebarChildren(instance: LumaCore.InstrumentInstance, engine: Engine) -> Bool {
        !engine.shownChildren(of: instance.id).isEmpty
    }
}
