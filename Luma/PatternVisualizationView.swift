import Charts
import ImageIO
import LumaCore
import SwiftUI

struct PatternVisualizationView: View {
    let visualization: PatternVisualization

    var body: some View {
        content
            .font(.system(.caption, design: .monospaced))
            .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch visualization {
        case .linePlot(let values):
            LinePlotView(values: values)
        case .scatterPlot(let x, let y):
            ScatterPlotView(x: x, y: y)
        case .image(let data):
            EncodedImageView(data: data)
        case .bitmap(let bitmap):
            BitmapView(bitmap: bitmap)
        case .model(let model):
            PatternModelView(model: model)
        case .sound(let sound):
            PatternSoundView(sound: sound)
        case .coordinates(let latitude, let longitude):
            PatternCoordinatesView(latitude: latitude, longitude: longitude)
        case .timestamp(let date):
            PatternTimestampView(date: date)
        case .table(let table):
            TableVisualizationView(table: table)
        case .digitalSignal(let segments):
            DigitalSignalView(segments: segments)
        case .hexViewer(let data, let address):
            BoundedScrollView(limit: CGSize(width: 640, height: 400)) {
                HexView(data: data, baseAddress: address)
            }
        case .chunkEntropy(let entropy):
            ChunkEntropyView(entropy: entropy)
        case .disassembly(let disassembly):
            DisassemblyVisualizationView(disassembly: disassembly)
        case .color, .gauge, .button:
            PatternInlineVisualizationView(visualization: visualization, press: {})
        }
    }
}

extension PatternVisualization {
    var isInline: Bool {
        switch self {
        case .color, .gauge, .button:
            return true
        default:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .linePlot, .chunkEntropy:
            return "chart.xyaxis.line"
        case .scatterPlot:
            return "chart.dots.scatter"
        case .image, .bitmap:
            return "photo"
        case .model:
            return "cube"
        case .sound:
            return "waveform"
        case .coordinates:
            return "map"
        case .timestamp:
            return "calendar"
        case .table:
            return "tablecells"
        case .digitalSignal:
            return "square.split.bottomrightquarter"
        case .hexViewer:
            return "number"
        case .disassembly:
            return "cpu"
        case .color:
            return "paintpalette"
        case .gauge:
            return "gauge.with.dots.needle.50percent"
        case .button:
            return "play"
        }
    }
}

struct PatternInlineVisualizationView: View {
    let visualization: PatternVisualization
    let press: () -> Void

    var body: some View {
        switch visualization {
        case .color(let red, let green, let blue, let alpha):
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: red, green: green, blue: blue, opacity: alpha))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 48, height: 11)
        case .gauge(let fraction):
            GaugeBar(fraction: fraction)
                .frame(width: 80, height: 9)
        case .button(_, let label):
            Button(action: press) {
                Label(label, systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        default:
            EmptyView()
        }
    }
}

private struct GaugeBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.2))
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
            }
        }
    }
}

private struct PlotPoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
}

private enum PlotSampling {
    static let maximumPoints = 2400

    static func envelope(_ values: [Float]) -> [PlotPoint] {
        let finite = values.enumerated().filter { $0.element.isFinite }
        guard finite.count > maximumPoints else {
            return finite.map { PlotPoint(id: $0.offset, x: Double($0.offset), y: Double($0.element)) }
        }
        let bucketSize = (finite.count + maximumPoints / 2 - 1) / (maximumPoints / 2)
        var points: [PlotPoint] = []
        for start in stride(from: 0, to: finite.count, by: bucketSize) {
            let bucket = finite[start..<min(start + bucketSize, finite.count)]
            let low = bucket.min { $0.element < $1.element }!
            let high = bucket.max { $0.element < $1.element }!
            for extreme in [low, high].sorted(by: { $0.offset < $1.offset }) {
                points.append(PlotPoint(id: points.count, x: Double(extreme.offset), y: Double(extreme.element)))
            }
        }
        return points
    }

    static func domain(of points: [PlotPoint]) -> ClosedRange<Double> {
        let first = points.first?.x ?? 0
        let last = points.last?.x ?? 0
        return first...max(last, first + 1)
    }

    static func pairs(_ x: [Float], _ y: [Float]) -> [PlotPoint] {
        let count = min(x.count, y.count)
        let step = max(1, count / maximumPoints)
        return stride(from: 0, to: count, by: step)
            .filter { x[$0].isFinite && y[$0].isFinite }
            .map { PlotPoint(id: $0, x: Double(x[$0]), y: Double(y[$0])) }
    }
}

private struct LinePlotView: View {
    private let points: [PlotPoint]

