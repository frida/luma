import CGraphene
import CGtk
import Foundation
import Gdk
import struct Graphene.PointRef
import Gtk
import LumaCore

private func computePoint<Src: WidgetProtocol, Dst: WidgetProtocol>(
    x: Double,
    y: Double,
    from src: Src,
    to dst: Dst
) -> (x: Double, y: Double) {
    var source = graphene_point_t(x: Float(x), y: Float(y))
    var destination = graphene_point_t(x: 0, y: 0)
    _ = withUnsafeMutablePointer(to: &source) { srcPtr in
        withUnsafeMutablePointer(to: &destination) { dstPtr in
            src.computePoint(target: dst, point: PointRef(srcPtr), outPoint: PointRef(dstPtr))
        }
    }
    return (Double(destination.x), Double(destination.y))
}

@MainActor
enum AddressActionMenu {
    static var navigator: ((UUID, UUID) -> Void)?
    static var errorReporter: ((String) -> Void)?
    static var navigateToTarget: ((LumaCore.NavigationTarget) -> Void)?

    static func attach(
        to anchor: Widget,
        engine: Engine,
        sessionID: UUID,
        address: UInt64,
        value: String,
        copyLabel: String = "Copy",
        includeDisassembly: Bool = true,
        context: AddressContext = AddressContext()
    ) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.propagationPhase = GTK_PHASE_CAPTURE
        gesture.onPressed { [anchor] gesture, _, x, y in
            MainActor.assumeIsolated {
                _ = gesture.set(state: GTK_EVENT_SEQUENCE_CLAIMED)
                present(at: anchor, x: x, y: y, engine: engine, sessionID: sessionID, address: address, value: value, copyLabel: copyLabel, includeDisassembly: includeDisassembly, context: context)
            }
        }
        anchor.install(controller: gesture)
    }

    static func present(
        at anchor: Widget,
        x: Double,
        y: Double,
        engine: Engine,
        sessionID: UUID,
        address: UInt64,
        value: String,
        copyLabel: String = "Copy",
        includeDisassembly: Bool = true,
        context: AddressContext = AddressContext(),
        extraSections: [[ContextMenu.Item]] = []
    ) {
        guard let rootPtr = anchor.root?.ptr else { return }
        let root = WidgetRef(raw: rootPtr)
        let point = computePoint(x: x, y: y, from: anchor, to: root)
        Task { @MainActor in
            let facts = await engine.addressFacts(sessionID: sessionID, address: address, context: context)
            presentResolved(
                at: root, x: point.x, y: point.y, engine: engine, sessionID: sessionID,
                address: address, value: value, copyLabel: copyLabel, includeDisassembly: includeDisassembly, context: context, facts: facts, extraSections: extraSections)
        }
    }

    private static func presentResolved(
        at anchor: some WidgetProtocol,
        x: Double,
        y: Double,
        engine: Engine,
        sessionID: UUID,
        address: UInt64,
        value: String,
        copyLabel: String,
        includeDisassembly: Bool,
        context: AddressContext,
        facts: AddressFacts,
        extraSections: [[ContextMenu.Item]]
    ) {
        let copySection: [ContextMenu.Item] = [
            .init(copyLabel) { copyToClipboard(value) }
        ]

        var inspectSection: [ContextMenu.Item] = []
        if includeDisassembly, facts.mapping == .executable {
            inspectSection.append(.init("Open Disassembly") {
                openInsight(engine: engine, sessionID: sessionID, address: address, kind: .disassembly, preferredAnchor: context.anchorHint, failureLabel: "Can\u{2019}t open disassembly")
            })
        }
        if facts.mapping != .unmapped {
            inspectSection.append(.init("Open Memory") {
                openInsight(engine: engine, sessionID: sessionID, address: address, kind: .memory, preferredAnchor: context.anchorHint, failureLabel: "Can\u{2019}t open memory")
            })
        }

        let pluggableSection: [ContextMenu.Item] = engine
            .addressActions(sessionID: sessionID, address: address, context: context, facts: facts)
            .map { action in
                ContextMenu.Item(action.title, destructive: action.role == .destructive) {
                    Task { @MainActor in
                        guard let target = await action.perform() else { return }
                        navigateToTarget?(target)
                    }
                }
            }

        ContextMenu.present([copySection, inspectSection] + extraSections + [pluggableSection], at: anchor, x: x, y: y)
    }

    static func openInsight(
        engine: Engine,
        sessionID: UUID,
        address: UInt64,
        kind: AddressInsight.Kind,
        preferredAnchor: AddressAnchor? = nil,
        failureLabel: String
    ) {
        do {
            let insight = try engine.getOrCreateInsight(sessionID: sessionID, pointer: address, kind: kind, preferredAnchor: preferredAnchor)
            navigator?(sessionID, insight.id)
        } catch {
            errorReporter?("\(failureLabel): \(error.localizedDescription)")
        }
    }

    private static func copyToClipboard(_ value: String) {
        guard let display = Display.getDefault() else { return }
        display.clipboard.set(text: value)
    }
}
