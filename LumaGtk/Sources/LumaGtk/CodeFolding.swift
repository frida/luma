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
    private let chevrons = FoldChevronRenderer()
    private var folds: [CodeFold] = []
    private var collapsed: Set<Int> = []
    private var openChevronAlpha = 0.0
    private var fade: Adw.TimedAnimation?

    private static let chevronColumnWidth = 14
    private static let chevronToCode = 2
    private static let chevronAlpha = 0.6
    private static let fadeIn = 150
    private static let fadeOut = 400
    private static let placeholderWidth = 22.0
    private static let placeholderGap = 4.0

    init(editor: GtkSource.View, buffer: GtkSource.Buffer) {
        self.buffer = buffer
        layer = TextLayer(editor: editor, buffer: buffer)
        _ = luma_text_buffer_create_hidden_tag(buffer.ptr, Self.hiddenTag)

        chevrons.folding = self
        installChevrons(in: editor)
        installPlaceholderInteraction(on: editor)
        layer.onDraw = { [weak self] cr in self?.drawScopes(on: cr) }
    }

    func setRanges(_ ranges: [LSP.FoldingRange], in text: String) {
        folds = CodeFold.folds(from: ranges.filter { $0.endLine > $0.startLine }, in: text)
        collapsed.formIntersection(folds.map(\.startLine))
        applyCollapsed()
    }

    func textChanged() {
        layer.queueDraw()
    }

    private func installChevrons(in editor: GtkSource.View) {
        let gutter = editor.getGutter(windowType: .left)!
        _ = gutter.insert(renderer: GutterRendererRef(chevrons.handle), position: 1)
        chevronsWidget.setSizeRequest(width: Self.chevronColumnWidth + Self.chevronToCode, height: -1)

        let gutterHover = EventControllerMotion()
        gutterHover.onEnter { [weak self] _, _, _ in
            MainActor.assumeIsolated { self?.fadeOpenChevrons(to: 1, over: Self.fadeIn) }
        }
        gutterHover.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOpenChevrons(to: 0, over: Self.fadeOut) }
        }
        gutter.add(controller: gutterHover)

        let chevronHover = EventControllerMotion()
        chevronHover.onEnter { [weak self] _, _, y in
            MainActor.assumeIsolated { self?.updatePointer(atY: y) }
        }
        chevronHover.onMotion { [weak self] _, _, y in
            MainActor.assumeIsolated { self?.updatePointer(atY: y) }
        }
        chevronsWidget.add(controller: chevronHover)
    }

    private func installPlaceholderInteraction(on editor: GtkSource.View) {
        let click = GestureClick()
        click.propagationPhase = .capture
        click.onPressed { [weak self] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let self, let fold = self.collapsedFold(atPlaceholder: self.layer.point(fromEditorX: x, y: y)) else { return }
                _ = gesture.set(state: .claimed)
                self.toggle(line: fold.startLine)
            }
        }
        editor.add(controller: click)

        let hover = EventControllerMotion()
        hover.onMotion { [weak self, weak editor] _, x, y in
            MainActor.assumeIsolated {
                guard let self, let editor else { return }
                let overPlaceholder = self.collapsedFold(atPlaceholder: self.layer.point(fromEditorX: x, y: y)) != nil
                editor.setCursorFrom(name: overPlaceholder ? "pointer" : "text")
            }
        }
        editor.add(controller: hover)
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

    private func fadeOpenChevrons(to target: Double, over milliseconds: Int) {
        fade?.pause()
        let receiver = Unmanaged.passRetained(FadeReceiver(folding: self)).toOpaque()
        let animation = Adw.TimedAnimation(
            widget: chevronsWidget, from: openChevronAlpha, to: target, duration: milliseconds,
            target: Adw.CallbackAnimationTarget(callback: fadeStep, userData: receiver, destroy: releaseFadeReceiver))
        fade = animation
        animation.play()
    }

    fileprivate func setOpenChevronAlpha(_ alpha: Double) {
        openChevronAlpha = alpha
        chevronsWidget.queueDraw()
    }

    private func updatePointer(atY y: Double) {
        let line = layer.line(atY: y, in: chevronsWidget)
        chevronsWidget.setCursorFrom(name: startsFold(line: line) && !isFoldedAway(line) ? "pointer" : nil)
    }

    private func collapsedFold(atPlaceholder point: CGPoint) -> CodeFold? {
        folds.first { collapsed.contains($0.startLine) && !isFoldedAway($0.startLine) && placeholderRect(for: $0).contains(point) }
    }

    fileprivate func toggle(line: Int) {
        if collapsed.contains(line) {
            collapsed.remove(line)
        } else {
            collapsed.insert(line)
        }
        applyCollapsed()
    }

    fileprivate func startsFold(line: Int) -> Bool {
        folds.contains { $0.startLine == line }
    }

    fileprivate func snapshotChevron(onLine line: Int, lines: GutterLinesRef, snapshot: UnsafeMutablePointer<GtkSnapshot>) {
        guard startsFold(line: line) else { return }
        let isCollapsed = collapsed.contains(line)
        let alpha = isCollapsed ? 1 : openChevronAlpha
        guard alpha > 0 else { return }
        var top: gint = 0
        var height: gint = 0
        lines.getLineYrange(line: line, mode: .cell, y: &top, height: &height)
        guard height > 0 else { return }
        var cell = graphene_rect_t(
            origin: graphene_point_t(x: 0, y: Float(top)),
            size: graphene_size_t(width: Float(chevronsWidget.width), height: Float(height)))
        let cr = gtk_snapshot_append_cairo(snapshot, &cell)!
        defer { cairo_destroy(cr) }
        drawChevron(collapsed: isCollapsed, alpha: alpha, centeredAt: CGPoint(x: Double(Self.chevronColumnWidth) / 2, y: Double(top) + Double(height) / 2), on: cr)
    }

    private func drawChevron(collapsed isCollapsed: Bool, alpha: Double, centeredAt center: CGPoint, on cr: UnsafeMutablePointer<cairo_t>) {
        var color = GdkRGBA()
        gtk_widget_get_color(chevronsWidget.widget_ptr, &color)
        let (x, y) = (center.x, center.y)
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
        let pill = placeholderRect(for: fold)
        let (x, y, width, height) = (pill.minX, pill.minY, pill.width, pill.height)
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

    private func placeholderRect(for fold: CodeFold) -> CGRect {
        let opener = layer.rect(ofOffset: fold.hidden.lowerBound - 1)
        let height = min(opener.height - 4, 14)
        return CGRect(
            x: opener.maxX + Self.placeholderGap, y: opener.minY + (opener.height - height) / 2,
            width: Self.placeholderWidth, height: height)
    }

    private func isFoldedAway(_ line: Int) -> Bool {
        folds.contains { collapsed.contains($0.startLine) && line > $0.startLine && line < $0.endLine }
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
        chevronsWidget.queueDraw()
        layer.queueDraw()
    }

    private var chevronsWidget: WidgetRef {
        WidgetRef(raw: chevrons.handle)
    }
}

@MainActor
private final class FoldChevronRenderer: GutterRendererSubclass {
    weak var folding: CodeFolding?

    override func activate(
        iter: UnsafeMutablePointer<GtkTextIter>?, area: UnsafeMutablePointer<GdkRectangle>?, button: guint, state: GdkModifierType,
        nPresses: gint
    ) {
        folding?.toggle(line: Int(gtk_text_iter_get_line(iter)))
    }

    override func queryActivatable(iter: UnsafeMutablePointer<GtkTextIter>?, area: UnsafeMutablePointer<GdkRectangle>?) -> gboolean {
        folding?.startsFold(line: Int(gtk_text_iter_get_line(iter))) == true ? 1 : 0
    }

    override func snapshotLine(snapshot: UnsafeMutablePointer<GtkSnapshot>?, lines: UnsafeMutablePointer<GtkSourceGutterLines>?, line: guint) {
        folding?.snapshotChevron(onLine: Int(line), lines: GutterLinesRef(lines!), snapshot: snapshot!)
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
