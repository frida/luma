import Adw
import CAdw
import Cairo
import CGtk
import CLuma
import Foundation
import Gtk
import GtkSource
import LumaCore

@MainActor
final class CodeFolding {
    let layer: TextLayer

    static let hiddenTag = "luma-fold-hidden"

    private let buffer: GtkSource.Buffer
    private let gutter: TextLayer
    private var folds: [CodeFold] = []
    private var collapsed: Set<Int> = []
    private var numberWidth = 0.0
    private var openChevronAlpha = 0.0
    private var fade: Adw.TimedAnimation?

    private static let numberLeading = 8.0
    private static let numberToChevron = 4.0
    private static let chevronColumnWidth = 14.0
    private static let chevronToCode = 2.0
    private static let numberAlpha = 0.55
    private static let chevronAlpha = 0.6
    private static let fadeIn = 150
    private static let fadeOut = 400
    private static let placeholderWidth = 22.0
    private static let placeholderGap = 4.0

    init(editor: GtkSource.View, buffer: GtkSource.Buffer) {
        self.buffer = buffer
        layer = TextLayer(editor: editor, buffer: buffer)
        gutter = TextLayer(editor: editor, buffer: buffer)
        gutter.area.canTarget = true
        gtk_text_view_set_gutter(editor.text_view_ptr, GTK_TEXT_WINDOW_LEFT, gutter.area.widget_ptr)
        _ = luma_text_buffer_create_hidden_tag(buffer.ptr, Self.hiddenTag)

        buffer.onMarkSet { [weak self] _, _, _ in
            MainActor.assumeIsolated { self?.gutter.queueDraw() }
        }
        installClicks()
        installHover()
        fitGutter()
        gutter.onDraw = { [weak self] cr in self?.drawGutter(on: cr) }
        layer.onDraw = { [weak self] cr in self?.drawScopes(on: cr) }
    }

    func setRanges(_ ranges: [LSP.FoldingRange], in text: String) {
        folds = CodeFold.folds(from: ranges, in: text)
        collapsed.formIntersection(folds.map(\.startLine))
        applyCollapsed()
    }

    func textChanged() {
        fitGutter()
        gutter.queueDraw()
        layer.queueDraw()
    }

