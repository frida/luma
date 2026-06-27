import Foundation
import Gtk
import LumaCore

@MainActor
protocol InstrumentDetailUI: AnyObject {
    var widget: Widget { get }
    func update(_ instrument: LumaCore.InstrumentInstance)
    func selectComponent(id: UUID)
    func showConfigurationView()
    func setOnComponentAdded(_ handler: ((UUID) -> Void)?)
    func applySessionState()
}

extension InstrumentDetailUI {
    func selectComponent(id: UUID) {}
    func showConfigurationView() {}
    func setOnComponentAdded(_ handler: ((UUID) -> Void)?) {}
    func applySessionState() {}
}

@MainActor
protocol InstrumentUIKind: AnyObject {
    func makeDetailUI(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> InstrumentDetailUI

    func makeSidebarChildren(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> [InstrumentSidebarChild]

    func hasSidebarChildren(instrument: LumaCore.InstrumentInstance) -> Bool
}

extension InstrumentUIKind {
    func makeSidebarChildren(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> [InstrumentSidebarChild] {
        []
    }

    func hasSidebarChildren(instrument: LumaCore.InstrumentInstance) -> Bool {
        false
    }
}

struct InstrumentSidebarChild {
    let key: String
    let componentID: UUID?
    let row: ListBoxRow
    let onActivate: @MainActor () -> Void
}

@MainActor
protocol InstrumentUIHost: AnyObject {
    func navigateToInstrumentComponent(sessionID: UUID, instrumentID: UUID, componentID: UUID)
    func navigateToInstrument(sessionID: UUID, instrumentID: UUID)
    func selectedComponentID(sessionID: UUID, instrumentID: UUID) -> UUID?
}

@MainActor
final class InstrumentUIRegistry {
    static let shared = InstrumentUIRegistry()

    private var kinds: [LumaCore.InstrumentKind: InstrumentUIKind] = [:]

    private init() {}

    func register(_ kind: LumaCore.InstrumentKind, ui: InstrumentUIKind) {
        kinds[kind] = ui
    }

    func ui(for kind: LumaCore.InstrumentKind) -> InstrumentUIKind {
        kinds[kind] ?? PlaceholderUIKind.shared
    }
}

@MainActor
private final class PlaceholderUIKind: InstrumentUIKind {
    static let shared = PlaceholderUIKind()

    func makeDetailUI(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> InstrumentDetailUI {
        PlaceholderDetailUI()
    }
}

@MainActor
private final class PlaceholderDetailUI: InstrumentDetailUI {
    let widget: Widget

    init() {
        let label = Label(str: "Unknown instrument kind")
        label.add(cssClass: "dim-label")
        label.halign = .start
        label.marginStart = 24
        label.marginTop = 12
        widget = label
    }

    func update(_ instrument: LumaCore.InstrumentInstance) {}
}