    init(values: [Float]) {
        points = PlotSampling.envelope(values)
    }

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Index", point.x), y: .value("Value", point.y))
                .interpolationMethod(.linear)
        }
        .chartXScale(domain: PlotSampling.domain(of: points))
        .foregroundStyle(Color.fridaBrand)
        .frame(width: 600, height: 300)
    }
}

private struct ScatterPlotView: View {
    private let points: [PlotPoint]

    init(x: [Float], y: [Float]) {
        points = PlotSampling.pairs(x, y)
    }

    var body: some View {
        Chart(points) { point in
            PointMark(x: .value("X", point.x), y: .value("Y", point.y))
                .symbolSize(12)
        }
        .foregroundStyle(Color.fridaBrand)
        .frame(width: 600, height: 300)
    }
}

private struct ChunkEntropyView: View {
    private let points: [PlotPoint]

    init(entropy: PatternVisualization.ChunkEntropy) {
        points = entropy.values.enumerated().map { PlotPoint(id: $0.offset, x: Double($0.offset * entropy.chunkSize), y: $0.element) }
    }

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Offset", point.x), y: .value("Entropy", point.y))
        }
        .chartXScale(domain: PlotSampling.domain(of: points))
        .chartYScale(domain: 0...1)
        .chartXAxisLabel("Offset")
        .chartYAxisLabel("Entropy")
        .foregroundStyle(Color.fridaBrand)
        .frame(width: 400, height: 250)
    }
}

private struct EncodedImageView: View {
    private let image: CGImage?

    init(data: Data) {
        image = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    var body: some View {
        if let image {
            PixelArt(image: image)
        } else {
            Text("Not an image format Luma can read.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct BitmapView: View {
    let bitmap: PatternVisualization.Bitmap

    var body: some View {
        if let image = cgImage {
            PixelArt(image: image)
        } else {
            Text("Empty bitmap.")
                .foregroundStyle(.secondary)
        }
    }

    private var cgImage: CGImage? {
        guard bitmap.width > 0, bitmap.height > 0, let provider = CGDataProvider(data: bitmap.rgba as CFData) else { return nil }
        return CGImage(
            width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private struct PixelArt: View {
    let image: CGImage

    @Environment(\.displayScale) private var displayScale

    private static let smallestSide: CGFloat = 200
    private static let largestSide: CGFloat = 600

    var body: some View {
        VStack(spacing: 6) {
            scaledImage
            Text("\(image.width) × \(image.height)")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var scaledImage: some View {
        let longest = CGFloat(max(image.width, image.height, 1))
        if longest > Self.largestSide {
            let fit = Self.largestSide / longest
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
        } else {
            let pointsPerPixel = max(1, (Self.smallestSide / longest).rounded(.down))
            let factor = max(1, Int((pointsPerPixel * displayScale).rounded()))
            Image(decorative: Self.enlarged(image, by: factor), scale: CGFloat(factor) / pointsPerPixel)
        }
    }

    private static func enlarged(_ image: CGImage, by factor: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: image.width * factor, height: image.height * factor, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * factor, height: image.height * factor))
        return context.makeImage()!
    }
}

private struct TableVisualizationView: View {
    let table: PatternVisualization.Table

    var body: some View {
        BoundedScrollView(limit: CGSize(width: 640, height: 400)) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<table.rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<table.columns, id: \.self) { column in
                            Text(table.cell(row: row, column: column))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .border(Color.primary.opacity(0.15), width: 0.5)
                        }
                    }
                    .background(row % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                }
            }
        }
    }
}

private struct DisassemblyVisualizationView: View {
    let disassembly: PatternVisualization.Disassembly

    @State private var listing: Listing = .loading

    private enum Listing {
        case loading
        case loaded([PatternVisualization.Disassembly.Instruction])
        case failed(String)
    }

    var body: some View {
        Group {
            switch listing {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .loaded(let instructions):
                BoundedScrollView(limit: CGSize(width: 800, height: 400)) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                        GridRow {
                            Text("Address")
                            Text("Bytes")
                            Text("Instruction")
                        }
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(instructions) { instruction in
                            GridRow {
                                Text(String(format: "0x%08llX", instruction.address))
                                    .foregroundStyle(.secondary)
                                Text(instruction.bytes)
                                Text(instruction.text)
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
            }
        }
        .task {
            do {
                listing = .loaded(try await disassembly.instructions())
            } catch {
                listing = .failed(error.localizedDescription)
            }
        }
    }
}

private struct BoundedScrollView<Content: View>: View {
    let limit: CGSize
    @ViewBuilder let content: Content

    @State private var contentSize: CGSize = .zero

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            content
                .fixedSize()
                .onGeometryChange(for: CGSize.self, of: \.size) { contentSize = $0 }
        }
        .frame(width: min(contentSize.width, limit.width), height: min(contentSize.height, limit.height))
    }
}
