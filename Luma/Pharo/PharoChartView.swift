import Charts
import SwiftUI
import SwiftyPharo

/// A GtPlotter bar chart, drawn with the native Charts framework rather than
/// Bloc. A tap on a bar drills into the element behind it.
struct PharoChartView: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let view: String
    let chart: PharoChart
    let onSelect: (PharoObject) -> Void

    @State private var drilling = false

    var body: some View {
        Chart(indexedBars, id: \.offset) { bar in
            mark(for: bar.element)
        }
        .chartOverlay { proxy in tapCatcher(proxy) }
        .padding()
    }

    private var indexedBars: [(offset: Int, element: PharoChartBar)] {
        Array(chart.bars.enumerated())
    }

    @ChartContentBuilder
    private func mark(for bar: PharoChartBar) -> some ChartContent {
        if chart.orientation == "horizontal" {
            BarMark(x: .value("Value", bar.value), y: .value("Label", bar.label))
        } else {
            BarMark(x: .value("Label", bar.label), y: .value("Value", bar.value))
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
        let label: String? = chart.orientation == "horizontal"
            ? proxy.value(atY: location.y - frame.minY)
            : proxy.value(atX: location.x - frame.minX)
        guard let label, let index = chart.bars.firstIndex(where: { $0.label == label }) else { return }
        drill(into: index)
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
