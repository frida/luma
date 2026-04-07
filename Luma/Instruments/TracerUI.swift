import SwiftUI
import LumaCore

struct TracerUI: InstrumentUI {
    func makeConfigEditor(
        configJSON: Binding<Data>,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        let configBinding = Binding<TracerConfig>(
            get: {
                (try? TracerConfig.decode(from: configJSON.wrappedValue)) ?? TracerConfig()
            },
            set: { newValue in
                configJSON.wrappedValue = newValue.encode()
            }
        )

        return AnyView(
            TracerConfigView(
                config: configBinding,
                workspace: workspace,
                selection: selection
            )
        )
    }

    func renderEvent(
        _ event: RuntimeEvent,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> AnyView {
        guard case .jsValue(let v) = event.payload,
            let ev = Engine.parseTracerEvent(from: v),
            let processNode = workspace.processNode(for: event)
        else {
            return AnyView(
                Text(String(describing: event.payload))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            )
        }

        let messageView: AnyView = {
            if case .array(_, let elems) = ev.message,
                elems.count == 1,
                case .string(let messageText) = elems[0]
            {
                return AnyView(
                    Text(messageText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                )
            } else {
                return AnyView(
                    JSInspectValueView(
                        value: ev.message,
                        sessionID: event.sessionID ?? UUID(),
                        workspace: workspace,
                        selection: selection
                    )
                )
            }
        }()

        return AnyView(
            TracerEventRowView(
                messageView: messageView,
                process: processNode,
                backtrace: ev.backtrace,
                workspace: workspace,
                selection: selection
            )
        )
    }

    func makeEventContextMenuItems(
        _ event: RuntimeEvent,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentEventMenuItem] {
        guard case .instrument(let instrumentID, _) = event.source,
            case .jsValue(let v) = event.payload,
            let ev = Engine.parseTracerEvent(from: v),
            let sessionID = event.sessionID
        else {
            return []
        }

        return [
            InstrumentEventMenuItem(
                title: "Go to Hook",
                systemImage: "arrow.turn.down.right",
                role: .normal
            ) {
                selection.wrappedValue = .instrumentComponent(
                    sessionID,
                    instrumentID,
                    ev.id,
                    UUID()
                )
            },
        ]
    }

}
