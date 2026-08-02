import Charts
import SwiftUI
import SwiftyPharo

struct PharoChartView: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let view: String
    let chart: PharoChart
    let onSelect: (PharoObject) -> Void

    @State private var drilling = false

    var body: some View {
        let core = Chart {
            ForEach(Array(chart.series.enumerated()), id: \.offset) { series in
                marks(series.element, series: series.offset)
            }
        }
        .chartOverlay { proxy in tapCatcher(proxy) }
        .chartLegend(chart.series.count > 1 ? .visible : .hidden)

        titled(scaled(core)).padding()
    }

    private var isNumeric: Bool {
        chart.series.allSatisfy { $0.kind != "bar" }
    }

    @ViewBuilder
    private func scaled(_ content: some View) -> some View {
        if isNumeric {
            content
                .chartXScale(type: chart.scaleX == "log" ? .log : .linear)
                .chartYScale(type: chart.scaleY == "log" ? .log : .linear)
        } else {
            content
        }
    }

    @ViewBuilder
    private func titled(_ content: some View) -> some View {
        switch (chart.titleX.isEmpty, chart.titleY.isEmpty) {
        case (false, false):
            content.chartXAxisLabel(chart.titleX).chartYAxisLabel(chart.titleY)
        case (false, true):
            content.chartXAxisLabel(chart.titleX)
        case (true, false):
            content.chartYAxisLabel(chart.titleY)
        case (true, true):
            content
        }
    }

    @ChartContentBuilder
    private func marks(_ series: PharoChartSeries, series index: Int) -> some ChartContent {
        ForEach(Array(series.points.enumerated()), id: \.offset) { point in
            let p = point.element
            switch series.kind {
            case "bar" where series.orientation == "vertical":
                BarMark(x: .value("Label", p.label), y: .value("Value", p.y))
            case "bar":
                BarMark(x: .value("Value", p.y), y: .value("Label", p.label))
            case "line":
                LineMark(x: .value("X", p.x), y: .value("Y", p.y))
                    .foregroundStyle(by: .value("Series", index))
                    .symbol(by: .value("Series", index))
            default:
                PointMark(x: .value("X", p.x), y: .value("Y", p.y))
                    .foregroundStyle(by: .value("Series", index))
            }
        }
    }

    private func tapCatcher(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in drill(at: location, proxy: proxy, in: geometry) }
        }
    }

    private func drill(at location: CGPoint, proxy: ChartProxy, in geometry: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let frame = geometry[plot]
        let at = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        if let index = isNumeric ? nearestPoint(to: at, proxy: proxy) : barPoint(at: at, proxy: proxy) {
            drill(into: index)
        }
    }

    private func barPoint(at location: CGPoint, proxy: ChartProxy) -> Int? {
        let horizontal = chart.series.first?.orientation != "vertical"
        let label: String? = horizontal ? proxy.value(atY: location.y) : proxy.value(atX: location.x)
        guard let label else { return nil }
        return flatIndices().first { chart.series[$0.series].points[$0.point].label == label }?.flat
    }

    private func nearestPoint(to location: CGPoint, proxy: ChartProxy) -> Int? {
        guard let x: Double = proxy.value(atX: location.x), let y: Double = proxy.value(atY: location.y) else {
            return nil
        }
        return flatIndices().min { a, b in
            distance(from: (x, y), to: a) < distance(from: (x, y), to: b)
        }?.flat
    }

    private func distance(from tap: (x: Double, y: Double), to index: (series: Int, point: Int, flat: Int)) -> Double {
        let p = chart.series[index.series].points[index.point]
        return hypot(p.x - tap.x, p.y - tap.y)
    }

    private func flatIndices() -> [(series: Int, point: Int, flat: Int)] {
        var flat = 0
        var result: [(series: Int, point: Int, flat: Int)] = []
        for (s, series) in chart.series.enumerated() {
            for p in series.points.indices {
                result.append((series: s, point: p, flat: flat))
                flat += 1
            }
        }
        return result
    }

    private func drill(into index: Int) {
        guard !drilling else { return }
        drilling = true
        Task {
            defer { drilling = false }
            if let drilled = try? await runtime.drillInto(object, view: view, index: index + 1) {
                onSelect(drilled)
            }
        }
    }
}
