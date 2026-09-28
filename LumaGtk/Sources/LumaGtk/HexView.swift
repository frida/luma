import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk

@MainActor
public final class HexView {
    public let widget: ScrolledWindow

    private let surface: Overlay
    private let selectionLayer: Fixed
    private let selectionBands: [Box]
    private let bytesArea: DrawingArea

    private var bytes: [UInt8]
    private var baseAddress: UInt64
    private var layout: HexLayout
    private var selection: Selection?

    public init(bytes: Data, baseAddress: UInt64 = 0) {
        self.bytes = Array(bytes)
        self.baseAddress = baseAddress
        layout = HexLayout(byteCount: self.bytes.count, baseAddress: baseAddress)

        selectionLayer = Fixed()
        selectionLayer.canTarget = false
        selectionBands = (0..<HexLayout.maxSelectionBands).map { _ in
            let band = Box(orientation: .horizontal, spacing: 0)
            band.add(cssClass: "luma-hex-selection")
            band.visible = false
            return band
        }
        for band in selectionBands {
            selectionLayer.put(widget: band, x: 0, y: 0)
        }

        bytesArea = DrawingArea()
        bytesArea.canTarget = false

        surface = Overlay()
        surface.hexpand = true
        surface.vexpand = true
        surface.focusable = true
        surface.canFocus = true
        surface.set(child: selectionLayer)
        surface.addOverlay(widget: bytesArea)

        widget = ScrolledWindow()
        widget.hexpand = true
        widget.vexpand = false
        widget.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .never)
        widget.propagateNaturalHeight = true
        widget.set(child: surface)

        bytesArea.setDrawFunc { [weak self] _, ctx, _, _ in
            MainActor.assumeIsolated {
                self?.drawBytes(ctx: ctx)
            }
        }

