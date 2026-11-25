import CGraphene
import CGtk
import Gtk
import LumaCore

@MainActor
final class ArrangedWidgetArea {
    let widget: Box
    private let scroller: ScrolledWindow
    private let above: [Widget]
    private let margin: Int32
    private let content: Box
    private let cover: Overlay
    private let layout: InstrumentLayout
    private let widgets: [InstrumentWidget]
    private let metrics: InstrumentLayout.Metrics
    private let cards: [(id: String, card: Widget)]
    private var tallies: [String: RowTally]
    private var viewportHeight = 0.0
    private var allocatedWidth = 0.0
    private var cached: (width: Double, height: Double, arrangement: InstrumentLayout.Arrangement)?

    init(
        above: [Widget],
        margin: Int32,
        layout: InstrumentLayout,
        widgets: [InstrumentWidget],
        cards: [(id: String, card: Widget)],
        tallies: [String: RowTally],
        metrics: InstrumentLayout.Metrics
    ) {
        self.above = above
        self.margin = margin
        self.layout = layout
        self.widgets = widgets
        self.cards = cards
        self.tallies = tallies
        self.metrics = metrics

        content = Box(orientation: .vertical, spacing: 0)
        for entry in cards {
            gtk_widget_set_overflow(entry.card.widget_ptr, GTK_OVERFLOW_HIDDEN)
            content.append(child: entry.card)
        }

        let page = Box(orientation: .vertical, spacing: Int(Self.spacing))
        page.marginStart = Int(margin)
        page.marginEnd = Int(margin)
        page.marginTop = Int(margin)
        page.marginBottom = Int(margin)
        for widget in above {
            page.append(child: widget)
        }
        cover = Overlay()
        cover.set(child: content)
        page.append(child: cover)

        scroller = ScrolledWindow()
        scroller.hexpand = true
        scroller.vexpand = true
        scroller.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroller.set(child: page)

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true
        widget.append(child: scroller)

        Self.install(on: widget, owner: self, measure: Self.measureArea, allocate: Self.allocateArea)
        Self.install(on: content, owner: self, measure: Self.measureContent, allocate: Self.allocateContent)
    }

    func cover(with widget: Widget) {
        cover.addOverlay(widget: widget)
    }

    func setCovered(_ covered: Bool) {
        content.sensitive = !covered
        content.canTarget = !covered
    }

    func setTally(_ tally: RowTally, of id: String) {
        let cap = layout.path(of: id).flatMap { layout[$0].maxRows } ?? InstrumentLayout.defaultRowCap
        let shownBefore = tallies[id]?.capped(at: cap)
        tallies[id] = tally
        guard tally.capped(at: cap) != shownBefore else { return }
        cached = nil
        content.queueResize()
    }

    private var rowCounts: [String: Int] {
        tallies.mapValues(\.count)
    }

    private var subtitledRowCounts: [String: Int] {
        tallies.mapValues(\.subtitled)
    }

    private func arrangement(width: Double, height: Double) -> InstrumentLayout.Arrangement {
        if let cached, cached.width == width, cached.height == height {
            return cached.arrangement
        }
        let arrangement = layout.arranged(
            widgets: widgets, width: width, height: height, rowCounts: rowCounts, subtitledRowCounts: subtitledRowCounts, metrics: metrics)
        cached = (width, height, arrangement)
        return arrangement
    }

    private func naturalHeight(forWidth width: Double) -> Double {
        let contentWidth = width - Double(2 * margin)
        let natural = layout.arranged(
            widgets: widgets, width: contentWidth, height: 0, rowCounts: rowCounts, subtitledRowCounts: subtitledRowCounts, metrics: metrics
        ).height
        return natural + aboveHeight(forWidth: Int32(contentWidth)) + Double(2 * margin)
    }

    private func aboveHeight(forWidth width: Int32) -> Double {
        let heights = above.map { Double(ArrangedWidgetArea.size(of: $0.widget_ptr, GTK_ORIENTATION_VERTICAL, for: width).natural) }
        return heights.reduce(0, +) + Double(above.count) * Self.spacing
    }

    private func width(for size: Int32) -> Double {
        size >= 0 ? Double(size) : allocatedWidth
    }

    private func adopt(viewportHeight height: Double) {
        guard height != viewportHeight else { return }
        viewportHeight = height
        cached = nil
        content.queueResize()
    }

    private func minimumCardWidth() -> Int32 {
        cards.map { ArrangedWidgetArea.size(of: $0.card.widget_ptr, GTK_ORIENTATION_HORIZONTAL, for: -1).minimum }.max() ?? 0
    }

