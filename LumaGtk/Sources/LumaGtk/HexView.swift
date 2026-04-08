import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk

@MainActor
public final class HexView {
    public let widget: ScrolledWindow

    private let scroll: ScrolledWindow
    private let drawingArea: DrawingArea

    private var bytes: [UInt8] = []
    private var baseAddress: UInt64 = 0

    private var selection: ClosedRange<Int>?
    private var caretIndex: Int?
    private var dragStartIndex: Int?

    private let bytesPerRow: Int = 16
    private let fontSize: Double = 12
    private let marginX: Double = 8
    private let marginY: Double = 6
    private let hexSpacing: Double = 2
    private let groupSpacing: Double = 20
    private let rowExtraSpacing: Double = 2

    private var cellWidth: Double = 8
    private var cellHeight: Double = 14
    private var asciiCellWidth: Double = 8
    private var offsetColumnWidth: Double = 80
    private var rowHeight: Double = 16
    private var metricsReady: Bool = false

    public init(bytes: Data, baseAddress: UInt64 = 0) {
        self.bytes = Array(bytes)
        self.baseAddress = baseAddress

        let area = DrawingArea()
        area.hexpand = true
        area.vexpand = true
        area.focusable = true
        area.canFocus = true
        self.drawingArea = area

        let sw = ScrolledWindow()
        sw.hexpand = true
        sw.vexpand = false
        sw.setPolicy(hscrollbarPolicy: GTK_POLICY_NEVER, vscrollbarPolicy: GTK_POLICY_NEVER)
        sw.propagateNaturalHeight = true
        sw.set(child: WidgetRef(area.widget_ptr))
        self.scroll = sw
        self.widget = sw

        area.setDrawFunc { [weak self] _, ctx, _, _ in
            MainActor.assumeIsolated {
                self?.draw(ctx: ctx)
            }
        }

        installGestures()
        installKeyController()
        recomputeContentSize()
    }

    public func setBytes(_ bytes: Data, baseAddress: UInt64 = 0) {
        self.bytes = Array(bytes)
        self.baseAddress = baseAddress
        selection = nil
        caretIndex = nil
        dragStartIndex = nil
        recomputeContentSize()
        drawingArea.queueDraw()
    }

    // MARK: - Metrics

    private func ensureMetrics(ctx: Cairo.ContextRef) {
        if metricsReady { return }
        configureFont(ctx: ctx)
        let sample = "00".withCString { p -> cairo_text_extents_t in
            ctx.textExtents(p)
        }
        cellWidth = max(sample.x_advance, sample.width)
        let ascii = "M".withCString { p -> cairo_text_extents_t in
            ctx.textExtents(p)
        }
        asciiCellWidth = max(ascii.x_advance, ascii.width)
        cellHeight = max(sample.height, ascii.height)
        rowHeight = cellHeight + rowExtraSpacing + 4
        let offsetSample = "00000000".withCString { p -> cairo_text_extents_t in
            ctx.textExtents(p)
        }
        offsetColumnWidth = max(offsetSample.x_advance, offsetSample.width) + 4
        metricsReady = true
    }

    private func configureFont(ctx: Cairo.ContextRef) {
        "monospace".withCString { p in
            ctx.selectFontFace(p, slant: .normal, weight: .normal)
        }
        ctx.fontSize = fontSize
    }

    private func recomputeContentSize() {
        let rows = max(1, (bytes.count + bytesPerRow - 1) / bytesPerRow)
        let width = Int(
            ceil(
                marginX * 2 + offsetColumnWidth + groupSpacing
                    + Double(bytesPerRow) * cellWidth + Double(bytesPerRow - 1) * hexSpacing
                    + groupSpacing + Double(bytesPerRow) * asciiCellWidth
            )
        ) + 8
        let height = Int(marginY * 2 + Double(rows) * rowHeight)
        drawingArea.contentWidth = width
        drawingArea.contentHeight = max(40, height)
        scroll.setSizeRequest(width: width, height: -1)
    }

    // MARK: - Hit testing

