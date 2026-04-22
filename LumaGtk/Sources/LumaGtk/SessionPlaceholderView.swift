import CCairo
import Cairo
import Gtk
import LumaCore

@MainActor
enum SessionPlaceholderView {
    static func make(seed: String, displayName: String, pixelSize: Int) -> Widget {
        let initials = SessionPlaceholder.initials(for: displayName)
        let palette = SessionPlaceholder.palette(for: seed)

        let area = DrawingArea()
        area.setSizeRequest(width: pixelSize, height: pixelSize)
        area.setDrawFunc { _, ctx, width, height in
            paint(
                ctx: ctx,
                width: Double(width),
                height: Double(height),
                palette: palette,
                initials: initials
            )
        }
        return area
    }

    private static func paint(
        ctx: Cairo.ContextRef,
        width: Double,
        height: Double,
        palette: SessionPlaceholder.Palette,
        initials: String
    ) {
        let radius = 4.0
        roundedRectanglePath(ctx: ctx, width: width, height: height, radius: radius)
        ctx.clip()

        let (r1, g1, b1) = hsvToRgb(
            h: palette.primaryHue,
            s: palette.primarySaturation,
            v: palette.primaryBrightness
        )
        let (r2, g2, b2) = hsvToRgb(
            h: palette.secondaryHue,
            s: palette.secondarySaturation,
            v: palette.secondaryBrightness
        )
        let gradient = cairo_pattern_create_linear(0, 0, width, height)
        cairo_pattern_add_color_stop_rgb(gradient, 0.0, r1, g1, b1)
        cairo_pattern_add_color_stop_rgb(gradient, 1.0, r2, g2, b2)
        cairo_set_source(ctx.context_ptr, gradient)
        cairo_pattern_destroy(gradient)
        ctx.rectangle(x: 0, y: 0, width: width, height: height)
        ctx.fill()

        drawInitials(ctx: ctx, text: initials, width: width, height: height)
    }

    private static func roundedRectanglePath(
        ctx: Cairo.ContextRef,
        width: Double,
        height: Double,
        radius: Double
    ) {
        let r = min(radius, min(width, height) / 2)
        cairo_new_sub_path(ctx.context_ptr)
        cairo_arc(ctx.context_ptr, width - r, r, r, -.pi / 2, 0)
        cairo_arc(ctx.context_ptr, width - r, height - r, r, 0, .pi / 2)
        cairo_arc(ctx.context_ptr, r, height - r, r, .pi / 2, .pi)
        cairo_arc(ctx.context_ptr, r, r, r, .pi, 3 * .pi / 2)
        cairo_close_path(ctx.context_ptr)
    }

    private static func drawInitials(
        ctx: Cairo.ContextRef,
        text: String,
        width: Double,
        height: Double
    ) {
        let slant = cairo_font_slant_t(rawValue: 0)
        let weight = cairo_font_weight_t(rawValue: 1)
        cairo_select_font_face(ctx.context_ptr, "sans-serif", slant, weight)
        cairo_set_font_size(ctx.context_ptr, height * 0.48)

        var extents = cairo_text_extents_t()
        text.withCString { cstr in
            cairo_text_extents(ctx.context_ptr, cstr, &extents)
        }

        let textX = (width - extents.width) / 2 - extents.x_bearing
        let textY = (height - extents.height) / 2 - extents.y_bearing

        ctx.setSource(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.25)
        ctx.moveTo(textX, textY + 0.5)
        text.withCString { cstr in
            cairo_show_text(ctx.context_ptr, cstr)
        }

        ctx.setSource(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.moveTo(textX, textY)
        text.withCString { cstr in
            cairo_show_text(ctx.context_ptr, cstr)
        }
    }

    private static func hsvToRgb(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
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
