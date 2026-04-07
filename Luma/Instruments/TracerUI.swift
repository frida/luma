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
            let ev = Engine.parseTracerEvent(from: v)
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
                        sessionID: event.processNode.sessionRecord.id,
                        workspace: workspace,
                        selection: selection
                    )
                )
            }
        }()

        return AnyView(
            TracerEventRowView(
                messageView: messageView,
                process: event.processNode,
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
            let ev = Engine.parseTracerEvent(from: v)
        else {
            return []
        }

        let processNode = event.processNode

        return [
            InstrumentEventMenuItem(
                title: "Go to Hook",
                systemImage: "arrow.turn.down.right",
                role: .normal
            ) {
                selection.wrappedValue = .instrumentComponent(
                    processNode.sessionRecord.id,
                    instrumentID,
                    ev.id,
                    UUID()
                )
            },
        ]
    }

    func makeAddressDecorations(
        context: InstrumentAddressContext,
        workspace: Workspace
    ) -> [InstrumentAddressDecoration] {
        workspace.addressAnnotationsBySession[context.sessionID]?[context.address]?.decorations ?? []
    }

    func makeAddressContextMenuItems(
        context: InstrumentAddressContext,
        workspace: Workspace,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentAddressMenuItem] {
        let tracerID = workspace.tracerInstanceIDBySession[context.sessionID]
        let hookID = workspace.addressAnnotationsBySession[context.sessionID]?[context.address]?.tracerHookID

        if let tracerID, let hookID {
            return [
                InstrumentAddressMenuItem(
                    title: "Go to Hook",
                    systemImage: "arrow.turn.down.right",
                    role: .normal,
                    action: {
                        selection.wrappedValue = .instrumentComponent(context.sessionID, tracerID, hookID, UUID())
                    }
                ),
            ]
        } else {
            return [
                InstrumentAddressMenuItem(
                    title: "Add Instruction Hook\u{2026}",
                    systemImage: "pin",
                    role: .normal,
                    action: {
                        Task { @MainActor in
                            await workspace.addTracerInstructionHook(
                                sessionID: context.sessionID,
                                address: context.address,
                                selection: selection
                            )
                        }
                    }
                ),
            ]
        }
    }
}
