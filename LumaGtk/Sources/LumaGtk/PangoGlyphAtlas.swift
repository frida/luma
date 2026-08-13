import Cairo
import CGtk
import Foundation
import LumaCore

/// Draws the printable range on a grid, with Pango. What an image can reach
/// for fonts is its own business; this is the host's, and it has one.
enum PangoGlyphAtlas {
    static func install() {
        GlyphAtlasRasteriser.rasterise = { pixelSize in
            make(pixelSize: pixelSize)
        }
    }

    private nonisolated static func make(pixelSize: Int) -> GlyphAtlas? {
        let font = pango_font_description_from_string("Monospace")
        pango_font_description_set_absolute_size(font, Double(pixelSize) * Double(PANGO_SCALE))
        defer { pango_font_description_free(font) }

        let measuring = cairo_image_surface_create(Cairo.Format.argb32.value, 1, 1)
        let measure = cairo_create(measuring)
        let layout = pango_cairo_create_layout(measure)
        pango_layout_set_font_description(layout, font)

        let codes = Array(GlyphAtlas.first...GlyphAtlas.last)
        let advances = codes.map { code -> Float in
            Float(size(of: code, layout: layout).width)
        }
        let lineHeight = codes.map { size(of: $0, layout: layout).height }.max() ?? pixelSize

        // A guard texel each side, so a cell is never sampled into its
        // neighbour, and whole texels so it is sampled on its own grid.
        let cellWidth = Int((advances.max() ?? Float(pixelSize)).rounded(.up)) + 2
        let cellHeight = lineHeight + 2
        let columns = 16
        let rows = (codes.count + columns - 1) / columns
        let width = cellWidth * columns
        let height = cellHeight * rows

        let sheet = cairo_image_surface_create(Cairo.Format.argb32.value, Int32(width), Int32(height))
        let context = cairo_create(sheet)
        let drawing = pango_cairo_create_layout(context)
        pango_layout_set_font_description(drawing, font)
        cairo_set_source_rgba(context, 1, 1, 1, 1)

        for (index, code) in codes.enumerated() {
            guard let scalar = Unicode.Scalar(UInt32(code)) else { continue }

            pango_layout_set_text(drawing, String(Character(scalar)), -1)
            cairo_move_to(
                context,
                Double(index % columns * cellWidth + 1),
                Double(index / columns * cellHeight + 1))
            pango_cairo_show_layout(context, drawing)
        }
        cairo_surface_flush(sheet)

        var pixels = [UInt32](repeating: 0, count: width * height)
        if let data = cairo_image_surface_get_data(sheet) {
            let rowBytes = Int(cairo_image_surface_get_stride(sheet))
            for row in 0..<height {
                let start = data.advanced(by: row * rowBytes)
                start.withMemoryRebound(to: UInt32.self, capacity: width) { words in
                    for column in 0..<width {
                        pixels[row * width + column] = words[column]
                    }
                }
            }
        }

        g_object_unref(drawing)
        cairo_destroy(context)
        cairo_surface_destroy(sheet)
        g_object_unref(layout)
        cairo_destroy(measure)
        cairo_surface_destroy(measuring)

        let band = ink(of: pixels, width: width, cellHeight: cellHeight)
        return GlyphAtlas(
            pixels: pixels,
            width: width,
            height: height,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            columns: columns,
            inkTop: band.lowerBound,
            inkBottom: band.upperBound,
            advances: advances)
    }

    private nonisolated static func size(
        of code: Int,
        layout: UnsafeMutablePointer<PangoLayout>?
    ) -> (width: Int, height: Int) {
        guard let scalar = Unicode.Scalar(UInt32(code)) else { return (0, 0) }

        pango_layout_set_text(layout, String(Character(scalar)), -1)
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        return (Int(width), Int(height))
    }

    /// Which rows of a cell the lettering touches. Every cell shares a
    /// baseline, so one pass answers for all of them.
    private nonisolated static func ink(
        of pixels: [UInt32],
        width: Int,
        cellHeight: Int
    ) -> ClosedRange<Int> {
        var top = cellHeight
        var bottom = 0
        for (index, pixel) in pixels.enumerated() where pixel != 0 {
            let row = (index / width) % cellHeight
            top = min(top, row)
            bottom = max(bottom, row)
        }
        guard top <= bottom else { return 0...cellHeight }
        return top...(bottom + 1)
    }
}
