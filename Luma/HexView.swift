import SwiftUI

struct HexView: View {
    private let bytes: [UInt8]
    private let baseAddress: UInt64

    @FocusState private var isFocused: Bool
    @State private var selection: Selection?

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    init(data: Data, baseAddress: UInt64 = 0) {
        bytes = Array(data)
        self.baseAddress = baseAddress
    }

    var body: some View {
        let layout = self.layout
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                self.row(row, layout: layout)
                    .equatable()
            }
        }
        .contentShape(Rectangle())
        .textSelection(.disabled)
        .gesture(dragGesture(layout: layout))
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

    private var layout: HexLayout {
        isCompactWidth
            ? HexLayout(metrics: .compact, addressDigits: nil)
            : HexLayout(metrics: .regular, addressDigits: addressDigits)
    }

    private var addressDigits: Int {
        let lastRow = max(rowCount - 1, 0)
        let lastRowAddress = baseAddress &+ UInt64(lastRow * HexLayout.bytesPerRow)
        return max(8, String(lastRowAddress, radix: 16).count)
    }

    private var rowCount: Int {
        (bytes.count + HexLayout.bytesPerRow - 1) / HexLayout.bytesPerRow
    }

    private func row(_ row: Int, layout: HexLayout) -> HexRow {
        let start = row * HexLayout.bytesPerRow
        let end = min(start + HexLayout.bytesPerRow, bytes.count)
        return HexRow(
            address: layout.addressDigits.map { formatAddress(baseAddress &+ UInt64(start), digits: $0) },
            bytes: bytes[start..<end],
            selectedColumns: selectedColumns(inRowStartingAt: start),
            layout: layout)
    }

    private func formatAddress(_ address: UInt64, digits: Int) -> String {
        let hex = String(address, radix: 16, uppercase: true)
        return String(repeating: "0", count: digits - hex.count) + hex
    }

    private func selectedColumns(inRowStartingAt start: Int) -> ClosedRange<Int>? {
        guard let range = selection?.range else { return nil }
        let first = max(range.lowerBound, start)
        let last = min(range.upperBound, start + HexLayout.bytesPerRow - 1)
        return first <= last ? (first - start)...(last - start) : nil
    }

    private func dragGesture(layout: HexLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let anchor = byteIndex(at: value.startLocation, layout: layout),
                    let caret = byteIndex(at: value.location, layout: layout)
                else { return }
                selection = Selection(anchor: anchor, caret: caret)
            }
    }

    private func byteIndex(at point: CGPoint, layout: HexLayout) -> Int? {
        guard point.y >= 0 else { return nil }
        let rowStart = Int(point.y / layout.metrics.rowHeight) * HexLayout.bytesPerRow
        guard rowStart < bytes.count, let column = layout.byteColumn(atX: point.x) else { return nil }
        return min(rowStart + column, bytes.count - 1)
    }

    private enum CopyFormat { case hex, ascii, base64 }

    private func copySelection(_ format: CopyFormat) {
        let slice = bytes[selection?.range ?? 0...(bytes.count - 1)]

        let text: String
        switch format {
        case .hex:
            text = slice.map { HexRow.hexDigits[Int($0)] }.joined(separator: " ")
        case .ascii:
            text = String(slice.map(HexRow.asciiCharacter))
        case .base64:
            text = Data(slice).base64EncodedString()
        }

        Platform.copyToClipboard(text)
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard !bytes.isEmpty, let motion = caretMotion(for: keyPress.key) else { return .ignored }
        moveCaret(rows: motion.rows, columns: motion.columns, extending: keyPress.modifiers.contains(.shift))
        return .handled
    }

    private func caretMotion(for key: KeyEquivalent) -> (rows: Int, columns: Int)? {
        switch key {
        case .leftArrow, "h": (0, -1)
        case .rightArrow, "l": (0, 1)
        case .upArrow, "k": (-1, 0)
        case .downArrow, "j": (1, 0)
        default: nil
        }
    }

    private func moveCaret(rows: Int, columns: Int, extending: Bool) {
        let caret = selection?.caret ?? 0
        let lastRow = rowCount - 1
        let row = min(max(caret / HexLayout.bytesPerRow + rows, 0), lastRow)
        let column = caret % HexLayout.bytesPerRow
        let newCaret = min(max(row * HexLayout.bytesPerRow + column + columns, 0), bytes.count - 1)
        selection = Selection(anchor: extending ? selection?.anchor ?? 0 : newCaret, caret: newCaret)
    }

    private struct Selection {
        var anchor: Int
        var caret: Int

        var range: ClosedRange<Int> { min(anchor, caret)...max(anchor, caret) }
    }
}

