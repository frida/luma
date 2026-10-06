import CGtk
import Foundation
import Gtk
import GtkSource

@MainActor
final class CodeLineNumbers: GutterRendererSubclass {
    private let buffer: GtkSource.Buffer
    private var digitCount = 0

    private static let leading = 8
    private static let trailing = 4
    private static let alpha: Float = 0.55

    init(editor: GtkSource.View, buffer: GtkSource.Buffer) {
        self.buffer = buffer
        super.init()
        _ = editor.getGutter(windowType: .left)!.insert(renderer: GutterRendererRef(handle), position: 0)
        textChanged()
    }

    func textChanged() {
        let digits = max(String(buffer.lineCount).count, 2)
        guard digits != digitCount else { return }
        digitCount = digits
        let widest = layout(markup: String(repeating: "8", count: digits))
        defer { g_object_unref(widest) }
        var width: gint = 0
        pango_layout_get_pixel_size(widest, &width, nil)
        widget.setSizeRequest(width: Self.leading + Int(width) + Self.trailing, height: -1)
    }

    override func snapshotLine(snapshot: UnsafeMutablePointer<GtkSnapshot>?, lines: UnsafeMutablePointer<GtkSourceGutterLines>?, line: guint) {
        let lines = GutterLinesRef(lines!)
        var top: gint = 0
        var height: gint = 0
        lines.getLineYrange(line: Int(line), mode: .cell, y: &top, height: &height)
        guard height > 0 else { return }
        let isCursor = lines.isCursor(line: Int(line))
        let number = layout(markup: isCursor ? "<b>\(line + 1)</b>" : "\(line + 1)")
        defer { g_object_unref(number) }
        var numberWidth: gint = 0
        var numberHeight: gint = 0
        pango_layout_get_pixel_size(number, &numberWidth, &numberHeight)
        var color = GdkRGBA()
        gtk_widget_get_color(widget.widget_ptr, &color)
        if !isCursor {
            color.alpha *= Self.alpha
        }
        var origin = graphene_point_t(
            x: Float(widget.width - Self.trailing - Int(numberWidth)), y: Float(top) + Float(height - numberHeight) / 2)
        gtk_snapshot_save(snapshot)
        gtk_snapshot_translate(snapshot, &origin)
        gtk_snapshot_append_layout(snapshot, number, &color)
        gtk_snapshot_restore(snapshot)
    }

    private func layout(markup: String) -> UnsafeMutablePointer<PangoLayout> {
        let layout = gtk_widget_create_pango_layout(widget.widget_ptr, nil)!
        pango_layout_set_markup(layout, markup, -1)
        return layout
    }

    private var widget: WidgetRef {
        WidgetRef(raw: handle)
    }
}
