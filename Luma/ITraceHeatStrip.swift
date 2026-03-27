import SwiftUI

struct ITraceHeatStrip: View {
    let entries: [TraceEntry]
    @Binding var selectedIndex: Int?

    @Environment(\.colorScheme) private var colorScheme

    private let stripHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let range = addressRange()
            let visits = visitCounts()
            let maxVisits = visits.values.max() ?? 1

            Canvas { context, size in
                guard range.span > 0 else { return }

                // Draw blocks.
                var drawn = Set<UInt64>()
                for entry in entries {
                    guard drawn.insert(entry.blockAddress).inserted else { continue }

                    let count = visits[entry.blockAddress] ?? 1
                    let x = xPos(entry.blockAddress, range: range, width: size.width)
                    let w = max(2, Double(entry.blockSize) / Double(range.span) * size.width)
                    let intensity = Double(count) / Double(maxVisits)
                    let hue = Double((entry.blockAddress >> 12) % 360) / 360.0
                    let color: Color
                    if colorScheme == .dark {
                        color = Color(hue: hue, saturation: 0.7, brightness: 0.3 + 0.7 * intensity)
                    } else {
                        color = Color(hue: hue, saturation: 0.5 + 0.4 * intensity, brightness: 0.4 + 0.3 * intensity)
                    }

                    context.fill(
                        Path(CGRect(x: x, y: 0, width: w, height: size.height)),
                        with: .color(color)
                    )
                }

                // Selection cursor.
                if let idx = selectedIndex, idx < entries.count {
                    let x = xPos(entries[idx].blockAddress, range: range, width: size.width)
                    let cursorColor: Color = colorScheme == .dark ? .white : .black
                    context.fill(
                        Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
                        with: .color(cursorColor)
                    )
                }
            }
            .background(colorScheme == .dark ? Color.black.opacity(0.85) : Color(white: 0.92))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard range.span > 0 else { return }
                let targetAddr = range.min + UInt64(location.x / geo.size.width * CGFloat(range.span))
                selectedIndex = nearestEntryIndex(to: targetAddr)
            }
        }
        .frame(height: stripHeight)
    }

    private struct AddressRange {
        let min: UInt64
        let max: UInt64
        var span: UInt64 { max - min }
    }

    private func addressRange() -> AddressRange {
        var lo: UInt64 = .max
        var hi: UInt64 = 0
        for entry in entries {
            lo = Swift.min(lo, entry.blockAddress)
            hi = Swift.max(hi, entry.blockAddress + UInt64(entry.blockSize))
        }
        guard lo < hi else { return AddressRange(min: 0, max: 1) }
        return AddressRange(min: lo, max: hi)
    }

    private func visitCounts() -> [UInt64: Int] {
        var counts: [UInt64: Int] = [:]
        for entry in entries {
            counts[entry.blockAddress, default: 0] += 1
        }
        return counts
    }

    private func xPos(_ address: UInt64, range: AddressRange, width: CGFloat) -> CGFloat {
        Double(address - range.min) / Double(range.span) * width
    }

    private func nearestEntryIndex(to address: UInt64) -> Int {
        var bestIdx = 0
        var bestDist: UInt64 = .max
        for (i, entry) in entries.enumerated() {
            let dist = address >= entry.blockAddress
                ? address - entry.blockAddress
                : entry.blockAddress - address
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        return bestIdx
    }
}
