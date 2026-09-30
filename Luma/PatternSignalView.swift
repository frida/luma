import LumaCore
import SwiftUI

struct DigitalSignalView: View {
    let segments: [PatternVisualization.SignalSegment]

    var body: some View {
        let totalBits = max(segments.reduce(0) { $0 + $1.bits }, 1)
        let levels: ClosedRange<CGFloat> = -0.1...1.1
        Canvas { canvas, size in
            let plot = CGRect(x: 0, y: 0, width: size.width, height: size.height - 14)
            func x(_ bit: Int) -> CGFloat { plot.minX + plot.width * CGFloat(bit) / CGFloat(totalBits) }
            func y(_ level: CGFloat) -> CGFloat {
                plot.maxY - plot.height * (level - levels.lowerBound) / (levels.upperBound - levels.lowerBound)
            }

            var bit = 0
            var signal = Path()
            signal.move(to: CGPoint(x: x(0), y: y(0)))
            for (index, segment) in segments.enumerated() {
                let color = PatternPalette.color(for: segment.color.flatMap(PatternTint.init(hex:)) ?? .palette(index))
                let start = x(bit)
                let end = x(bit + segment.bits)
                canvas.fill(Path(CGRect(x: start, y: y(1), width: end - start, height: y(0) - y(1))), with: .color(color.opacity(0.2)))
                let level: CGFloat = segment.isHigh ? 1 : 0
                signal.addLine(to: CGPoint(x: start, y: y(level)))
                signal.addLine(to: CGPoint(x: end, y: y(level)))
                let middle = (start + end) / 2
                canvas.draw(Text(segment.label).foregroundStyle(color), at: CGPoint(x: middle, y: y(0.55)))
                canvas.draw(Text(segment.value).foregroundStyle(color), at: CGPoint(x: middle, y: y(0.40)))
                canvas.draw(Text("\(bit)").foregroundStyle(.secondary), at: CGPoint(x: start, y: size.height - 6), anchor: .leading)
                bit += segment.bits
            }
            signal.addLine(to: CGPoint(x: x(bit), y: y(0)))
            canvas.stroke(signal, with: .color(.primary), lineWidth: 2)
            canvas.draw(Text("\(bit)").foregroundStyle(.secondary), at: CGPoint(x: x(bit), y: size.height - 6), anchor: .trailing)
        }
        .frame(width: 600, height: 200)
    }
}