    private func byteIndex(at x: Double, y: Double) -> Int? {
        guard !bytes.isEmpty, rowHeight > 0 else { return nil }
        let relY = y - marginY
        if relY < 0 { return nil }
        let row = Int(relY / rowHeight)
        let rowStart = row * bytesPerRow
        if rowStart >= bytes.count { return nil }
        let rowLen = min(bytesPerRow, bytes.count - rowStart)

        let hexStart = marginX + offsetColumnWidth + groupSpacing
        let hexStride = cellWidth + hexSpacing
        let hexEnd = hexStart + Double(rowLen) * cellWidth + Double(max(0, rowLen - 1)) * hexSpacing

        let asciiStart = hexStart + Double(bytesPerRow) * cellWidth
            + Double(bytesPerRow - 1) * hexSpacing + groupSpacing
        let asciiEnd = asciiStart + Double(rowLen) * asciiCellWidth

        if x >= hexStart && x <= hexEnd {
            var col = Int((x - hexStart) / hexStride)
            col = max(0, min(rowLen - 1, col))
            return rowStart + col
        }
        if x >= asciiStart && x <= asciiEnd {
            var col = Int((x - asciiStart) / asciiCellWidth)
            col = max(0, min(rowLen - 1, col))
            return rowStart + col
        }
        return nil
    }

    // MARK: - Drawing

    private func draw(ctx: Cairo.ContextRef) {
        let wasReady = metricsReady
        ensureMetrics(ctx: ctx)
        if !wasReady {
            recomputeContentSize()
        }
        configureFont(ctx: ctx)

        if bytes.isEmpty {
            ctx.setSource(red: 0.6, green: 0.6, blue: 0.6, alpha: 0.8)
            ctx.moveTo(marginX, marginY + cellHeight)
            "(no data)".withCString { ctx.showText($0) }
            return
        }

        let rows = (bytes.count + bytesPerRow - 1) / bytesPerRow
        let hexStart = marginX + offsetColumnWidth + groupSpacing
        let asciiStart = hexStart + Double(bytesPerRow) * cellWidth
            + Double(bytesPerRow - 1) * hexSpacing + groupSpacing

        // Selection background pass
        if let range = selection {
            ctx.setSource(red: 0.22, green: 0.47, blue: 0.93, alpha: 0.30)
            for idx in range {
                if idx >= bytes.count { break }
                let r = idx / bytesPerRow
                let c = idx % bytesPerRow
                let y = marginY + Double(r) * rowHeight
                let hx = hexStart + Double(c) * (cellWidth + hexSpacing) - 1
                ctx.rectangle(x: hx, y: y, width: cellWidth + 2, height: rowHeight - 1)
                ctx.fill()
                let ax = asciiStart + Double(c) * asciiCellWidth
                ctx.rectangle(x: ax, y: y, width: asciiCellWidth, height: rowHeight - 1)
                ctx.fill()
            }
        }

        for row in 0..<rows {
            let rowStart = row * bytesPerRow
            let rowLen = min(bytesPerRow, bytes.count - rowStart)
            let baseline = marginY + Double(row) * rowHeight + cellHeight

            // Offset
            ctx.setSource(red: 0.36, green: 0.78, blue: 0.43, alpha: 0.9)
            ctx.moveTo(marginX, baseline)
            String(format: "%08X", Int(baseAddress) + rowStart).withCString { ctx.showText($0) }

            // Hex bytes
            for col in 0..<rowLen {
                let byte = bytes[rowStart + col]
                let (r, g, b) = color(for: byte)
                ctx.setSource(red: r, green: g, blue: b, alpha: 1.0)
                let x = hexStart + Double(col) * (cellWidth + hexSpacing)
                ctx.moveTo(x, baseline)
                String(format: "%02X", byte).withCString { ctx.showText($0) }
            }

            // ASCII
            ctx.setSource(red: 0.72, green: 0.72, blue: 0.75, alpha: 1.0)
            for col in 0..<rowLen {
                let byte = bytes[rowStart + col]
                let ch: Character =
                    (0x20...0x7E).contains(byte)
                    ? Character(UnicodeScalar(byte)) : "."
                let x = asciiStart + Double(col) * asciiCellWidth
                ctx.moveTo(x, baseline)
                String(ch).withCString { ctx.showText($0) }
            }
        }
    }

