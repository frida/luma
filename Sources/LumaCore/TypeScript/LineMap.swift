import Foundation

public struct LineMap: Sendable {
    public let lineStarts: [Int]
    public let utf16Count: Int

    public init(text: String) {
        var starts = [0]
        var offset = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A {
                if previous == 0x0D {
                    starts[starts.count - 1] = offset
                } else {
                    starts.append(offset)
                }
            } else if unit == 0x0D {
                starts.append(offset)
            }
            previous = unit
        }
        lineStarts = starts
        utf16Count = offset
    }

    public func position(ofUTF16Offset offset: Int) -> LSP.Position {
        let clamped = max(0, min(offset, utf16Count))
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= clamped {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return LSP.Position(line: low, character: clamped - lineStarts[low])
    }

    public func utf16Offset(of position: LSP.Position) -> Int {
        guard position.line < lineStarts.count else { return utf16Count }
        let lineStart = lineStarts[position.line]
        let lineEnd = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] : utf16Count
        return min(lineStart + position.character, lineEnd)
    }

    public func utf16Range(of range: LSP.Range) -> Range<Int> {
        let start = utf16Offset(of: range.start)
        return start..<max(start, utf16Offset(of: range.end))
    }
}
