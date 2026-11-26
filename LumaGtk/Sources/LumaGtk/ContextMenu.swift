import CGraphene
import Gdk
import struct Graphene.PointRef
import Gtk

@MainActor
enum ContextMenu {
    struct Item {
        let label: String
        let detail: String?
        let isDestructive: Bool
        let isEnabled: Bool
        let handler: () -> Void
        let children: [Item]

        init(_ label: String, detail: String? = nil, destructive: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
            self.label = label
            self.detail = detail
            self.isDestructive = destructive
            self.isEnabled = enabled
            self.handler = handler
            self.children = []
        }

        init(_ label: String, children: [Item]) {
            self.label = label
            self.detail = nil
            self.isDestructive = false
            self.isEnabled = true
            self.handler = {}
            self.children = children
        }
    }

    private static let windowMargin = 24

    static func attach(to row: Widget, anchor: Widget, present: @escaping (_ x: Double, _ y: Double) -> Void) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { _, _, x, y in
            MainActor.assumeIsolated { present(x, y) }
        }
        row.add(controller: click)
        let longPress = GestureLongPress()
        longPress.onPressed { _, x, y in
            MainActor.assumeIsolated { present(x, y) }
        }
        row.add(controller: longPress)
        let keys = EventControllerKey()
        keys.onKeyPressed { keys, keyval, _, state in
            MainActor.assumeIsolated {
                let key = Int32(keyval)
                guard key == Gdk.keyMenu || (key == Gdk.keyF10 && state.contains(.shiftMask)) else { return false }
                present(0, Double(keys.widget.height))
                return true
            }
        }
        row.add(controller: keys)
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

        let scroller = ScrolledWindow()
        scroller.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroller.propagateNaturalWidth = true
        scroller.propagateNaturalHeight = true
        scroller.maxContentHeight = root.height - windowMargin * 2
        let pages = Stack()
        pages.transitionType = .slideLeftRight
        let main = page(sections, popover: popover, pages: pages)
        _ = pages.add(child: main)
        pages.visibleChild = WidgetRef(main)
        scroller.set(child: pages)

        popover.set(child: scroller)
        popover.set(parent: root)
        let previousFocus = anchor.root?.getFocus().map { Widget(retaining: $0.widget_ptr) }
        popover.onClosed { closed in
            MainActor.assumeIsolated {
                closed.unparent()
                _ = previousFocus?.grabFocus()
            }
        }
        popover.presentPointing(at: px, y: py)
    }

    private static func page(_ sections: [[Item]], popover: Popover, pages: Stack) -> Box {
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
                box.append(child: makeButton(item, popover: popover, pages: pages, returningTo: box))
            }
        }
        return box
    }

    private static func makeButton(_ item: Item, popover: Popover, pages: Stack, returningTo page: Box) -> Button {
        let label = Label(str: item.label)
        label.halign = .start
        label.xalign = 0
        label.hexpand = true

        let content = Box(orientation: .horizontal, spacing: 6)
        if let detail = item.detail {
            let caption = Label(str: detail)
            caption.add(cssClass: "caption")
            caption.add(cssClass: "dim-label")
            caption.halign = .start
            caption.xalign = 0
            caption.wrap = true
            caption.maxWidthChars = 36
            let lines = Box(orientation: .vertical, spacing: 2)
            lines.hexpand = true
            lines.append(child: label)
            lines.append(child: caption)
            content.append(child: lines)
        } else {
            content.append(child: label)
        }

        let button = Button()
        button.set(child: content)
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-menu-item")
        if item.isDestructive {
            button.add(cssClass: "luma-menu-destructive")
        }
        button.sensitive = item.isEnabled

        if !item.children.isEmpty {
            content.append(child: Gtk.Image(iconName: "go-next-symbolic"))
            let submenu = submenuPage(item, popover: popover, pages: pages, returningTo: page)
            button.onClicked { _ in
                MainActor.assumeIsolated {
                    pages.visibleChild = WidgetRef(submenu)
                    _ = submenu.firstChild?.grabFocus()
                }
            }
            return button
        }

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

    private static func submenuPage(_ item: Item, popover: Popover, pages: Stack, returningTo parent: Box) -> Box {
        let title = Label(str: item.label)
        title.add(cssClass: "heading")
        title.hexpand = true

        let backContent = Box(orientation: .horizontal, spacing: 6)
        backContent.append(child: Gtk.Image(iconName: "go-previous-symbolic"))
        backContent.append(child: title)

        let back = Button()
        back.set(child: backContent)
        back.add(cssClass: "flat")
        back.add(cssClass: "luma-menu-item")
        back.onClicked { _ in
            MainActor.assumeIsolated {
                pages.visibleChild = WidgetRef(parent)
                _ = parent.firstChild?.grabFocus()
            }
        }

        let submenu = page([item.children], popover: popover, pages: pages)
        submenu.prepend(child: Separator(orientation: .horizontal))
        submenu.prepend(child: back)
        _ = pages.add(child: submenu)
        return submenu
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