        installGestures()
        installKeyController()
        applyContentSize()
    }

    public func setBytes(_ bytes: Data, baseAddress: UInt64 = 0) {
        self.bytes = Array(bytes)
        self.baseAddress = baseAddress
        layout = HexLayout(byteCount: self.bytes.count, baseAddress: baseAddress)
        selection = nil
        applyContentSize()
        bytesArea.queueDraw()
        showSelection()
    }

    private func drawBytes(ctx: Cairo.ContextRef) {
        HexMetrics.selectFont(on: ctx._ptr)

        if bytes.isEmpty {
            ctx.setSource(red: 0.6, green: 0.6, blue: 0.6, alpha: 0.8)
            ctx.moveTo(HexLayout.marginX, layout.baseline(ofRow: 0))
            "(no data)".withCString { ctx.showText($0) }
            return
        }

        var runs = GlyphRuns()
        for row in 0..<layout.rowCount {
            runs.removeAll()
            collectGlyphs(ofRow: row, into: &runs)
            runs.show(on: ctx._ptr)
        }
    }

    private func collectGlyphs(ofRow row: Int, into runs: inout GlyphRuns) {
        let baseline = layout.baseline(ofRow: row)
        let start = row * HexLayout.bytesPerRow
        let rowBytes = bytes[start..<min(start + HexLayout.bytesPerRow, bytes.count)]

        let address = layout.formatAddress(baseAddress &+ UInt64(start))
        for (column, digit) in zip(0..., address.utf8) {
            runs.append(layout.glyph(digit, atColumn: column, baseline: baseline), style: .address)
        }

        for (index, byte) in zip(0..., rowBytes) {
            let hexColumn = layout.hexStartColumn + index * HexLayout.hexCellColumns
            let style = GlyphStyle(classifying: byte)
            runs.append(layout.glyph(HexLayout.hexDigits[Int(byte >> 4)], atColumn: hexColumn, baseline: baseline), style: style)
            runs.append(layout.glyph(HexLayout.hexDigits[Int(byte & 0xf)], atColumn: hexColumn + 1, baseline: baseline), style: style)
            runs.append(layout.glyph(HexLayout.asciiCode(for: byte), atColumn: layout.asciiStartColumn + index, baseline: baseline), style: .ascii)
        }
    }

    private func installGestures() {
        let drag = GestureDrag()
        drag.set(button: 1)
        drag.onDragBegin { [weak self] _, x, y in
            MainActor.assumeIsolated {
                self?.beginDrag(atX: x, y: y)
            }
        }
        drag.onDragUpdate { [weak self] gesture, offsetX, offsetY in
            MainActor.assumeIsolated {
                self?.continueDrag(gesture, offsetX: offsetX, offsetY: offsetY)
            }
        }
        surface.install(controller: drag)

        let rightClick = GestureClick()
        rightClick.set(button: 3)
        rightClick.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated {
                self?.presentContextMenu(atX: x, y: y)
            }
        }
        surface.install(controller: rightClick)
    }

    private func beginDrag(atX x: Double, y: Double) {
        _ = surface.grabFocus()
        guard let index = byteIndex(atX: x, y: y) else { return }
        select(anchor: index, caret: index)
    }

    private func continueDrag(_ gesture: GestureDragRef, offsetX: Double, offsetY: Double) {
        var startX = 0.0
        var startY = 0.0
        _ = gesture.getStartPoint(x: &startX, y: &startY)
        guard let anchor = byteIndex(atX: startX, y: startY),
            let caret = byteIndex(atX: startX + offsetX, y: startY + offsetY)
        else { return }
        select(anchor: anchor, caret: caret)
    }

    private func presentContextMenu(atX x: Double, y: Double) {
        guard !bytes.isEmpty else { return }
        if let index = byteIndex(atX: x, y: y), selection?.range.contains(index) != true {
            select(anchor: index, caret: index)
        }
        ContextMenu.present([
            [
                .init("Copy Hex") { [weak self] in self?.copySelection(.hex) },
                .init("Copy ASCII") { [weak self] in self?.copySelection(.ascii) },
                .init("Copy Base64") { [weak self] in self?.copySelection(.base64) },
            ],
        ], at: surface, x: x, y: y)
    }

    private func installKeyController() {
        let key = EventControllerKey()
        key.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                self?.handleKey(keyval: keyval, state: state) ?? false
            }
        }
        surface.install(controller: key)
    }

    private func handleKey(keyval: UInt, state: Gdk.ModifierType) -> Bool {
        guard !bytes.isEmpty, let motion = caretMotion(for: Int32(truncatingIfNeeded: keyval)) else { return false }
        moveCaret(rows: motion.rows, columns: motion.columns, extending: state.contains(.shiftMask))
        return true
    }

    private func caretMotion(for keyval: Int32) -> (rows: Int, columns: Int)? {
        switch keyval {
        case Gdk.keyLeft, Gdk.keyh, Gdk.keyH: (0, -1)
        case Gdk.keyRight, Gdk.keyl, Gdk.keyL: (0, 1)
        case Gdk.keyUp, Gdk.keyk, Gdk.keyK: (-1, 0)
        case Gdk.keyDown, Gdk.keyj, Gdk.keyJ: (1, 0)
        default: nil
        }
    }

    private func moveCaret(rows: Int, columns: Int, extending: Bool) {
        let caret = selection?.caret ?? 0
        let row = min(max(caret / HexLayout.bytesPerRow + rows, 0), layout.rowCount - 1)
        let column = min(max(caret % HexLayout.bytesPerRow + columns, 0), HexLayout.bytesPerRow - 1)
        let newCaret = min(row * HexLayout.bytesPerRow + column, bytes.count - 1)
        select(anchor: extending ? selection?.anchor ?? 0 : newCaret, caret: newCaret)
    }

    private func applyContentSize() {
        let width = Int(layout.contentWidth.rounded(.up))
        selectionLayer.setSizeRequest(width: width, height: max(40, Int(layout.contentHeight.rounded(.up))))
        widget.setSizeRequest(width: width, height: -1)
    }

    private func byteIndex(atX x: Double, y: Double) -> Int? {
        guard let index = layout.byteIndex(atX: x, y: y) else { return nil }
        return min(index, bytes.count - 1)
    }

    private func select(anchor: Int, caret: Int) {
        selection = Selection(anchor: anchor, caret: caret)
        showSelection()
    }

    private func showSelection() {
        let bands = selection.map { layout.selectionBands(covering: $0.range) } ?? []
        for (band, rect) in zip(selectionBands, bands) {
            place(band, over: rect)
        }
        for band in selectionBands.dropFirst(bands.count) {
            band.visible = false
        }
    }

    private func place(_ band: Box, over rect: CGRect) {
        let pixelRect = rect.integral
        band.visible = true
        selectionLayer.move(widget: band, x: pixelRect.minX, y: pixelRect.minY)
        band.setSizeRequest(width: Int(pixelRect.width), height: Int(pixelRect.height))
    }

    private enum CopyFormat { case hex, ascii, base64 }

    private func copySelection(_ format: CopyFormat) {
        let slice = bytes[selection?.range ?? 0...(bytes.count - 1)]
        let text: String
        switch format {
        case .hex:
            text = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .ascii:
            text = String(decoding: slice.map(HexLayout.asciiCode), as: UTF8.self)
        case .base64:
            text = Data(slice).base64EncodedString()
        }
        Display.getDefault()?.clipboard.set(text: text)
    }

    private struct Selection {
        var anchor: Int
        var caret: Int

        var range: ClosedRange<Int> { min(anchor, caret)...max(anchor, caret) }
    }
}

