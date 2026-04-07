import CCairo
import Cairo
import Foundation
import Gtk
import LumaCore

@MainActor
final class ITraceTimeline {
    let widget: DrawingArea

    var onSelect: ((Int) -> Void)?

    private let functionCalls: [TraceFunctionCall]
    private let totalEntryCount: Int
    private var selectedIndex: Int?

    init(functionCalls: [TraceFunctionCall], totalEntryCount: Int) {
        self.functionCalls = functionCalls
        self.totalEntryCount = max(1, totalEntryCount)

        let area = DrawingArea()
        area.setSizeRequest(width: -1, height: 32)
        area.hexpand = true
        area.set(hasTooltip: true)
        widget = area

        area.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated {
                self?.draw(ctx: ctx, width: Double(width), height: Double(height))
            }
        }

        let click = GestureClick()
        click.set(button: 1)
        click.onPressed { [weak self, weak area] _, _, x, _ in
            MainActor.assumeIsolated {
                guard let self, let area else { return }
                let width = Double(area.allocatedWidth)
                if let idx = self.callIndex(at: x, width: width) {
                    self.selectedIndex = idx
                    area.queueDraw()
                    self.onSelect?(idx)
                }
            }
        }
        area.add(controller: click)

        area.onQueryTooltip { [weak self] _, x, _, _, tooltip in
            MainActor.assumeIsolated {
                guard let self else { return false }
                let width = Double(area.allocatedWidth)
                guard let idx = self.callIndex(at: Double(x), width: width) else {
                    return false
                }
                tooltip.set(text: self.functionCalls[idx].functionName)
                return true
            }
        }
    }

    func setSelected(index: Int?) {
        guard selectedIndex != index else { return }
        selectedIndex = index
        widget.queueDraw()
    }

    private func callIndex(at x: Double, width: Double) -> Int? {
        guard !functionCalls.isEmpty, width > 0 else { return nil }
        var accX: Double = 0
        for (i, call) in functionCalls.enumerated() {
            let w = max(2, Double(call.entryCount) / Double(totalEntryCount) * width)
            if x < accX + w { return i }
            accX += w
        }
        return functionCalls.count - 1
    }

    private func draw(ctx: Cairo.ContextRef, width: Double, height: Double) {
        ctx.setSource(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.55)
        ctx.rectangle(x: 0, y: 0, width: width, height: height)
        ctx.fill()

        guard !functionCalls.isEmpty, width > 0 else { return }

        var x: Double = 0
        for (i, call) in functionCalls.enumerated() {
            let w = max(2, Double(call.entryCount) / Double(totalEntryCount) * width)
            let isSelected = selectedIndex == i

            let hue = functionHue(call.functionName)
            let (r, g, b) = hsvToRgb(h: hue, s: 0.7, v: 0.55)
            ctx.setSource(red: r, green: g, blue: b, alpha: 1.0)
            ctx.rectangle(x: x, y: 0, width: w, height: height)
            ctx.fill()

            if i > 0 {
                ctx.setSource(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.35)
                ctx.rectangle(x: x, y: 2, width: 0.5, height: height - 4)
                ctx.fill()
            }

            if isSelected {
                ctx.setSource(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.9)
                ctx.lineWidth = 1.5
                ctx.rectangle(x: x + 0.75, y: 0.75, width: w - 1.5, height: height - 1.5)
                ctx.stroke()
            }

            if w > 30 {
                drawSegmentLabel(
                    ctx: ctx,
                    text: call.shortName,
                    x: x,
                    width: w,
                    height: height,
                    isSelected: isSelected
                )
            }

            x += w
        }
    }

    private func drawSegmentLabel(
        ctx: Cairo.ContextRef,
        text: String,
        x: Double,
        width: Double,
        height: Double,
        isSelected: Bool
    ) {
        cairo_select_font_face(
            ctx.context_ptr,
            "monospace",
            CAIRO_FONT_SLANT_NORMAL,
            isSelected ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL
        )
        cairo_set_font_size(ctx.context_ptr, 9)

        var extents = cairo_text_extents_t()
        let display = ellipsize(text: text, width: width - 12, ctx: ctx)
        display.withCString { cstr in
            cairo_text_extents(ctx.context_ptr, cstr, &extents)
        }

        let textX = x + width - 6 - extents.width - extents.x_bearing
        let textY = (height + extents.height) / 2

        if isSelected {
            ctx.setSource(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        } else {
            ctx.setSource(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.7)
        }
        ctx.moveTo(textX, textY)
        display.withCString { cstr in
            cairo_show_text(ctx.context_ptr, cstr)
        }
    }

    private func ellipsize(text: String, width: Double, ctx: Cairo.ContextRef) -> String {
        var extents = cairo_text_extents_t()
        text.withCString { cstr in
            cairo_text_extents(ctx.context_ptr, cstr, &extents)
        }
        if extents.width <= width { return text }
        var trimmed = text
        while trimmed.count > 1 {
            trimmed.removeFirst()
            let candidate = "…" + trimmed
            candidate.withCString { cstr in
                cairo_text_extents(ctx.context_ptr, cstr, &extents)
            }
            if extents.width <= width { return candidate }
        }
        return "…"
    }

    private func functionHue(_ name: String) -> Double {
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Double(hash % 360) / 360.0
    }

    private func hsvToRgb(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6.0)
        let f = h * 6.0 - Double(i)
        let p = v * (1.0 - s)
        let q = v * (1.0 - f * s)
        let t = v * (1.0 - (1.0 - f) * s)
        switch i % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
