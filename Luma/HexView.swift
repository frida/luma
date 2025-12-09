import SwiftUI

struct HexView: View {
    let data: Data
    let bytesPerRow: Int = 16

    let groupSpacing: CGFloat = 20
    let hexSpacing: CGFloat = 2
    let asciiSpacing: CGFloat = 0

    @FocusState private var isFocused: Bool
    @State private var caretIndex: Int? = nil

    @State private var dragSelection: ClosedRange<Int>? = nil
    @State private var dragStartIndex: Int? = nil

    @State private var offsetColumnWidth: CGFloat = 0
    @State private var hexCellSize: CGSize = .zero
    @State private var asciiCellSize: CGSize = .zero
    @State private var rowHeight: CGFloat = 0

    private var bytes: [UInt8] { Array(data) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                let row = rows[rowIndex]

                HStack(alignment: .firstTextBaseline, spacing: groupSpacing) {
                    Text(String(format: "%08X", row.offset))
                        .foregroundStyle(Color.green.opacity(0.85))
                        .background(
                            GeometryReader { geo in
                                Color.clear.onAppear {
                                    offsetColumnWidth = geo.size.width
                                }
                            }
                        )
                        .textSelection(.enabled)

                    HStack(spacing: hexSpacing) {
                        ForEach(row.bytes.indices, id: \.self) { col in
                            let global = row.offset + col
                            let byte = row.bytes[col]
                            Text(String(format: "%02X", byte))
                                .foregroundStyle(color(for: byte))
                                .padding(.horizontal, 2)
                                .background(selectionBackground(for: global))
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.onAppear {
                                            hexCellSize = geo.size
                                        }
                                    }
                                )
                        }
                    }

