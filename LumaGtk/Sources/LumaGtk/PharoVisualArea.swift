import CCairo
import CGtk
import Cairo
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

/// Draws the two visualisations a Pharo view can carry -- a `mondrian` graph and
/// a `GtPlotter` chart -- onto a Cairo surface, the way the SwiftUI frontend
/// draws them with a Canvas. The layout maths is shared through LumaCore; only
/// the strokes are GTK's.
@MainActor
enum PharoVisualArea {
    static func chart(_ chart: PharoChart) -> Box {
        let area = DrawingArea()
        area.contentWidth = 640
        area.contentHeight = 380
        area.setDrawFunc { _, ctx, width, height in
            MainActor.assumeIsolated { draw(chart, ctx, Double(width), Double(height)) }
        }
        return scrolling(area)
    }

    static let margin = 24.0

    private static func draw(_ chart: PharoChart, _ ctx: Cairo.ContextRef, _ width: Double, _ height: Double) {
        setFont(ctx, size: 11)
        let plot = Frame(left: 52, top: 16, right: width - 16, bottom: height - 40)
        let points = chart.series.flatMap(\.points)
        guard !points.isEmpty else { return }

        let logX = chart.scaleX == "logarithmic"
        let logY = chart.scaleY == "logarithmic"
        let xs = Bounds(points.map(\.x), log: logX)
        let ys = Bounds(points.map(\.y), log: logY)

        ctx.setSource(red: 0.5, green: 0.5, blue: 0.56, alpha: 0.9)
        ctx.moveTo(plot.left, plot.top)
        ctx.lineTo(plot.left, plot.bottom)
        ctx.lineTo(plot.right, plot.bottom)
        ctx.stroke()

        for series in chart.series {
            drawSeries(series, ctx, plot: plot, xs: xs, ys: ys, logX: logX, logY: logY)
        }

        ctx.setSource(red: 0.6, green: 0.6, blue: 0.64, alpha: 1)
        drawText(chart.titleX, ctx, x: (plot.left + plot.right) / 2, y: height - 12, centered: true)
    }

    private static func drawSeries(
        _ series: PharoChartSeries, _ ctx: Cairo.ContextRef,
        plot: Frame, xs: Bounds, ys: Bounds, logX: Bool, logY: Bool
    ) {
        let placed = series.points.map { point -> (x: Double, y: Double) in
            (plot.left + xs.fraction(point.x, log: logX) * plot.width,
             plot.bottom - ys.fraction(point.y, log: logY) * plot.height)
        }
        ctx.setSource(red: 0.94, green: 0.39, blue: 0.34, alpha: 1)

        switch series.kind {
        case "line":
            for (index, at) in placed.enumerated() {
                if index == 0 { ctx.moveTo(at.x, at.y) } else { ctx.lineTo(at.x, at.y) }
            }
            ctx.stroke()
        case "scatter":
            for at in placed {
                ctx.rectangle(x: at.x - 2.5, y: at.y - 2.5, width: 5, height: 5)
                ctx.fill()
            }
        default:
            let barWidth = max(2.0, plot.width / Double(placed.count) * 0.6)
            for at in placed {
                ctx.rectangle(x: at.x - barWidth / 2, y: at.y, width: barWidth, height: plot.bottom - at.y)
                ctx.fill()
            }
        }
    }

    private struct Frame {
        let left, top, right, bottom: Double
        var width: Double { right - left }
        var height: Double { bottom - top }
    }

    private struct Bounds {
        let low, high: Double
        init(_ values: [Double], log: Bool) {
            let mapped = log ? values.map { Foundation.log10(max($0, 1e-9)) } : values
            let lowest = mapped.min() ?? 0
            let highest = mapped.max() ?? 1
            low = lowest
            high = highest > lowest ? highest : lowest + 1
        }
        func fraction(_ value: Double, log: Bool) -> Double {
            let mapped = log ? Foundation.log10(max(value, 1e-9)) : value
            return (mapped - low) / (high - low)
        }
    }

    static func setFont(_ ctx: Cairo.ContextRef, size: Double) {
        "monospace".withCString { ctx.selectFontFace($0, slant: .normal, weight: .normal) }
        ctx.fontSize = size
    }

    private static func drawText(_ text: String, _ ctx: Cairo.ContextRef, x: Double, y: Double, centered: Bool) {
        text.withCString { cString in
            let extents = ctx.textExtents(cString)
            ctx.moveTo(centered ? x - extents.width / 2 : x, y)
            ctx.showText(cString)
        }
    }

    static func fit(_ label: String, into width: Double, ctx: Cairo.ContextRef) -> String {
        var text = label
        while text.count > 1, text.withCString({ ctx.textExtents($0).width }) > width {
            text = String(text.dropLast(2)) + "…"
        }
        return text
    }

    private static func scrolling(_ area: DrawingArea) -> Box {
        area.hexpand = true
        area.vexpand = true
        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: WidgetRef(area.widget_ptr))
        let box = Box(orientation: .vertical, spacing: 0)
        box.append(child: scroll)
        return box
    }
}
