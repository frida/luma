import CCairo
import CGtk
import Cairo
import Foundation
import Gtk

/// The pager over the whole page: a square per slot -- the snippets, then each
/// inspector column -- with the current one brightest, and a thumb beneath that
/// tracks and drags the columns' scroll. It sits above both the snippets and
/// the inspectors, the way the SwiftUI strip stands over the whole page.
@MainActor
final class PharoOverviewBar {
    let widget: Box

    var slotCount: () -> Int = { 0 }
    var isCurrent: (Int) -> Bool = { _ in false }
    var tooltip: (Int) -> String = { _ in "" }
    var activate: (Int) -> Void = { _ in }
    var adjustment: () -> AdjustmentRef? = { nil }

    private let squaresRow: Box
    private let thumb: DrawingArea
    private var thumbHovered = false
    private var thumbDragBase = 0.0

    init() {
        squaresRow = Box(orientation: .horizontal, spacing: 3)
        squaresRow.halign = .center

        thumb = DrawingArea()
        thumb.setSizeRequest(width: -1, height: 8)
        thumb.hexpand = true

        widget = Box(orientation: .vertical, spacing: 3)
        widget.halign = .center
        widget.marginTop = 4
        widget.marginBottom = 4
        widget.append(child: squaresRow)
        widget.append(child: thumb)

        installThumb()
    }

    func reload() {
        while let existing = squaresRow.getFirstChild() {
            squaresRow.remove(child: existing)
        }
        for slot in 0..<slotCount() {
            let square = Button()
            square.add(cssClass: "luma-pharo-strip")
            square.setSizeRequest(width: 22, height: 12)
            square.tooltipText = tooltip(slot)
            if isCurrent(slot) { square.add(cssClass: "current") }
            square.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.activate(slot) }
            }
            squaresRow.append(child: square)
        }
        thumb.queueDraw()
    }

    func refresh() {
        thumb.queueDraw()
    }

    private func installThumb() {
        thumb.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated { self?.drawThumb(ctx, Double(width), Double(height)) }
        }
        let drag = GestureDrag()
        drag.onDragBegin { [weak self] _, _, _ in
            MainActor.assumeIsolated { self?.thumbDragBase = self?.adjustment()?.value ?? 0 }
        }
        drag.onDragUpdate { [weak self] _, offsetX, _ in
            MainActor.assumeIsolated {
                guard let self, let adjustment = self.adjustment() else { return }
                let track = Double(self.thumb.width)
                guard track > 0 else { return }
                adjustment.value = self.thumbDragBase + offsetX / track * adjustment.upper
            }
        }
        thumb.install(controller: drag)
        let motion = EventControllerMotion()
        motion.onEnter { [weak self] _, _, _ in
            MainActor.assumeIsolated { self?.thumbHovered = true; self?.thumb.queueDraw() }
        }
        motion.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.thumbHovered = false; self?.thumb.queueDraw() }
        }
        thumb.install(controller: motion)
    }

    private func drawThumb(_ ctx: Cairo.ContextRef, _ width: Double, _ height: Double) {
        guard let adjustment = adjustment() else { return }
        let upper = max(adjustment.upper, 1)
        let page = adjustment.pageSize > 0 ? adjustment.pageSize : upper
        let fractionVisible = min(page / upper, 1)
        let fractionLeading = min(adjustment.value / upper, 1 - fractionVisible)
        let thumbWidth = max(width * fractionVisible, 12)
        let thumbX = min(width * fractionLeading, width - thumbWidth)
        let y = height / 2
        if thumbHovered {
            ctx.setSource(red: 0.937, green: 0.392, blue: 0.337, alpha: 1)
        } else {
            ctx.setSource(red: 0.55, green: 0.55, blue: 0.6, alpha: 0.6)
        }
        capsule(ctx, x: thumbX, y: y - 1.5, width: thumbWidth, height: 3)
        ctx.fill()
    }

    private func capsule(_ ctx: Cairo.ContextRef, x: Double, y: Double, width: Double, height: Double) {
        let radius = height / 2
        cairo_new_sub_path(ctx.context_ptr)
        cairo_arc(ctx.context_ptr, x + width - radius, y + radius, radius, -.pi / 2, .pi / 2)
        cairo_arc(ctx.context_ptr, x + radius, y + radius, radius, .pi / 2, 3 * .pi / 2)
        cairo_close_path(ctx.context_ptr)
    }
}