    private func color(for byte: UInt8) -> (Double, Double, Double) {
        switch byte {
        case 0x00:
            return (0.55, 0.55, 0.58)
        case 0x20...0x7E:
            return (0.36, 0.82, 0.66)
        case 0x01...0x1F, 0x7F:
            return (0.95, 0.65, 0.2)
        default:
            return (0.35, 0.78, 0.92)
        }
    }

    // MARK: - Selection

    private func setSelection(anchor: Int, to end: Int) {
        let clampedEnd = max(0, min(bytes.count - 1, end))
        let clampedAnchor = max(0, min(bytes.count - 1, anchor))
        let lower = min(clampedAnchor, clampedEnd)
        let upper = max(clampedAnchor, clampedEnd)
        selection = lower...upper
        caretIndex = clampedEnd
        ensureCaretVisible()
        drawingArea.queueDraw()
    }

    private func moveCaret(rowDelta: Int, colDelta: Int, extend: Bool) {
        guard !bytes.isEmpty else { return }
        let current = caretIndex ?? 0
        let currentRow = current / bytesPerRow
        let currentCol = current % bytesPerRow

        var newRow = currentRow + rowDelta
        newRow = max(0, min(newRow, (bytes.count - 1) / bytesPerRow))

        let rowStart = newRow * bytesPerRow
        let rowLen = min(bytesPerRow, bytes.count - rowStart)

        var newCol = currentCol + colDelta
        newCol = max(0, min(newCol, rowLen - 1))

        let newIndex = rowStart + newCol

        if extend, let sel = selection {
            // Anchor at the opposite end of current caret
            let anchor = (caretIndex == sel.upperBound) ? sel.lowerBound : sel.upperBound
            setSelection(anchor: anchor, to: newIndex)
        } else {
            setSelection(anchor: newIndex, to: newIndex)
        }
    }

    private func ensureCaretVisible() {
        guard let caret = caretIndex else { return }
        guard let adj = scroll.vadjustment else { return }
        let row = caret / bytesPerRow
        let rowTop = marginY + Double(row) * rowHeight
        let rowBot = rowTop + rowHeight
        if rowTop < adj.value {
            adj.value = max(0, rowTop - rowHeight)
        } else if rowBot > adj.value + adj.pageSize {
            adj.value = min(adj.upper - adj.pageSize, rowBot - adj.pageSize + rowHeight)
        }
    }

    // MARK: - Gestures