@MainActor
private struct HexLayout {
    let rowCount: Int
    let addressDigits: Int

    static let bytesPerRow = 16
    static let maxSelectionBands = 6
    static let hexCellColumns = 3
    static let sectionGapColumns = 3
    static let marginX = 8.0
    static let marginY = 6.0
    static let hexDigits = Array("0123456789ABCDEF".utf8)

    private let metrics = HexMetrics.shared

    init(byteCount: Int, baseAddress: UInt64) {
        rowCount = (byteCount + Self.bytesPerRow - 1) / Self.bytesPerRow
        let lastRowAddress = baseAddress &+ UInt64(max(rowCount - 1, 0) * Self.bytesPerRow)
        addressDigits = max(8, String(lastRowAddress, radix: 16).count)
    }

    var hexStartColumn: Int { addressDigits + Self.sectionGapColumns }

    var asciiStartColumn: Int { hexStartColumn + hexColumnCount + Self.sectionGapColumns }

    private var hexColumnCount: Int { Self.bytesPerRow * Self.hexCellColumns - 1 }

    var contentWidth: Double { Self.marginX * 2 + Double(asciiStartColumn + Self.bytesPerRow) * metrics.advance }

    var contentHeight: Double { Self.marginY * 2 + Double(rowCount) * metrics.rowHeight }

    func formatAddress(_ address: UInt64) -> String {
        let hex = String(address, radix: 16, uppercase: true)
        return String(repeating: "0", count: addressDigits - hex.count) + hex
    }

    func baseline(ofRow row: Int) -> Double {
        top(ofRow: row) + metrics.baselineOffset
    }

    func glyph(_ code: UInt8, atColumn column: Int, baseline: Double) -> cairo_glyph_t {
        cairo_glyph_t(index: metrics.glyphIndex(for: code), x: x(ofColumn: column), y: baseline)
    }

    func selectionBands(covering range: ClosedRange<Int>) -> [CGRect] {
        let first = (row: range.lowerBound / Self.bytesPerRow, column: range.lowerBound % Self.bytesPerRow)
        let last = (row: range.upperBound / Self.bytesPerRow, column: range.upperBound % Self.bytesPerRow)
        if first.row == last.row {
            return bands(rows: first.row...first.row, columns: first.column...last.column)
        }
        var bands = bands(rows: first.row...first.row, columns: first.column...(Self.bytesPerRow - 1))
        if last.row - first.row > 1 {
            bands += self.bands(rows: (first.row + 1)...(last.row - 1), columns: 0...(Self.bytesPerRow - 1))
        }
        bands += self.bands(rows: last.row...last.row, columns: 0...last.column)
        return bands
    }

    func byteIndex(atX x: Double, y: Double) -> Int? {
        guard y >= Self.marginY else { return nil }
        let row = Int((y - Self.marginY) / metrics.rowHeight)
        guard row < rowCount, let column = byteColumn(atX: x) else { return nil }
        return row * Self.bytesPerRow + column
    }

    private func bands(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> [CGRect] {
        let top = top(ofRow: rows.lowerBound)
        let height = Double(rows.count) * metrics.rowHeight
        let hexFirst = Double(hexStartColumn + columns.lowerBound * Self.hexCellColumns) - 0.5
        let hexLast = Double(hexStartColumn + columns.upperBound * Self.hexCellColumns) + 2.5
        let asciiFirst = Double(asciiStartColumn + columns.lowerBound)
        let asciiLast = Double(asciiStartColumn + columns.upperBound + 1)
        return [
            CGRect(x: x(ofColumn: hexFirst), y: top, width: (hexLast - hexFirst) * metrics.advance, height: height),
            CGRect(x: x(ofColumn: asciiFirst), y: top, width: (asciiLast - asciiFirst) * metrics.advance, height: height),
        ]
    }

    private func byteColumn(atX x: Double) -> Int? {
        let column = (x - Self.marginX) / metrics.advance
        let hexStart = Double(hexStartColumn)
        let hexEnd = hexStart + Double(hexColumnCount)
        let asciiStart = Double(asciiStartColumn)
        let asciiEnd = asciiStart + Double(Self.bytesPerRow)

        if (hexStart..<hexEnd).contains(column) {
            let cellCenteredColumn = column - hexStart + 0.5
            return Int(cellCenteredColumn) / Self.hexCellColumns
        }
        if (asciiStart..<asciiEnd).contains(column) {
            return Int(column - asciiStart)
        }
        return nil
    }

    private func top(ofRow row: Int) -> Double {
        Self.marginY + Double(row) * metrics.rowHeight
    }

    private func x(ofColumn column: Int) -> Double {
        x(ofColumn: Double(column))
    }

    private func x(ofColumn column: Double) -> Double {
        Self.marginX + column * metrics.advance
    }

    static func asciiCode(for byte: UInt8) -> UInt8 {
        (0x20...0x7E).contains(byte) ? byte : UInt8(ascii: ".")
    }
}

private enum GlyphStyle: Int, CaseIterable {
    case address
    case zero
    case printable
    case control
    case high
    case ascii

