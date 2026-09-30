import CGtk
import CLuma
import Foundation
import Gtk
import GtkSource
import LumaCore

@MainActor
final class CodeSwatches {
    let layer: TextLayer

    private let buffer: GtkSource.Buffer
    private let cellTag: UnsafeMutablePointer<GtkTextTag>
    private var swatches: [CodeSwatch] = []

    private static let size = 10.0
    private static let gap = 4.0

    init(editor: GtkSource.View, buffer: GtkSource.Buffer) {
        self.buffer = buffer
        layer = TextLayer(editor: editor, buffer: buffer)
        cellTag = luma_text_buffer_create_swatch_tag(buffer.ptr, "luma-swatch-cell", gint(Self.size + Self.gap))
            .assumingMemoryBound(to: GtkTextTag.self)
        layer.onDraw = { [weak self] cr in self?.draw(on: cr) }
    }

    func setColors(_ colors: [LSP.ColorInformation], in text: String) {
        let map = LineMap(text: text)
        let offsets = CharacterOffsets(text: text)
        swatches = colors.map { CodeSwatch(offset: offsets.characterOffset(ofUTF16: map.utf16Offset(of: $0.range.start)), color: $0.color) }
        applyGaps()
    }

    func textChanged() {
        layer.queueDraw()
    }

    private func draw(on cr: UnsafeMutablePointer<cairo_t>) {
        let border = layer.textColor
        keepCellTagOnTop()
        layer.clipToText(cr)
        for swatch in swatches where !isFolded(swatch.offset) {
            let cell = layer.rect(ofOffset: swatch.offset)
            drawCharacter(at: swatch.offset, rightAlignedIn: cell, on: cr)
            let x = cell.minX + Self.gap / 2
            let y = cell.midY - Self.size / 2
            appendRoundedSquare(x: x, y: y, side: Self.size, to: cr)
            cairo_set_source_rgba(cr, swatch.color.red, swatch.color.green, swatch.color.blue, swatch.color.alpha)
            cairo_fill(cr)
            appendRoundedSquare(x: x + 0.5, y: y + 0.5, side: Self.size - 1, to: cr)
            cairo_set_source_rgba(cr, Double(border.red), Double(border.green), Double(border.blue), 0.25)
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
        }
    }

    private func applyGaps() {
        let start = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let end = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            start.deallocate()
            end.deallocate()
        }
        gtk_text_buffer_get_bounds(buffer.text_buffer_ptr, start, end)
        gtk_text_buffer_remove_tag(buffer.text_buffer_ptr, cellTag, start, end)
        for swatch in swatches {
            gtk_text_buffer_get_iter_at_offset(buffer.text_buffer_ptr, start, gint(swatch.offset))
            gtk_text_buffer_get_iter_at_offset(buffer.text_buffer_ptr, end, gint(swatch.offset + 1))
            gtk_text_buffer_apply_tag(buffer.text_buffer_ptr, cellTag, start, end)
        }
        layer.queueDraw()
    }

    private func keepCellTagOnTop() {
        let top = gtk_text_tag_table_get_size(gtk_text_buffer_get_tag_table(buffer.text_buffer_ptr)) - 1
        if gtk_text_tag_get_priority(cellTag) != top {
            gtk_text_tag_set_priority(cellTag, top)
        }
    }

    private func isFolded(_ offset: Int) -> Bool {
        let hidden = gtk_text_tag_table_lookup(gtk_text_buffer_get_tag_table(buffer.text_buffer_ptr), CodeFolding.hiddenTag)
        return withIter(at: offset) { gtk_text_iter_has_tag($0, hidden) != 0 }
    }

    private func drawCharacter(at offset: Int, rightAlignedIn cell: CGRect, on cr: UnsafeMutablePointer<cairo_t>) {
        var color = layer.textColor
        let character = withIter(at: offset) { iter in
            _ = luma_text_iter_get_foreground(iter, cellTag, &color)
            return String(Character(Unicode.Scalar(gtk_text_iter_get_char(iter))!))
        }
        let text = layer.textLayout(markup: SourceMarkup.escape(character))
        defer { g_object_unref(text) }
        var width: gint = 0
        var height: gint = 0
        pango_layout_get_pixel_size(text, &width, &height)
        cairo_set_source_rgba(cr, Double(color.red), Double(color.green), Double(color.blue), Double(color.alpha))
        cairo_move_to(cr, cell.maxX - Double(width), cell.minY + (cell.height - Double(height)) / 2)
        pango_cairo_show_layout(cr, text)
    }

    private func appendRoundedSquare(x: Double, y: Double, side: Double, to cr: UnsafeMutablePointer<cairo_t>) {
        let radius = 2.0
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + side - radius, y + radius, radius, -.pi / 2, 0)
        cairo_arc(cr, x + side - radius, y + side - radius, radius, 0, .pi / 2)
        cairo_arc(cr, x + radius, y + side - radius, radius, .pi / 2, .pi)
        cairo_arc(cr, x + radius, y + radius, radius, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
    }

    private func withIter<R>(at offset: Int, _ body: (UnsafeMutablePointer<GtkTextIter>) -> R) -> R {
        let iter = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { iter.deallocate() }
        gtk_text_buffer_get_iter_at_offset(buffer.text_buffer_ptr, iter, gint(offset))
        return body(iter)
    }
}

private struct CodeSwatch {
    let offset: Int
    let color: LSP.Color
}