    private func installClicks() {
        let click = GestureClick()
        click.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self, let fold = self.fold(atX: x, y: y) else { return }
                self.toggle(line: fold.startLine)
            }
        }
        gutter.area.add(controller: click)
    }

    private func installHover() {
        let hover = EventControllerMotion()
        hover.onEnter { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fadeOpenChevrons(to: 1, over: Self.fadeIn)
                self.updatePointer(atX: x, y: y)
            }
        }
        hover.onMotion { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.updatePointer(atX: x, y: y) }
        }
        hover.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOpenChevrons(to: 0, over: Self.fadeOut) }
        }
        gutter.area.add(controller: hover)
    }

    private func fitGutter() {
        let digits = max(String(buffer.lineCount).count, 2)
        let widest = gutter.textLayout(markup: String(repeating: "8", count: digits))
        defer { g_object_unref(widest) }
        var width: gint = 0
        pango_layout_get_pixel_size(widest, &width, nil)
        numberWidth = Double(width)
        let total = Self.numberLeading + numberWidth + Self.numberToChevron + Self.chevronColumnWidth + Self.chevronToCode
        gutter.area.setSizeRequest(width: Int(total.rounded(.up)), height: -1)
    }

    private func drawGutter(on cr: UnsafeMutablePointer<cairo_t>) {
        let color = gutter.textColor
        let cursorLine = gutter.cursorLine
        let visible = gutter.visibleLines()
        for line in visible.lowerBound...min(visible.upperBound, buffer.lineCount - 1) where !isFoldedAway(line) {
            let row = gutter.rect(ofLine: line)
            drawNumber(line, isCursor: line == cursorLine, in: row, color: color, on: cr)
            if let fold = folds.first(where: { $0.startLine == line }) {
                drawChevron(for: fold, in: row, color: color, on: cr)
            }
        }
    }

    private func drawScopes(on cr: UnsafeMutablePointer<cairo_t>) {
        let color = layer.textColor
        let visible = layer.visibleLines()
        layer.clipToText(cr)
        for fold in folds where fold.startLine <= visible.upperBound && fold.endLine >= visible.lowerBound && !isFoldedAway(fold.startLine) {
            if collapsed.contains(fold.startLine) {
                drawPlaceholder(for: fold, color: color, on: cr)
            } else {
                drawGuide(for: fold, color: color, on: cr)
            }
        }
    }

    private func fold(atX x: Double, y: Double) -> CodeFold? {
        guard x >= chevronColumnStart else { return nil }
        return visibleFold(startingAt: gutter.line(atY: y, in: gutter.area))
    }

    private func toggle(line: Int) {
        if collapsed.contains(line) {
            collapsed.remove(line)
        } else {
            collapsed.insert(line)
        }
        applyCollapsed()
    }

    private func fadeOpenChevrons(to target: Double, over milliseconds: Int) {
        fade?.pause()
        let receiver = Unmanaged.passRetained(FadeReceiver(folding: self)).toOpaque()
        let animation = Adw.TimedAnimation(
            widget: gutter.area, from: openChevronAlpha, to: target, duration: milliseconds,
            target: Adw.CallbackAnimationTarget(callback: fadeStep, userData: receiver, destroy: releaseFadeReceiver))
        fade = animation
        animation.play()
    }

    fileprivate func setOpenChevronAlpha(_ alpha: Double) {
        openChevronAlpha = alpha
        gutter.queueDraw()
    }

    private func updatePointer(atX x: Double, y: Double) {
        if fold(atX: x, y: y) == nil {
            gtk_widget_set_cursor(gutter.area.widget_ptr, nil)
        } else {
            gtk_widget_set_cursor_from_name(gutter.area.widget_ptr, "pointer")
        }
    }

    private func drawNumber(_ line: Int, isCursor: Bool, in row: CGRect, color: GdkRGBA, on cr: UnsafeMutablePointer<cairo_t>) {
        let number = gutter.textLayout(markup: isCursor ? "<b>\(line + 1)</b>" : "\(line + 1)")
        defer { g_object_unref(number) }
        var width: gint = 0
        var height: gint = 0
        pango_layout_get_pixel_size(number, &width, &height)
        let alpha = isCursor ? 1 : Self.numberAlpha
        cairo_set_source_rgba(cr, Double(color.red), Double(color.green), Double(color.blue), Double(color.alpha) * alpha)
        cairo_move_to(cr, Self.numberLeading + numberWidth - Double(width), row.minY + (row.height - Double(height)) / 2)
        pango_cairo_show_layout(cr, number)
    }

    private func drawChevron(for fold: CodeFold, in row: CGRect, color: GdkRGBA, on cr: UnsafeMutablePointer<cairo_t>) {
        let isCollapsed = collapsed.contains(fold.startLine)
        let alpha = isCollapsed ? 1 : openChevronAlpha
        guard alpha > 0 else { return }
        let x = chevronColumnStart + Self.chevronColumnWidth / 2
        let y = row.midY
        if isCollapsed {
            cairo_move_to(cr, x - 1.75, y - 3.5)
            cairo_line_to(cr, x + 1.75, y)
            cairo_line_to(cr, x - 1.75, y + 3.5)
        } else {
            cairo_move_to(cr, x - 3.5, y - 1.75)
            cairo_line_to(cr, x, y + 1.75)
            cairo_line_to(cr, x + 3.5, y - 1.75)
        }
        cairo_set_source_rgba(cr, Double(color.red), Double(color.green), Double(color.blue), Self.chevronAlpha * alpha)
        cairo_set_line_width(cr, 1.5)
        cairo_set_line_cap(cr, Cairo.LineCap.round.value)
        cairo_set_line_join(cr, Cairo.LineJoin.round.value)
        cairo_stroke(cr)
    }

    private func drawPlaceholder(for fold: CodeFold, color: GdkRGBA, on cr: UnsafeMutablePointer<cairo_t>) {
        let opener = layer.rect(ofOffset: fold.hidden.lowerBound - 1)
        let width = Self.placeholderWidth
        let height = min(opener.height - 4, 14)
        let x = opener.maxX + Self.placeholderGap
        let y = opener.minY + (opener.height - height) / 2
        let radius = height / 2
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + width - radius, y + radius, radius, -.pi / 2, .pi / 2)
        cairo_arc(cr, x + radius, y + radius, radius, .pi / 2, 3 * .pi / 2)
        cairo_close_path(cr)
        cairo_set_source_rgba(cr, Double(color.red), Double(color.green), Double(color.blue), 0.12)
        cairo_fill(cr)
        cairo_set_source_rgba(cr, Double(color.red), Double(color.green), Double(color.blue), 0.6)
        for dot in -1...1 {
            cairo_new_sub_path(cr)
            cairo_arc(cr, x + width / 2 + Double(dot) * 4.5, y + height / 2, 1.3, 0, 2 * .pi)
        }
        cairo_fill(cr)
    }

    private func drawGuide(for fold: CodeFold, color: GdkRGBA, on cr: UnsafeMutablePointer<cairo_t>) {
        guard fold.endLine > fold.startLine + 1 else { return }
        let indent = layer.rect(ofOffset: fold.indentOffset)
        let end = layer.rect(ofOffset: fold.hidden.upperBound)
        let x = indent.minX.rounded() + 0.5
        cairo_set_source_rgba(cr, Double(color.red), Double(color.green), Double(color.blue), 0.18)
        cairo_set_line_width(cr, 1)
        cairo_move_to(cr, x, indent.maxY)
        cairo_line_to(cr, x, end.minY)
        cairo_stroke(cr)
    }

    private func isFoldedAway(_ line: Int) -> Bool {
        folds.contains { collapsed.contains($0.startLine) && line > $0.startLine && line < $0.endLine }
    }

    private var chevronColumnStart: Double {
        Self.numberLeading + numberWidth + Self.numberToChevron
    }

    private func visibleFold(startingAt line: Int) -> CodeFold? {
        guard !isFoldedAway(line) else { return nil }
        return folds.first { $0.startLine == line }
    }

    private func applyCollapsed() {
        let start = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let end = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            start.deallocate()
            end.deallocate()
        }
        gtk_text_buffer_get_bounds(buffer.text_buffer_ptr, start, end)
        gtk_text_buffer_remove_tag_by_name(buffer.text_buffer_ptr, Self.hiddenTag, start, end)
        for fold in folds where collapsed.contains(fold.startLine) {
            gtk_text_buffer_get_iter_at_offset(buffer.text_buffer_ptr, start, gint(fold.hidden.lowerBound))
            gtk_text_buffer_get_iter_at_offset(buffer.text_buffer_ptr, end, gint(fold.hidden.upperBound))
            gtk_text_buffer_apply_tag_by_name(buffer.text_buffer_ptr, Self.hiddenTag, start, end)
        }
        gutter.queueDraw()
        layer.queueDraw()
    }
}