private struct HexRow: View, Equatable {
    let address: String?
    let bytes: ArraySlice<UInt8>
    let selectedColumns: ClosedRange<Int>?
    let layout: HexLayout

    static let hexDigits: [String] = (0...255).map { String(format: "%02X", $0) }

    var body: some View {
        Text(line)
            .font(layout.metrics.font)
            .lineLimit(1)
            .fixedSize()
            .frame(height: layout.metrics.rowHeight)
    }

    private var line: AttributedString {
        var line = AttributedString()
        if let address {
            line += run(address, color: Color.green.opacity(0.85))
            line += run(HexLayout.sectionGap)
        }
        line += hexColumn
        line += run(HexLayout.sectionGap)
        line += asciiColumn
        return line
    }

    private var hexColumn: AttributedString {
        var column = AttributedString()
        for (index, byte) in zip(0..., bytes) {
            if index > 0 {
                column += run(" ", selected: isSelected(index - 1) && isSelected(index))
            }
            column += run(Self.hexDigits[Int(byte)], color: color(for: byte), selected: isSelected(index))
        }
        let missingBytes = HexLayout.bytesPerRow - bytes.count
        column += run(String(repeating: " ", count: missingBytes * HexLayout.hexCellWidth))
        return column
    }

    private var asciiColumn: AttributedString {
        var column = AttributedString()
        for (index, byte) in zip(0..., bytes) {
            column += run(String(Self.asciiCharacter(for: byte)), color: .secondary, selected: isSelected(index))
        }
        return column
    }

    private func run(_ text: String, color: Color? = nil, selected: Bool = false) -> AttributedString {
        var run = AttributedString(text)
        run.foregroundColor = color
        if selected {
            run.backgroundColor = Color.accentColor.opacity(0.25)
        }
        return run
    }

    private func isSelected(_ column: Int) -> Bool {
        selectedColumns?.contains(column) ?? false
    }

    private func color(for byte: UInt8) -> Color {
        switch byte {
        case 0x00:
            .gray.opacity(0.6)
        case 0x20...0x7E:
            .mint
        case 0x01...0x1F, 0x7F:
            .orange
        default:
            .cyan
        }
    }

    static func asciiCharacter(for byte: UInt8) -> Character {
        (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
    }
}

private struct HexLayout: Equatable {
    let metrics: HexMetrics
    let addressDigits: Int?

    static let bytesPerRow = 16
    static let hexCellWidth = 3
    static let sectionGap = "   "

    func byteColumn(atX x: CGFloat) -> Int? {
        let column = x / metrics.advance
        let hexStart = CGFloat(hexStartColumn)
        let hexEnd = hexStart + CGFloat(Self.bytesPerRow * Self.hexCellWidth - 1)
        let asciiStart = hexEnd + CGFloat(Self.sectionGap.count)
        let asciiEnd = asciiStart + CGFloat(Self.bytesPerRow)

        if (hexStart..<hexEnd).contains(column) {
            let cellCenteredColumn = column - hexStart + 0.5
            return Int(cellCenteredColumn) / Self.hexCellWidth
        }
        if (asciiStart..<asciiEnd).contains(column) {
            return Int(column - asciiStart)
        }
        return nil
    }

    private var hexStartColumn: Int {
        addressDigits.map { $0 + Self.sectionGap.count } ?? 0
    }
}

private struct HexMetrics: Equatable {
    let font: Font
    let advance: CGFloat
    let rowHeight: CGFloat

    static let regular = HexMetrics(
        PlatformFont.monospacedSystemFont(ofSize: PlatformFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular))
    static let compact = HexMetrics(PlatformFont.monospacedSystemFont(ofSize: 9, weight: .regular))

    private static let rowGap: CGFloat = 3

    private init(_ font: PlatformFont) {
        self.font = Font(font as CTFont)
        advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        rowHeight = (font.ascender - font.descender + font.leading).rounded(.up) + Self.rowGap
    }
}
