import Charts
import SwiftUI
import SwiftyPharo

struct PharoChartView: View {
    let chart: PharoChart
    var onDrill: ((Int) async -> PharoObject?)?
    var onSelect: (PharoObject) -> Void = { _ in }

    @State private var drilling = false
    @State private var selected: Int?
    @State private var hovered: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        let core = Chart {
            ForEach(Array(chart.series.enumerated()), id: \.offset) { series in
                marks(series.element, series: series.offset)
            }
        }
        .chartOverlay { proxy in tapCatcher(proxy) }
        .chartForegroundStyleScale(range: seriesColors)
        .chartLegend(chart.series.count > 1 ? .visible : .hidden)

        titled(scaled(core))
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(.leftArrow) { move(-1); return .handled }
            .onKeyPress(.rightArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.return) { drillSelected(); return .handled }
            .onKeyPress(.escape) { selected = nil; return .handled }
            .padding()
    }

    private var isNumeric: Bool {
        chart.series.allSatisfy { $0.kind != "bar" }
    }

    private var seriesColors: [Color] {
        chart.series.count > 1
            ? [.fridaBrand, .teal, .purple, .orange, .green, .pink]
            : [.fridaBrand]
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
                    .foregroundStyle(by: .value("Series", index))
                    .annotation(position: .top) { barValue(p.y) }
            case "bar":
                BarMark(x: .value("Value", p.y), y: .value("Label", p.label))
                    .foregroundStyle(by: .value("Series", index))
                    .annotation(position: .trailing) { barValue(p.y) }
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

    @ViewBuilder
    private func barValue(_ value: Double) -> some View {
        if showsBarValues {
            Text(formatted(value))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var showsBarValues: Bool {
        flatCount <= 40
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func tapCatcher(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .pointerStyle(.link)
                    .onTapGesture { location in activate(at: location, proxy: proxy, in: geometry) }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = point(at: location, proxy: proxy, in: geometry)
                        case .ended: hovered = nil
                        }
                    }

                if let selected, let position = plotPosition(of: selected, proxy: proxy, in: geometry) {
                    Circle()
                        .fill(Color.fridaBrand)
                        .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
                        .frame(width: 12, height: 12)
                        .position(position)
                        .allowsHitTesting(false)
                }

                if let hovered, let position = plotPosition(of: hovered, proxy: proxy, in: geometry) {
                    Text(readout(hovered))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        .position(x: position.x, y: position.y - 16)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func readout(_ flat: Int) -> String {
        guard let at = flatIndices().first(where: { $0.flat == flat }) else { return "" }
        let series = chart.series[at.series]
        let p = series.points[at.point]
        return series.kind == "bar"
            ? "\(p.label): \(formatted(p.y))"
            : "\(formatted(p.x)), \(formatted(p.y))"
    }

    private func activate(at location: CGPoint, proxy: ChartProxy, in geometry: GeometryProxy) {
        guard let index = point(at: location, proxy: proxy, in: geometry) else { return }
        if selected == index {
            drill(into: index)
        } else {
            selected = index
            isFocused = true
        }
    }

    private func point(at location: CGPoint, proxy: ChartProxy, in geometry: GeometryProxy) -> Int? {
        guard let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        let at = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        return isNumeric ? nearestPoint(to: at, proxy: proxy) : barPoint(at: at, proxy: proxy)
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

    private func plotPosition(of flat: Int, proxy: ChartProxy, in geometry: GeometryProxy) -> CGPoint? {
        guard let plot = proxy.plotFrame, let at = flatIndices().first(where: { $0.flat == flat }) else { return nil }
        let frame = geometry[plot]
        let series = chart.series[at.series]
        let p = series.points[at.point]
        let x: CGFloat?
        let y: CGFloat?
        switch (series.kind, series.orientation) {
        case ("bar", "vertical"):
            x = proxy.position(forX: p.label)
            y = proxy.position(forY: p.y)
        case ("bar", _):
            x = proxy.position(forX: p.y)
            y = proxy.position(forY: p.label)
        default:
            x = proxy.position(forX: p.x)
            y = proxy.position(forY: p.y)
        }
        guard let x, let y else { return nil }
        return CGPoint(x: frame.minX + x, y: frame.minY + y)
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

    private var flatCount: Int {
        chart.series.reduce(0) { $0 + $1.points.count }
    }

    private func move(_ delta: Int) {
        guard flatCount > 0 else { return }
        isFocused = true
        if let selected {
            self.selected = min(max(selected + delta, 0), flatCount - 1)
        } else {
            selected = delta > 0 ? 0 : flatCount - 1
        }
    }

    private func drillSelected() {
        if let selected { drill(into: selected) }
    }

    private func drill(into index: Int) {
        guard let onDrill, !drilling else { return }
        drilling = true
        Task {
            defer { drilling = false }
            if let drilled = await onDrill(index) {
                onSelect(drilled)
            }
        }
    }
}
