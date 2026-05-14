import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class TracerUIKind: InstrumentUIKind {
    private let sharedMonaco: MonacoEditor

    init(sharedMonaco: MonacoEditor) {
        self.sharedMonaco = sharedMonaco
    }

    func makeDetailUI(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> InstrumentDetailUI {
        TracerDetailUI(
            engine: engine,
            instrument: instrument,
            sharedMonaco: sharedMonaco,
            host: host
        )
    }

    func makeSidebarChildren(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> [InstrumentSidebarChild] {
        guard let config = try? TracerConfig.decode(from: instrument.configJSON) else { return [] }
        let ordered = config.hooksByMostRecentlyEdited()
        guard !ordered.isEmpty else { return [] }

        let sessionID = instrument.sessionID
        let instrumentID = instrument.id

        let inline = inlineHooks(
            from: ordered,
            selectedID: host.selectedComponentID(sessionID: sessionID, instrumentID: instrumentID)
        )

        var children: [InstrumentSidebarChild] = []
        for hook in inline {
            let (row, anchor) = TracerSidebar.makeHookRow(hook: hook)
            let hookID = hook.id
            attachHookContextMenu(
                row: row,
                anchor: anchor,
                hook: hook,
                engine: engine,
                sessionID: sessionID,
                instrumentID: instrumentID,
                host: host
            )
            children.append(
                InstrumentSidebarChild(
                    key: "hook:\(hookID.uuidString)",
                    componentID: hookID,
                    row: row,
                    onActivate: { [weak host] in
                        host?.navigateToInstrumentComponent(
                            sessionID: sessionID,
                            instrumentID: instrumentID,
                            componentID: hookID
                        )
                    }
                )
            )
        }
        if ordered.count > inline.count {
            let (row, anchor) = TracerSidebar.makeBrowseAllRow(totalCount: ordered.count)
            let hooks = ordered
            children.append(
                InstrumentSidebarChild(
                    key: "browse",
                    componentID: nil,
                    row: row,
                    onActivate: { [anchor, weak host] in
                        guard let host else { return }
                        TracerSidebar.presentBrowser(
                            hooks: hooks,
                            anchor: anchor,
                            onChoose: { hook in
                                host.navigateToInstrumentComponent(
                                    sessionID: sessionID,
                                    instrumentID: instrumentID,
                                    componentID: hook.id
                                )
                            }
                        )
                    }
                )
            )
        }
        return children
    }

    private func attachHookContextMenu(
        row: ListBoxRow,
        anchor: Widget,
        hook: TracerConfig.Hook,
        engine: Engine,
        sessionID: UUID,
        instrumentID: UUID,
        host: InstrumentUIHost
    ) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak engine, weak host, anchor] _, _, x, y in
            MainActor.assumeIsolated {
                guard let engine, let host else { return }
                TracerHookContextMenu.present(
                    at: anchor,
                    x: x,
                    y: y,
                    hook: hook,
                    engine: engine,
                    sessionID: sessionID,
                    instrumentID: instrumentID,
                    host: host
                )
            }
        }
        row.install(controller: click)
    }

    private func inlineHooks(
        from ordered: [TracerConfig.Hook],
        selectedID: UUID?
    ) -> [TracerConfig.Hook] {
        var inline = Array(ordered.prefix(TracerSidebar.inlineLimit))
        if let selectedID,
            !inline.contains(where: { $0.id == selectedID }),
            let selected = ordered.first(where: { $0.id == selectedID })
        {
            if inline.count >= TracerSidebar.inlineLimit {
                inline.removeLast()
            }
            inline.append(selected)
        }
        return inline.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

@MainActor
private final class TracerDetailUI: InstrumentDetailUI {
    let widget: Widget

    private weak var engine: Engine?
    private var instrument: LumaCore.InstrumentInstance
    private let editor: TracerConfigEditor

    init(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        sharedMonaco: MonacoEditor,
        host: InstrumentUIHost
    ) {
        self.engine = engine
        self.instrument = instrument
        let config = (try? TracerConfig.decode(from: instrument.configJSON)) ?? TracerConfig()
        var box: TracerDetailUI?
        let editor = TracerConfigEditor(
            engine: engine,
            sessionID: instrument.sessionID,
            config: config,
            tracerEditor: sharedMonaco,
            apply: { data in
                box?.applyConfig(data)
            }
        )
        self.editor = editor
        widget = editor.widget
        let sessionID = instrument.sessionID
        let instrumentID = instrument.id
        editor.onRevertNavigation = { [weak host] hookID in
            host?.navigateToInstrumentComponent(
                sessionID: sessionID,
                instrumentID: instrumentID,
                componentID: hookID
            )
        }
        box = self
    }

    func update(_ instrument: LumaCore.InstrumentInstance) {
        guard instrument.configJSON != self.instrument.configJSON else { return }
        self.instrument = instrument
        guard let config = try? TracerConfig.decode(from: instrument.configJSON) else { return }
        editor.update(config: config)
    }

    func selectComponent(id: UUID) {
        editor.selectHook(id: id)
    }

    func showConfigurationView() {
        editor.showConfigurationView()
    }

    func setOnComponentAdded(_ handler: ((UUID) -> Void)?) {
        editor.setOnHookAdded(handler)
    }

    func applySessionState() {
        editor.applySessionState()
    }

    private func applyConfig(_ data: Data) {
        instrument.configJSON = data
        guard let engine else { return }
        let snapshot = instrument
        Task { @MainActor in
            await engine.applyInstrumentConfig(snapshot, configJSON: data)
        }
    }
}