    private func place(width: Double) {
        let arrangement = arrangement(width: width, height: viewportHeight)
        for entry in cards {
            let frame = arrangement.frames[entry.id]!
            _ = Self.size(of: entry.card.widget_ptr, GTK_ORIENTATION_VERTICAL, for: Int32(frame.width))
            var origin = graphene_point_t(x: Float(frame.x), y: Float(frame.y))
            gtk_widget_allocate(entry.card.widget_ptr, Int32(frame.width), Int32(frame.height), -1, gsk_transform_translate(nil, &origin))
        }
    }

    private static let spacing = 12.0
    private static let key = "luma-arranged-widget-area"

    private static func install(
        on widget: Box, owner: ArrangedWidgetArea, measure: GtkCustomMeasureFunc, allocate: GtkCustomAllocateFunc
    ) {
        g_object_set_data(
            UnsafeMutableRawPointer(widget.widget_ptr)?.assumingMemoryBound(to: GObject.self), key,
            Unmanaged.passUnretained(owner).toOpaque())
        gtk_widget_set_layout_manager(widget.widget_ptr, gtk_custom_layout_new(heightForWidth, measure, allocate))
    }

    private static func owner(of widget: UnsafeMutablePointer<GtkWidget>?) -> ArrangedWidgetArea {
        let data = g_object_get_data(UnsafeMutableRawPointer(widget)?.assumingMemoryBound(to: GObject.self), key)!
        return Unmanaged<ArrangedWidgetArea>.fromOpaque(data).takeUnretainedValue()
    }

    private static func size(
        of widget: UnsafeMutablePointer<GtkWidget>?, _ orientation: GtkOrientation, for size: Int32
    ) -> (minimum: Int32, natural: Int32) {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(widget, orientation, size, &minimum, &natural, nil, nil)
        return (minimum, natural)
    }

    private static let heightForWidth: GtkCustomRequestModeFunc = { _ in
        GTK_SIZE_REQUEST_HEIGHT_FOR_WIDTH
    }

    private static let measureArea: GtkCustomMeasureFunc = { area, orientation, forSize, minimum, natural, _, _ in
        nonisolated(unsafe) let area = area
        nonisolated(unsafe) let minimum = minimum
        nonisolated(unsafe) let natural = natural
        MainActor.assumeIsolated {
            let owner = ArrangedWidgetArea.owner(of: area)
            if orientation == GTK_ORIENTATION_HORIZONTAL {
                let size = ArrangedWidgetArea.size(of: owner.scroller.widget_ptr, orientation, for: -1)
                minimum?.pointee = size.minimum
                natural?.pointee = size.natural
                return
            }
            _ = ArrangedWidgetArea.size(of: owner.scroller.widget_ptr, orientation, for: forSize)
            minimum?.pointee = 0
            natural?.pointee = Int32(owner.naturalHeight(forWidth: owner.width(for: forSize)))
        }
    }

    private static let allocateArea: GtkCustomAllocateFunc = { area, width, height, _ in
        nonisolated(unsafe) let area = area
        MainActor.assumeIsolated {
            let owner = ArrangedWidgetArea.owner(of: area)
            let contentWidth = width - 2 * owner.margin
            owner.adopt(viewportHeight: Double(height - 2 * owner.margin) - owner.aboveHeight(forWidth: contentWidth))
            _ = ArrangedWidgetArea.size(of: owner.scroller.widget_ptr, GTK_ORIENTATION_VERTICAL, for: width)
            gtk_widget_allocate(owner.scroller.widget_ptr, width, height, -1, nil)
        }
    }

    private static let measureContent: GtkCustomMeasureFunc = { content, orientation, forSize, minimum, natural, _, _ in
        nonisolated(unsafe) let content = content
        nonisolated(unsafe) let minimum = minimum
        nonisolated(unsafe) let natural = natural
        MainActor.assumeIsolated {
            let owner = ArrangedWidgetArea.owner(of: content)
            if orientation == GTK_ORIENTATION_HORIZONTAL {
                let width = owner.minimumCardWidth()
                minimum?.pointee = width
                natural?.pointee = width
                return
            }
            let height = Int32(owner.arrangement(width: owner.width(for: forSize), height: owner.viewportHeight).height)
            minimum?.pointee = height
            natural?.pointee = height
        }
    }

    private static let allocateContent: GtkCustomAllocateFunc = { content, width, _, _ in
        nonisolated(unsafe) let content = content
        MainActor.assumeIsolated {
            let owner = ArrangedWidgetArea.owner(of: content)
            owner.allocatedWidth = Double(width)
            owner.place(width: Double(width))
        }
    }
}

struct RowTally: Equatable {
    var count: Int
    var subtitled: Int

    func capped(at cap: Int) -> RowTally {
        let shown = min(count, cap)
        return RowTally(count: shown, subtitled: min(subtitled, shown))
    }
}