private final class FadeReceiver {
    weak var folding: CodeFolding?

    init(folding: CodeFolding) {
        self.folding = folding
    }
}

private let fadeStep: AdwAnimationTargetFunc = { value, data in
    let receiver = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        let target = Unmanaged<FadeReceiver>.fromOpaque(UnsafeRawPointer(bitPattern: receiver)!).takeUnretainedValue()
        target.folding?.setOpenChevronAlpha(value)
    }
}

private let releaseFadeReceiver: GDestroyNotify = { data in
    Unmanaged<FadeReceiver>.fromOpaque(data!).release()
}

struct CodeFold {
    let startLine: Int
    let endLine: Int
    let indentOffset: Int
    let hidden: Swift.Range<Int>

    static func folds(from ranges: [LSP.FoldingRange], in text: String) -> [CodeFold] {
        let map = LineMap(text: text)
        let offsets = CharacterOffsets(text: text)
        let units = Array(text.utf16)
        return ranges.compactMap { range in
            var start = map.utf16Offset(of: LSP.Position(line: range.startLine, character: range.startCharacter ?? 0))
            var end = map.utf16Offset(of: LSP.Position(line: range.endLine, character: range.endCharacter ?? 0))
            if range.startCharacter == nil {
                start = map.utf16Offset(of: LSP.Position(line: range.startLine + 1, character: 0)) - 1
            }
            if range.endCharacter == nil {
                end = map.utf16Offset(of: LSP.Position(line: range.endLine + 1, character: 0)) - 1
            }
            if start < units.count, openers.contains(units[start]) {
                start += 1
            }
            if end > 0, end <= units.count, closers.contains(units[end - 1]) {
                end -= 1
            }
            guard end > start else { return nil }
            var indent = map.utf16Offset(of: LSP.Position(line: range.startLine, character: 0))
            while indent < start, units[indent] == 0x20 || units[indent] == 0x09 {
                indent += 1
            }
            return CodeFold(
                startLine: range.startLine, endLine: range.endLine, indentOffset: offsets.characterOffset(ofUTF16: indent),
                hidden: offsets.characterOffset(ofUTF16: start)..<offsets.characterOffset(ofUTF16: end))
        }
    }

    private static let openers: Set<UTF16.CodeUnit> = [0x7B, 0x28, 0x5B]
    private static let closers: Set<UTF16.CodeUnit> = [0x7D, 0x29, 0x5D]
}