                    HStack(spacing: asciiSpacing) {
                        ForEach(row.bytes.indices, id: \.self) { col in
                            let global = row.offset + col
                            let byte = row.bytes[col]
                            let ch = ascii(for: byte)
                            Text(String(ch))
                                .foregroundStyle(.secondary)
                                .background(selectionBackground(for: global))
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.onAppear {
                                            asciiCellSize = geo.size
                                        }
                                    }
                                )
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .background(
                    GeometryReader { proxy in
                        Color.clear.onAppear {
                            rowHeight = proxy.size.height + 2
                        }
                    }
                )
            }
        }
        .contentShape(Rectangle())
        .textSelection(.disabled)
        .gesture(dragGesture)
        .contextMenu {
            if !bytes.isEmpty {
                Button("Copy Hex") { copySelection(.hex) }
                Button("Copy ASCII") { copySelection(.ascii) }
                Button("Copy Base64") { copySelection(.base64) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onTapGesture {
            isFocused = true
        }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
    }

    private var rows: [Row] {
        stride(from: 0, to: bytes.count, by: bytesPerRow).map { start in
            let end = min(start + bytesPerRow, bytes.count)
            return Row(offset: start, bytes: Array(bytes[start..<end]))
        }
    }

    private struct Row {
        let offset: Int
        let bytes: [UInt8]
    }

    private func color(for byte: UInt8) -> Color {
        switch byte {
        case 0x00:
            return .gray.opacity(0.6)
        case 0x20...0x7E:
            return .mint
        case 0x01...0x1F, 0x7F:
            return .orange
        default:
            return .cyan
        }
    }

    private func ascii(for byte: UInt8) -> Character {
        (0x20...0x7E).contains(byte)
            ? Character(UnicodeScalar(byte))
            : "."
    }

    private func ensureCaretInitialized() {
        guard !bytes.isEmpty else { return }
        if caretIndex == nil {
            caretIndex = 0
            dragSelection = 0...0
        }
    }

    private func updateSelection(to newIndex: Int, extend: Bool) {
        guard !bytes.isEmpty else { return }

        let clamped = max(0, min(bytes.count - 1, newIndex))
        caretIndex = clamped

        if extend, let currentRange = dragSelection {
            let anchor = currentRange.lowerBound
            let lower = min(anchor, clamped)
            let upper = max(anchor, clamped)
            dragSelection = lower...upper
        } else {
            dragSelection = clamped...clamped
        }
    }

    private func moveCaret(rowDelta: Int, colDelta: Int, extend: Bool) {
        guard !bytes.isEmpty else { return }
        ensureCaretInitialized()

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
        updateSelection(to: newIndex, extend: extend)
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard !bytes.isEmpty else { return .ignored }

        let extend = keyPress.modifiers.contains(.shift)
        let key = keyPress.key

        if key == .leftArrow {
            moveCaret(rowDelta: 0, colDelta: -1, extend: extend)
            return .handled
        }
        if key == .rightArrow {
            moveCaret(rowDelta: 0, colDelta: 1, extend: extend)
            return .handled
        }
        if key == .upArrow {
            moveCaret(rowDelta: -1, colDelta: 0, extend: extend)
            return .handled
        }
        if key == .downArrow {
            moveCaret(rowDelta: 1, colDelta: 0, extend: extend)
            return .handled
        }

        let h = KeyEquivalent("h")
        let j = KeyEquivalent("j")
        let k = KeyEquivalent("k")
        let l = KeyEquivalent("l")

        if key == h {
            moveCaret(rowDelta: 0, colDelta: -1, extend: extend)
            return .handled
        }
        if key == l {
            moveCaret(rowDelta: 0, colDelta: 1, extend: extend)
            return .handled
        }
        if key == k {
            moveCaret(rowDelta: -1, colDelta: 0, extend: extend)
            return .handled
        }
        if key == j {
            moveCaret(rowDelta: 1, colDelta: 0, extend: extend)
            return .handled
        }

        return .ignored
    }

    private func selectionBackground(for index: Int) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                (dragSelection?.contains(index) ?? false)
                    ? Color.accentColor.opacity(0.25)
                    : .clear)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let start = dragStartIndex ?? index(at: value.startLocation),
                    let current = index(at: value.location)
                else { return }

                if dragStartIndex == nil {
                    dragStartIndex = start
                }

                let lower = min(start, current)
                let upper = max(start, current)
                dragSelection = lower...upper
                caretIndex = current
            }
            .onEnded { _ in
                dragStartIndex = nil
            }
    }

    private func index(at location: CGPoint) -> Int? {
        guard rowHeight > 0,
            hexCellSize.width > 0,
            offsetColumnWidth > 0
        else { return nil }

        let row = max(0, Int(location.y / rowHeight))
        let rowStart = row * bytesPerRow
        guard rowStart < bytes.count else { return nil }

        let remaining = bytes.count - rowStart
        let rowLen = min(bytesPerRow, remaining)
        guard rowLen > 0 else { return nil }

        let x = location.x

        let hexStartX = offsetColumnWidth + groupSpacing
        let hexCellStride = hexCellSize.width + hexSpacing
        let hexRowWidth =
            CGFloat(rowLen) * hexCellSize.width
            + CGFloat(max(0, rowLen - 1)) * hexSpacing

        let haveAscii = asciiCellSize.width > 0
        let asciiStartX = hexStartX + hexRowWidth + groupSpacing
        let asciiCellStride = asciiCellSize.width + asciiSpacing
        let asciiRowWidth =
            CGFloat(rowLen) * asciiCellSize.width
            + CGFloat(max(0, rowLen - 1)) * asciiSpacing

        if x >= hexStartX && x <= hexStartX + hexRowWidth {
            let relativeX = x - hexStartX
            let stride = hexCellStride

            var col = Int(relativeX / stride)
            let offsetInStride = relativeX - CGFloat(col) * stride

            if offsetInStride >= hexCellSize.width {
                col += 1
            }

            col = max(0, min(rowLen - 1, col))

            let idx = rowStart + col
            return idx < bytes.count ? idx : nil
        }

        if haveAscii,
            x >= asciiStartX && x <= asciiStartX + asciiRowWidth
        {
            let relativeX = x - asciiStartX
            let stride = asciiCellStride

            var col = Int(relativeX / stride)
            let offsetInStride = relativeX - CGFloat(col) * stride

            if offsetInStride >= asciiCellSize.width {
                col += 1
            }

            col = max(0, min(rowLen - 1, col))

            let idx = rowStart + col
            return idx < bytes.count ? idx : nil
        }

        return nil
    }

    private enum CopyFormat { case hex, ascii, base64 }

    private func copySelection(_ format: CopyFormat) {
        guard !bytes.isEmpty else { return }

        let range = dragSelection ?? 0...(bytes.count - 1)
        let slice = Array(bytes[range])
        let data = Data(slice)

        let text: String
        switch format {
        case .hex:
            text = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .ascii:
            text = String(slice.map(ascii))
        case .base64:
            text = data.base64EncodedString()
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