    init(classifying byte: UInt8) {
        switch byte {
        case 0x00: self = .zero
        case 0x20...0x7E: self = .printable
        case 0x01...0x1F, 0x7F: self = .control
        default: self = .high
        }
    }

    var color: (red: Double, green: Double, blue: Double, alpha: Double) {
        switch self {
        case .address: (0.36, 0.78, 0.43, 0.9)
        case .zero: (0.55, 0.55, 0.58, 1.0)
        case .printable: (0.36, 0.82, 0.66, 1.0)
        case .control: (0.95, 0.65, 0.2, 1.0)
        case .high: (0.35, 0.78, 0.92, 1.0)
        case .ascii: (0.72, 0.72, 0.75, 1.0)
        }
    }
}

private struct GlyphRuns {
    private var glyphs = Array(repeating: [cairo_glyph_t](), count: GlyphStyle.allCases.count)

    mutating func append(_ glyph: cairo_glyph_t, style: GlyphStyle) {
        glyphs[style.rawValue].append(glyph)
    }

    mutating func removeAll() {
        for style in GlyphStyle.allCases {
            glyphs[style.rawValue].removeAll(keepingCapacity: true)
        }
    }

    func show(on cr: UnsafeMutablePointer<cairo_t>) {
        for style in GlyphStyle.allCases where !glyphs[style.rawValue].isEmpty {
            let color = style.color
            cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha)
            glyphs[style.rawValue].withUnsafeBufferPointer {
                cairo_show_glyphs(cr, $0.baseAddress, Int32($0.count))
            }
        }
    }
}

@MainActor
private struct HexMetrics {
    let advance: Double
    let rowHeight: Double
    let baselineOffset: Double
    private let glyphIndices: [CUnsignedLong]

    static let shared = HexMetrics()

    private static let fontSize = 12.0
    private static let rowGap = 2.0
    #if os(Windows)
        private static let family = "Consolas"
    #else
        private static let family = "monospace"
    #endif

    private init() {
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1)
        let cr = cairo_create(surface)!
        defer {
            cairo_destroy(cr)
            cairo_surface_destroy(surface)
        }
        Self.selectFont(on: cr)

        var fontExtents = cairo_font_extents_t()
        cairo_font_extents(cr, &fontExtents)
        var digitExtents = cairo_text_extents_t()
        cairo_text_extents(cr, "0", &digitExtents)

        advance = digitExtents.x_advance
        rowHeight = (fontExtents.ascent + fontExtents.descent).rounded(.up) + Self.rowGap
        baselineOffset = Self.rowGap / 2 + fontExtents.ascent
        glyphIndices = Self.printableGlyphIndices(in: cairo_get_scaled_font(cr))
    }

    static func selectFont(on cr: UnsafeMutablePointer<cairo_t>) {
        cairo_select_font_face(cr, family, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, fontSize)
    }

    func glyphIndex(for code: UInt8) -> CUnsignedLong {
        glyphIndices[Int(code)]
    }

    private static func printableGlyphIndices(in font: UnsafeMutablePointer<cairo_scaled_font_t>) -> [CUnsignedLong] {
        let printable = String(decoding: 0x20...0x7E, as: UTF8.self)
        var glyphs: UnsafeMutablePointer<cairo_glyph_t>?
        var glyphCount: Int32 = 0
        cairo_scaled_font_text_to_glyphs(font, 0, 0, printable, Int32(printable.utf8.count), &glyphs, &glyphCount, nil, nil, nil)
        defer { cairo_glyph_free(glyphs) }

        var indices = [CUnsignedLong](repeating: 0, count: 0x80)
        for (code, glyph) in zip(0x20..., UnsafeBufferPointer(start: glyphs, count: Int(glyphCount))) {
            indices[code] = glyph.index
        }
        return indices
    }
}
