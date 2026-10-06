import CGtk
import Foundation
import Gtk
import GtkSource

@MainActor
final class TextLayer {
    let area: DrawingArea
    var onDraw: (UnsafeMutablePointer<cairo_t>) -> Void = { _ in }

    private let editor: GtkSource.View
    private let buffer: GtkSource.Buffer

    init(editor: GtkSource.View, buffer: GtkSource.Buffer) {
        self.editor = editor
        self.buffer = buffer
        area = DrawingArea()
        area.canTarget = false
        area.setDrawFunc { [weak self] _, ctx, _, _ in
            MainActor.assumeIsolated {
                self?.onDraw(ctx._ptr)
            }
        }
        for adjustment in [editor.vadjustment!, editor.hadjustment!] {
            adjustment.onValueChanged { [weak self] _ in
                MainActor.assumeIsolated { self?.queueDraw() }
            }
        }
    }

    func queueDraw() {
        area.queueDraw()
    }

    var textColor: GdkRGBA {
        var color = GdkRGBA()
        gtk_widget_get_color(editor.widget_ptr, &color)
        return color
    }

    func textLayout(markup: String) -> UnsafeMutablePointer<PangoLayout> {
        let layout = gtk_widget_create_pango_layout(editor.widget_ptr, nil)!
        pango_layout_set_markup(layout, markup, -1)
        return layout
    }

    func visibleLines() -> ClosedRange<Int> {
        let visible = visibleRect()
        return line(atBufferY: visible.y)...line(atBufferY: visible.y + visible.height)
    }

    func clipToText(_ cr: UnsafeMutablePointer<cairo_t>) {
        let visible = visibleRect()
        let origin = point(bufferX: visible.x, bufferY: visible.y)
        cairo_rectangle(cr, origin.x, origin.y, Double(visible.width), Double(visible.height))
        cairo_clip(cr)
    }

    func rect(ofOffset offset: Int) -> CGRect {
        var location = GdkRectangle()
        withIter { iter in
            gtk_text_buffer_get_iter_at_offset(buffer.text_buffer_ptr, iter, gint(offset))
            gtk_text_view_get_iter_location(editor.text_view_ptr, iter, &location)
        }
        let origin = point(bufferX: location.x, bufferY: location.y)
        return CGRect(x: origin.x, y: origin.y, width: Double(location.width), height: Double(location.height))
    }

    func point(fromEditorX x: Double, y: Double) -> CGPoint {
        var from = graphene_point_t(x: Float(x), y: Float(y))
        var to = graphene_point_t()
        _ = gtk_widget_compute_point(editor.widget_ptr, area.widget_ptr, &from, &to)
        return CGPoint(x: Double(to.x), y: Double(to.y))
    }

    func line(atY y: Double, in widget: some WidgetProtocol) -> Int {
        var from = graphene_point_t(x: 0, y: Float(y))
        var to = graphene_point_t()
        _ = gtk_widget_compute_point(widget.widget_ptr, editor.widget_ptr, &from, &to)
        var bufferX: gint = 0
        var bufferY: gint = 0
        gtk_text_view_window_to_buffer_coords(editor.text_view_ptr, TextWindowType.widget.value, 0, gint(to.y), &bufferX, &bufferY)
        return line(atBufferY: bufferY)
    }

    private func visibleRect() -> GdkRectangle {
        var rect = GdkRectangle()
        gtk_text_view_get_visible_rect(editor.text_view_ptr, &rect)
        return rect
    }

    private func line(atBufferY y: gint) -> Int {
        withIter { iter in
            gtk_text_view_get_line_at_y(editor.text_view_ptr, iter, y, nil)
            return Int(gtk_text_iter_get_line(iter))
        }
    }

    private func point(bufferX: gint, bufferY: gint) -> CGPoint {
        var windowX: gint = 0
        var windowY: gint = 0
        gtk_text_view_buffer_to_window_coords(editor.text_view_ptr, TextWindowType.widget.value, bufferX, bufferY, &windowX, &windowY)
        var from = graphene_point_t(x: Float(windowX), y: Float(windowY))
        var to = graphene_point_t()
        _ = gtk_widget_compute_point(editor.widget_ptr, area.widget_ptr, &from, &to)
        return CGPoint(x: Double(to.x), y: Double(to.y))
    }

    private func withIter<R>(_ body: (UnsafeMutablePointer<GtkTextIter>) -> R) -> R {
        let iter = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { iter.deallocate() }
        return body(iter)
    }
}
