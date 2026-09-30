import CCairo
import CGtk
import Foundation
import LumaCore

enum GdkFrameEncoder {
    static func install() {
        VirtualMachineFrameEncoder.png = { frame, width in
            png(of: frame, width: width)
        }
    }

    private nonisolated static func png(of frame: VirtualMachineFrame, width: Int) -> Data {
        let height = max(1, frame.height * width / frame.width)
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, gint(width), gint(height))!
        defer { cairo_surface_destroy(surface) }
        draw(frame, scaledOnto: surface, width: width, height: height)

        let stride = Int(cairo_image_surface_get_stride(surface))
        let pixels = g_bytes_new(cairo_image_surface_get_data(surface), gsize(stride * height))
        defer { g_bytes_unref(pixels) }
        let texture = gdk_memory_texture_new(gint(width), gint(height), GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, pixels, gsize(stride))
        defer { g_object_unref(texture) }

        let png = gdk_texture_save_to_png_bytes(texture)
        defer { g_bytes_unref(png) }
        var size: gsize = 0
        let bytes = g_bytes_get_data(png, &size)
        return Data(bytes: bytes!, count: Int(size))
    }

    private nonisolated static func draw(
        _ frame: VirtualMachineFrame, scaledOnto surface: UnsafeMutablePointer<cairo_surface_t>, width: Int, height: Int
    ) {
        let format = frame.format == .bgra8888 ? CAIRO_FORMAT_ARGB32 : CAIRO_FORMAT_RGB24
        frame.withPixels { pixels in
            let source = cairo_image_surface_create_for_data(
                UnsafeMutablePointer(mutating: pixels.bindMemory(to: UInt8.self).baseAddress), format,
                gint(frame.width), gint(frame.height), gint(frame.stride))
            defer { cairo_surface_destroy(source) }
            let cr = cairo_create(surface)
            defer { cairo_destroy(cr) }
            cairo_scale(cr, Double(width) / Double(frame.width), Double(height) / Double(frame.height))
            cairo_set_source_surface(cr, source, 0, 0)
            cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD)
            cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
            cairo_paint(cr)
        }
        cairo_surface_flush(surface)
    }
}