    private func installGestures() {
        let leftClick = GestureClick()
        leftClick.set(button: 1)
        leftClick.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.drawingArea.grabFocus()
                if let idx = self.byteIndex(at: x, y: y) {
                    self.dragStartIndex = idx
                    self.setSelection(anchor: idx, to: idx)
                }
            }
        }
        drawingArea.install(controller: leftClick)

        let drag = GestureDrag()
        drag.set(button: 1)
        var startX: Double = 0
        var startY: Double = 0
        drag.onDragBegin { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                startX = x
                startY = y
                if let idx = self.byteIndex(at: x, y: y) {
                    self.dragStartIndex = idx
                    self.setSelection(anchor: idx, to: idx)
                }
            }
        }
        drag.onDragUpdate { [weak self] _, offX, offY in
            MainActor.assumeIsolated {
                guard let self else { return }
                let x = startX + offX
                let y = startY + offY
                if let cur = self.byteIndex(at: x, y: y), let anchor = self.dragStartIndex {
                    self.setSelection(anchor: anchor, to: cur)
                }
            }
        }
        drag.onDragEnd { [weak self] _, _, _ in
            MainActor.assumeIsolated {
                self?.dragStartIndex = nil
            }
        }
        drawingArea.install(controller: drag)

        let rightClick = GestureClick()
        rightClick.set(button: 3)
        rightClick.onPressed { [weak self] _, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let idx = self.byteIndex(at: x, y: y) {
                    if self.selection?.contains(idx) != true {
                        self.setSelection(anchor: idx, to: idx)
                    }
                }
                self.presentContextMenu(at: x, y: y)
            }
        }
        drawingArea.install(controller: rightClick)
    }

    private func installKeyController() {
        let key = EventControllerKey()
        key.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKey(keyval: keyval, state: state)
            }
        }
        drawingArea.install(controller: key)
    }

    private func handleKey(keyval: UInt, state: Gdk.ModifierType) -> Bool {
        guard !bytes.isEmpty else { return false }
        let extend = state.contains(.shiftMask)
        let k = Int32(keyval)
        if caretIndex == nil {
            caretIndex = 0
            selection = 0...0
        }
        switch k {
        case Gdk.keyLeft:
            moveCaret(rowDelta: 0, colDelta: -1, extend: extend); return true
        case Gdk.keyRight:
            moveCaret(rowDelta: 0, colDelta: 1, extend: extend); return true
        case Gdk.keyUp:
            moveCaret(rowDelta: -1, colDelta: 0, extend: extend); return true
        case Gdk.keyDown:
            moveCaret(rowDelta: 1, colDelta: 0, extend: extend); return true
        default:
            break
        }
        switch keyval {
        case 0x68, 0x48:  // h / H
            moveCaret(rowDelta: 0, colDelta: -1, extend: extend); return true
        case 0x6c, 0x4c:  // l / L
            moveCaret(rowDelta: 0, colDelta: 1, extend: extend); return true
        case 0x6b, 0x4b:  // k / K
            moveCaret(rowDelta: -1, colDelta: 0, extend: extend); return true
        case 0x6a, 0x4a:  // j / J
            moveCaret(rowDelta: 1, colDelta: 0, extend: extend); return true
        default:
            return false
        }
    }

    // MARK: - Context menu / copy

    private enum CopyFormat { case hex, ascii, base64 }

    private func presentContextMenu(at x: Double, y: Double) {
        guard !bytes.isEmpty else { return }

        let popover = Popover()
        popover.autohide = true

        let box = Box(orientation: .vertical, spacing: 2)
        box.add(cssClass: "luma-menu")
        box.marginStart = 6
        box.marginEnd = 6
        box.marginTop = 6
        box.marginBottom = 6

        let hexButton = Button(label: "Copy Hex")
        hexButton.add(cssClass: "flat")
        hexButton.onClicked { [weak self, popover] _ in
            MainActor.assumeIsolated {
                self?.copySelection(.hex)
                popover.popdown()
            }
        }
        box.append(child: hexButton)

        let asciiButton = Button(label: "Copy ASCII")
        asciiButton.add(cssClass: "flat")
        asciiButton.onClicked { [weak self, popover] _ in
            MainActor.assumeIsolated {
                self?.copySelection(.ascii)
                popover.popdown()
            }
        }
        box.append(child: asciiButton)

        let base64Button = Button(label: "Copy Base64")
        base64Button.add(cssClass: "flat")
        base64Button.onClicked { [weak self, popover] _ in
            MainActor.assumeIsolated {
                self?.copySelection(.base64)
                popover.popdown()
            }
        }
        box.append(child: base64Button)

        popover.set(child: WidgetRef(box.widget_ptr))
        popover.set(parent: drawingArea)
        popover.presentPointing(at: x, y: y)
    }

    private func copySelection(_ format: CopyFormat) {
        guard !bytes.isEmpty else { return }
        let range = selection ?? 0...(bytes.count - 1)
        let slice = Array(bytes[range])
        let text: String
        switch format {
        case .hex:
            text = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .ascii:
            text = String(
                slice.map {
                    (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "."
                }
            )
        case .base64:
            text = Data(slice).base64EncodedString()
        }
        if let display = Display.getDefault() {
            display.clipboard.set(text: text)
        }
    }
}
