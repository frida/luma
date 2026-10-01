import CGraphene
import struct Graphene.PointRef
import Gtk

@MainActor
enum ContextMenu {
    struct Item {
        let label: String
        let isDestructive: Bool
        let isEnabled: Bool
        let handler: () -> Void

        init(_ label: String, destructive: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
            self.label = label
            self.isDestructive = destructive
            self.isEnabled = enabled
            self.handler = handler
        }
    }

    static func present(
        _ sections: [[Item]],
        at anchor: some WidgetProtocol,
        x: Double,
        y: Double
    ) {
        guard let rootPtr = anchor.root?.ptr else { return }
        let root = WidgetRef(raw: rootPtr)
        let (px, py) = computePoint(x: x, y: y, from: anchor, to: root)

        let popover = Popover()
        popover.hasArrow = false
        popover.add(cssClass: "luma-context-menu")

        let box = Box(orientation: .vertical, spacing: 0)
        box.marginTop = 4
        box.marginBottom = 4
        box.marginStart = 4
        box.marginEnd = 4

        var firstSection = true
        for items in sections where !items.isEmpty {
            if !firstSection {
                box.append(child: Separator(orientation: .horizontal))
            }
            firstSection = false
            for item in items {
                box.append(child: makeButton(item, popover: popover))
            }
        }

        popover.set(child: box)
        popover.set(parent: root)
        popover.onClosed { closed in
            MainActor.assumeIsolated { closed.unparent() }
        }
        popover.presentPointing(at: px, y: py)
    }

    private static func makeButton(_ item: Item, popover: Popover) -> Button {
        let label = Label(str: item.label)
        label.halign = .start
        label.xalign = 0
        label.hexpand = true

        let button = Button()
        button.set(child: label)
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-menu-item")
        button.sensitive = item.isEnabled

        let handler = item.handler
        let menu = PopoverRef(raw: popover.ptr)
        button.onClicked { _ in
            MainActor.assumeIsolated {
                menu.popdown()
                _Concurrency.Task { @MainActor in handler() }
            }
        }
        return button
    }
}

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
