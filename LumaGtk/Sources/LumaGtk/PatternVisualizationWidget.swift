import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class PatternVisualizationWidget {
    let widget: Widget

    private var keepers: [AnyObject] = []

    init(_ visualization: PatternVisualization) {
        let box = Box(orientation: .vertical, spacing: 6)
        box.marginStart = 12
        box.marginEnd = 12
        box.marginTop = 12
        box.marginBottom = 12
        widget = box
        switch visualization {
        case .linePlot(let values):
            append(PlotArea(points: PlotArea.envelope(values), style: .line, yDomain: nil), to: box)
        case .scatterPlot(let x, let y):
            append(PlotArea(points: PlotArea.pairs(x, y), style: .scatter, yDomain: nil), to: box)
        case .chunkEntropy(let entropy):
            let points = entropy.values.enumerated().map { (Double($0.offset * entropy.chunkSize), $0.element) }
            append(PlotArea(points: points, style: .line, yDomain: 0...1), to: box)
        case .image(let data):
            appendPixelArt(PixelArtArea(encoded: data), to: box)
        case .bitmap(let bitmap):
            appendPixelArt(PixelArtArea(bitmap: bitmap), to: box)
        case .model(let model):
            let area = ModelArea(model: model)
            keepers.append(area)
            box.append(child: area.widget)
            box.append(child: Self.caption("Drag to turn, scroll to zoom."))
        case .sound(let sound):
            appendSound(sound, to: box)
        case .coordinates(let latitude, let longitude):
            appendCoordinates(latitude: latitude, longitude: longitude, to: box)
        case .timestamp(let date):
            appendTimestamp(date, to: box)
        case .table(let table):
            box.append(child: Self.bounded(Self.grid(of: table), width: 640, height: 400))
        case .digitalSignal(let segments):
            append(SignalArea(segments: segments), to: box)
        case .hexViewer(let data, let address):
            let hex = HexView(bytes: data, baseAddress: address)
            keepers.append(hex)
            box.append(child: Self.bounded(hex.widget, width: -1, height: 400))
        case .disassembly(let disassembly):
            appendDisassembly(disassembly, to: box)
        case .color, .gauge, .button:
            box.append(child: PatternInlineVisualization(visualization)!.make(press: { _ in }))
        }
    }

    private func append(_ area: some DrawnArea, to box: Box) {
        keepers.append(area)
        box.append(child: area.widget)
    }

    private func appendPixelArt(_ area: PixelArtArea?, to box: Box) {
        guard let area else {
            box.append(child: Self.caption("Not an image format Luma can read."))
            return
        }
        keepers.append(area)
        box.append(child: area.widget)
        box.append(child: Self.caption("\(area.pixelWidth) × \(area.pixelHeight)"))
    }

    private func appendSound(_ sound: PatternVisualization.Sound, to box: Box) {
        append(WaveformArea(sound: sound), to: box)
        let frames = sound.samples.count / sound.channels
        let seconds = Double(frames) / Double(sound.sampleRate)
        if let url = try? Self.writeWAV(sound) {
            let stream = gtk_media_file_new_for_filename(url.path)
            g_object_set_data_full(UnsafeMutableRawPointer(stream)!.assumingMemoryBound(to: GObject.self), "luma-wav", strdup(url.path)) { path in
                unlink(path!.assumingMemoryBound(to: CChar.self))
                free(path)
            }
            gtk_box_append(box.box_ptr, gtk_media_controls_new(stream))
            g_object_unref(stream)
        }
        box.append(child: Self.caption(String(format: "%d ch · %d Hz · %.2f s", sound.channels, sound.sampleRate, seconds)))
    }

    private func appendCoordinates(latitude: Double, longitude: Double, to box: Box) {
        let text = String(format: "%.6f, %.6f", latitude, longitude)
        let label = Label(str: text)
        label.selectable = true
        label.add(cssClass: "monospace")
        label.halign = .start
        box.append(child: label)
        let uri = String(format: "https://www.openstreetmap.org/?mlat=%.6f&mlon=%.6f#map=15/%.6f/%.6f", latitude, longitude, latitude, longitude)
        let link = gtk_link_button_new_with_label(uri, "Open in OpenStreetMap")
        gtk_widget_set_halign(link, GTK_ALIGN_START)
        gtk_box_append(box.box_ptr, link)
    }

    private func appendTimestamp(_ date: Date, to box: Box) {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)

        let row = Box(orientation: .horizontal, spacing: 24)
        let month = Gtk.Calendar()
        let day = g_date_time_new_utc(gint(parts.year!), gint(parts.month!), gint(parts.day!), 0, 0, 0)
        #if HAS_GTK_CALENDAR_SET_DATE
        gtk_calendar_set_date(month.calendar_ptr, day)
        #else
        gtk_calendar_select_day(month.calendar_ptr, day)
        #endif
        g_date_time_unref(day)
        month.canTarget = false
        row.append(child: month)
        let clock = ClockArea(date: date, calendar: calendar)
        keepers.append(clock)
        row.append(child: clock.widget)
        box.append(child: row)

        let text = Label(str: date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space, timeZone: calendar.timeZone)))
        text.selectable = true
        text.add(cssClass: "monospace")
        box.append(child: text)
    }

    private func appendDisassembly(_ disassembly: PatternVisualization.Disassembly, to box: Box) {
        let spinner = makeSpinner()
        box.append(child: spinner)
        Task { @MainActor [weak box] in
            let listing: Widget
            do {
                listing = Self.bounded(Self.grid(of: try await disassembly.instructions()), width: 800, height: 400)
            } catch {
                let failure = Label(str: error.localizedDescription)
                failure.add(cssClass: "error")
                listing = failure
            }
            box?.remove(child: spinner)
            box?.append(child: listing)
        }
    }

    private static func caption(_ text: String) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "caption")
        label.add(cssClass: "dim-label")
        return label
    }

    private static func writeWAV(_ sound: PatternVisualization.Sound) throws -> URL {
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        let payload = sound.samples.count * 2
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payload))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(sound.channels))
        append(UInt32(sound.sampleRate))
        append(UInt32(sound.sampleRate * sound.channels * 2))
        append(UInt16(sound.channels * 2))
        append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(payload))
        for sample in sound.samples {
            append(sample)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("luma-pattern-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }

    private static func grid(of table: PatternVisualization.Table) -> Grid {
        let grid = Grid()
        grid.add(cssClass: "luma-pattern-table")
        for row in 0..<table.rows {
            for column in 0..<table.columns {
                let cell = Label(str: table.cell(row: row, column: column))
                cell.add(cssClass: "monospace")
                cell.add(cssClass: "luma-pattern-cell")
                cell.xalign = 0
                grid.attach(child: cell, column: column, row: row, width: 1, height: 1)
            }
        }
        return grid
    }

    private static func bounded(_ content: Widget, width: Int, height: Int) -> ScrolledWindow {
        let scroller = ScrolledWindow()
        scroller.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        scroller.propagateNaturalWidth = true
        scroller.propagateNaturalHeight = true
        if width > 0 {
            scroller.maxContentWidth = width
        }
        scroller.maxContentHeight = height
        scroller.set(child: content)
        return scroller
    }

    private static func grid(of instructions: [PatternVisualization.Disassembly.Instruction]) -> Grid {
        let grid = Grid()
        grid.columnSpacing = 16
        grid.rowSpacing = 2
        for (column, title) in ["Address", "Bytes", "Instruction"].enumerated() {
            let header = Label(str: title)
            header.add(cssClass: "dim-label")
            header.xalign = 0
            grid.attach(child: header, column: column, row: 0, width: 1, height: 1)
        }
        for (row, instruction) in instructions.enumerated() {
            let cells = [String(format: "0x%08llX", instruction.address), instruction.bytes, instruction.text]
            for (column, text) in cells.enumerated() {
                let cell = Label(str: text)
                cell.add(cssClass: "monospace")
                cell.xalign = 0
                cell.selectable = true
                if column == 0 {
                    cell.add(cssClass: "dim-label")
                }
                grid.attach(child: cell, column: column, row: row + 1, width: 1, height: 1)
            }
        }
        return grid
    }
}

enum PatternInlineVisualization {
    case color(GdkRGBA)
    case gauge(Double)
    case button(label: String)

    init?(_ visualization: PatternVisualization) {
        switch visualization {
        case .color(let red, let green, let blue, let alpha):
            self = .color(GdkRGBA(red: Float(red), green: Float(green), blue: Float(blue), alpha: Float(alpha)))
        case .gauge(let fraction):
            self = .gauge(fraction)
        case .button(_, let label):
            self = .button(label: label)
        default:
            return nil
        }
    }

    @MainActor
    func make(press: @escaping (Widget) -> Void) -> Widget {
        switch self {
        case .color(let color):
            let swatch = DrawingArea()
            swatch.setSizeRequest(width: 48, height: 11)
            swatch.valign = .center
            swatch.setDrawFunc { _, ctx, width, height in
                MainActor.assumeIsolated {
                    let cr: UnsafeMutablePointer<cairo_t> = ctx._ptr
                    cairo_rectangle(cr, 0, 0, Double(width), Double(height))
                    color.setSource(on: cr)
                    cairo_fill_preserve(cr)
                    cairo_set_source_rgba(cr, 0.5, 0.5, 0.5, 0.5)
                    cairo_set_line_width(cr, 1)
                    cairo_stroke(cr)
                }
            }
            return swatch
        case .gauge(let fraction):
            let bar = LevelBar()
            bar.value = min(max(fraction, 0), 1)
            bar.setSizeRequest(width: 80, height: -1)
            bar.valign = .center
            return bar
        case .button(let label):
            let button = Button(label: "▶ " + label)
            button.add(cssClass: "flat")
            button.add(cssClass: "luma-pattern-chevron")
            button.focusable = false
            button.onClicked { [weak button] _ in
                MainActor.assumeIsolated {
                    guard let button else { return }
                    press(button)
                }
            }
            return button
        }
    }
}

@MainActor
private protocol DrawnArea: AnyObject {
    var widget: DrawingArea { get }
}

private let plotAccent = GdkRGBA(red: 239 / 255, green: 100 / 255, blue: 86 / 255, alpha: 1)

@MainActor
private final class PlotArea: DrawnArea {
    let widget: DrawingArea

    enum Style {
        case line
        case scatter
    }

    private static let largestPlot = 2400
    private static let insets = (left: 8.0, right: 48.0, top: 8.0, bottom: 22.0)

    init(points: [(Double, Double)], style: Style, yDomain: ClosedRange<Double>?) {
        widget = DrawingArea()
        widget.setSizeRequest(width: 600, height: 300)
        let xs = points.map(\.0)
        let ys = points.map(\.1)
        let xDomain = (xs.min() ?? 0)...max(xs.max() ?? 1, (xs.min() ?? 0) + 1)
        let yRange = yDomain ?? Self.padded((ys.min() ?? 0)...(ys.max() ?? 1))
        widget.setDrawFunc { [weak widget] _, ctx, width, height in
            MainActor.assumeIsolated {
                guard let widget else { return }
                Self.draw(points, style: style, x: xDomain, y: yRange, on: ctx, size: (Double(width), Double(height)), text: widget.textColor)
            }
        }
    }

    static func envelope(_ values: [Float]) -> [(Double, Double)] {
        let finite = values.enumerated().filter { $0.element.isFinite }
        guard finite.count > largestPlot else { return finite.map { (Double($0.offset), Double($0.element)) } }
        let bucketSize = (finite.count + largestPlot / 2 - 1) / (largestPlot / 2)
        var points: [(Double, Double)] = []
        for start in stride(from: 0, to: finite.count, by: bucketSize) {
            let bucket = finite[start..<min(start + bucketSize, finite.count)]
            let low = bucket.min { $0.element < $1.element }!
            let high = bucket.max { $0.element < $1.element }!
            for extreme in [low, high].sorted(by: { $0.offset < $1.offset }) {
                points.append((Double(extreme.offset), Double(extreme.element)))
            }
        }
        return points
    }

    static func pairs(_ x: [Float], _ y: [Float]) -> [(Double, Double)] {
        let count = min(x.count, y.count)
        let step = max(1, count / largestPlot)
        return stride(from: 0, to: count, by: step)
            .filter { x[$0].isFinite && y[$0].isFinite }
            .map { (Double(x[$0]), Double(y[$0])) }
    }

    private static func padded(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        let span = max(range.upperBound - range.lowerBound, 1e-9)
        return (range.lowerBound - span * 0.05)...(range.upperBound + span * 0.05)
    }

    private static func draw(
        _ points: [(Double, Double)], style: Style, x: ClosedRange<Double>, y: ClosedRange<Double>, on ctx: Cairo.ContextRef,
        size: (width: Double, height: Double), text: GdkRGBA
    ) {
        let cr: UnsafeMutablePointer<cairo_t> = ctx._ptr
        let plot = CGRect(
            x: insets.left, y: insets.top, width: size.width - insets.left - insets.right, height: size.height - insets.top - insets.bottom)
        func px(_ value: Double) -> Double { plot.minX + (value - x.lowerBound) / (x.upperBound - x.lowerBound) * plot.width }
        func py(_ value: Double) -> Double { plot.maxY - (value - y.lowerBound) / (y.upperBound - y.lowerBound) * plot.height }

        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 10)
        cairo_set_line_width(cr, 1)
        for tick in ticks(in: y) {
            text.scalingAlpha(by: 0.15).setSource(on: cr)
            cairo_move_to(cr, plot.minX, py(tick).rounded() + 0.5)
            cairo_line_to(cr, plot.maxX, py(tick).rounded() + 0.5)
            cairo_stroke(cr)
            text.scalingAlpha(by: 0.6).setSource(on: cr)
            cairo_move_to(cr, plot.maxX + 6, py(tick) + 3)
            cairo_show_text(cr, label(tick))
        }
        for tick in ticks(in: x) {
            text.scalingAlpha(by: 0.15).setSource(on: cr)
            cairo_move_to(cr, px(tick).rounded() + 0.5, plot.minY)
            cairo_line_to(cr, px(tick).rounded() + 0.5, plot.maxY)
            cairo_stroke(cr)
            text.scalingAlpha(by: 0.6).setSource(on: cr)
            cairo_move_to(cr, px(tick) + 3, plot.maxY + 14)
            cairo_show_text(cr, label(tick))
        }

        plotAccent.setSource(on: cr)
        switch style {
        case .line:
            cairo_set_line_width(cr, 2)
            for (index, point) in points.enumerated() {
                if index == 0 {
                    cairo_move_to(cr, px(point.0), py(point.1))
                } else {
                    cairo_line_to(cr, px(point.0), py(point.1))
                }
            }
            cairo_stroke(cr)
        case .scatter:
            for point in points {
                cairo_new_sub_path(cr)
                cairo_arc(cr, px(point.0), py(point.1), 2.5, 0, 2 * .pi)
            }
            cairo_fill(cr)
        }
    }

    private static func ticks(in range: ClosedRange<Double>) -> [Double] {
        let span = range.upperBound - range.lowerBound
        let rough = span / 4
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? rough
        let first = ceil(range.lowerBound / step) * step
        return stride(from: first, through: range.upperBound, by: step).map { $0 }
    }

    private static func label(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(format: "%.2g", value)
    }
}

@MainActor
private final class PixelArtArea {
    let widget: DrawingArea
    let pixelWidth: Int
    let pixelHeight: Int

    nonisolated(unsafe) private let surface: OpaquePointer
    nonisolated(unsafe) private let pixels: UnsafeMutablePointer<UInt8>

    private static let smallestSide = 200.0
    private static let largestSide = 600.0

    convenience init?(encoded data: Data) {
        guard let texture = IconPixbuf.makeTexture(fromEncodedData: data) else { return nil }
        let width = Int(texture.width)
        let height = Int(texture.height)
        var premultiplied = [UInt8](repeating: 0, count: width * height * 4)
        premultiplied.withUnsafeMutableBufferPointer {
            gdk_texture_download(texture.texture_ptr, $0.baseAddress, gsize(width * 4))
        }
        self.init(premultipliedBGRA: premultiplied, width: width, height: height)
    }

    convenience init(bitmap: PatternVisualization.Bitmap) {
        var premultiplied = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        let rgba = Array(bitmap.rgba)
        for pixel in 0..<(bitmap.width * bitmap.height) {
            let alpha = UInt16(rgba[pixel * 4 + 3])
            premultiplied[pixel * 4] = UInt8(UInt16(rgba[pixel * 4 + 2]) * alpha / 255)
            premultiplied[pixel * 4 + 1] = UInt8(UInt16(rgba[pixel * 4 + 1]) * alpha / 255)
            premultiplied[pixel * 4 + 2] = UInt8(UInt16(rgba[pixel * 4]) * alpha / 255)
            premultiplied[pixel * 4 + 3] = UInt8(alpha)
        }
        self.init(premultipliedBGRA: premultiplied, width: bitmap.width, height: bitmap.height)
    }

    private init(premultipliedBGRA: [UInt8], width: Int, height: Int) {
        pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: premultipliedBGRA.count)
        pixels.initialize(from: premultipliedBGRA, count: premultipliedBGRA.count)
        pixelWidth = width
        pixelHeight = height
        surface = OpaquePointer(cairo_image_surface_create_for_data(pixels, CAIRO_FORMAT_ARGB32, gint(width), gint(height), gint(width * 4)))
        let longest = Double(max(width, height, 1))
        let scale = longest > Self.largestSide ? Self.largestSide / longest : max(1, (Self.smallestSide / longest).rounded(.down))
        widget = DrawingArea()
        widget.setSizeRequest(width: Int(Double(width) * scale), height: Int(Double(height) * scale))
        let surface = surface
        widget.setDrawFunc { _, ctx, _, _ in
            let cr: UnsafeMutablePointer<cairo_t> = ctx._ptr
            cairo_scale(cr, scale, scale)
            cairo_set_source_surface(cr, UnsafeMutablePointer(surface), 0, 0)
            cairo_pattern_set_filter(cairo_get_source(cr), scale >= 1 ? CAIRO_FILTER_NEAREST : CAIRO_FILTER_GOOD)
            cairo_paint(cr)
        }
    }

    deinit {
        cairo_surface_destroy(UnsafeMutablePointer(surface))
        pixels.deallocate()
    }
}

@MainActor
private final class ModelArea {
    let widget: DrawingArea

    private let positions: [SIMD3<Double>]
    private let triangles: [(Int, Int, Int)]
    private let colors: [SIMD3<Double>]
    private var yaw = 0.6
    private var pitch = 0.4
    private var zoom = 1.0
    private var dragStart = (yaw: 0.0, pitch: 0.0)

    init(model: PatternVisualization.Model) {
        let vertexCount = model.vertices.count / 3
        let raw = (0..<vertexCount).map { SIMD3(Double(model.vertices[$0 * 3]), Double(model.vertices[$0 * 3 + 1]), Double(model.vertices[$0 * 3 + 2])) }
        let low = raw.reduce(raw[0]) { SIMD3(min($0.x, $1.x), min($0.y, $1.y), min($0.z, $1.z)) }
        let high = raw.reduce(raw[0]) { SIMD3(max($0.x, $1.x), max($0.y, $1.y), max($0.z, $1.z)) }
        let center = (low + high) / 2
        let radius = max(((high - center) * (high - center)).sum().squareRoot(), .leastNormalMagnitude)
        positions = raw.map { ($0 - center) / radius }
        let indices = model.indices.map { $0.map(Int.init) } ?? Array(0..<(vertexCount - vertexCount % 3))
        triangles = stride(from: 0, to: indices.count - 2, by: 3).map { (indices[$0], indices[$0 + 1], indices[$0 + 2]) }
        let defaultColor = SIMD3<Double>(1, 0x7f / 255.0, 0x33 / 255.0)
        colors =
            model.colors.count == vertexCount * 4
            ? (0..<vertexCount).map { SIMD3(Double(model.colors[$0 * 4]), Double(model.colors[$0 * 4 + 1]), Double(model.colors[$0 * 4 + 2])) }
            : Array(repeating: defaultColor, count: vertexCount)

        widget = DrawingArea()
        widget.setSizeRequest(width: 400, height: 400)
        widget.setDrawFunc { [weak self] _, ctx, width, height in
            MainActor.assumeIsolated {
                self?.draw(on: ctx, width: Double(width), height: Double(height))
            }
        }

        let drag = GestureDrag()
        drag.onDragBegin { [weak self] _, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dragStart = (self.yaw, self.pitch)
            }
        }
        drag.onDragUpdate { [weak self] _, dx, dy in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.yaw = self.dragStart.yaw + dx / 120
                self.pitch = min(max(self.dragStart.pitch + dy / 120, -1.5), 1.5)
                self.widget.queueDraw()
            }
        }
        widget.add(controller: drag)

        let scroll = EventControllerScroll(flags: .vertical)
        scroll.onScroll { [weak self] _, _, dy in
            MainActor.assumeIsolated {
                guard let self else { return false }
                self.zoom = min(max(self.zoom * (dy > 0 ? 0.9 : 1.1), 0.2), 8)
                self.widget.queueDraw()
                return true
            }
        }
        widget.add(controller: scroll)
    }

    private func draw(on ctx: Cairo.ContextRef, width: Double, height: Double) {
        let cr: UnsafeMutablePointer<cairo_t> = ctx._ptr
        let (cy, sy, cp, sp) = (cos(yaw), sin(yaw), cos(pitch), sin(pitch))
        let rotated = positions.map { p -> SIMD3<Double> in
            let x = p.x * cy + p.z * sy
            let z = -p.x * sy + p.z * cy
            return SIMD3(x, p.y * cp - z * sp, p.y * sp + z * cp)
        }
        let scale = min(width, height) * 0.38 * zoom
        func project(_ p: SIMD3<Double>) -> (Double, Double) { (width / 2 + p.x * scale, height / 2 - p.y * scale) }
        let light = SIMD3(0.3, 0.5, 0.8) / (SIMD3(0.3, 0.5, 0.8) * SIMD3(0.3, 0.5, 0.8)).sum().squareRoot()
        let ordered = triangles.sorted { rotated[$0.0].z + rotated[$0.1].z + rotated[$0.2].z < rotated[$1.0].z + rotated[$1.1].z + rotated[$1.2].z }
        for (a, b, c) in ordered {
            let u = rotated[b] - rotated[a]
            let v = rotated[c] - rotated[a]
            var normal = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
            let length = (normal * normal).sum().squareRoot()
            guard length > 0 else { continue }
            normal /= length
            let shade = 0.25 + 0.75 * abs((normal * light).sum())
            let tint = (colors[a] + colors[b] + colors[c]) / 3 * shade
            let points = [a, b, c].map { project(rotated[$0]) }
            cairo_move_to(cr, points[0].0, points[0].1)
            cairo_line_to(cr, points[1].0, points[1].1)
            cairo_line_to(cr, points[2].0, points[2].1)
            cairo_close_path(cr)
            cairo_set_source_rgb(cr, tint.x, tint.y, tint.z)
            cairo_fill_preserve(cr)
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
        }
    }
}

@MainActor
private final class WaveformArea: DrawnArea {
    let widget: DrawingArea

    init(sound: PatternVisualization.Sound) {
        widget = DrawingArea()
        widget.setSizeRequest(width: 600, height: 150)
        let envelope = Self.envelope(of: sound, columns: 600)
        widget.setDrawFunc { _, ctx, width, height in
            let cr: UnsafeMutablePointer<cairo_t> = ctx._ptr
            let laneHeight = Double(height) / Double(max(envelope.count, 1))
            let columnWidth = Double(width) / Double(max(envelope.first?.count ?? 1, 1))
            plotAccent.setSource(on: cr)
            cairo_set_line_width(cr, 1)
            for (channel, columns) in envelope.enumerated() {
                let middle = laneHeight * (Double(channel) + 0.5)
                for (column, range) in columns.enumerated() {
                    let x = (Double(column) + 0.5) * columnWidth
                    cairo_move_to(cr, x, middle - Double(range.upperBound) * laneHeight / 2)
                    cairo_line_to(cr, x, middle - Double(range.lowerBound) * laneHeight / 2 + 0.5)
                }
            }
            cairo_stroke(cr)
        }
    }

    private static func envelope(of sound: PatternVisualization.Sound, columns: Int) -> [[ClosedRange<Float>]] {
        let frames = sound.samples.count / sound.channels
        guard frames > 0 else { return [] }
        return (0..<sound.channels).map { channel in
            func sample(_ frame: Int) -> Float {
                Float(sound.samples[frame * sound.channels + channel]) / 32768
            }
            var previous = sample(0)
            return (0..<min(columns, frames)).map { column in
                let first = column * frames / columns
                let end = max(first + 1, (column + 1) * frames / columns)
                var low = previous
                var high = previous
                for frame in first..<end {
                    previous = sample(frame)
                    low = min(low, previous)
                    high = max(high, previous)
                }
                return low...high
            }
        }
    }
}

@MainActor
private final class ClockArea: DrawnArea {
    let widget: DrawingArea

    init(date: Date, calendar: Foundation.Calendar) {
        widget = DrawingArea()
        widget.setSizeRequest(width: 128, height: 128)
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = Double(time.second ?? 0)
        let minutes = Double(time.minute ?? 0) + seconds / 60
        let hours = Double((time.hour ?? 0) % 12) + minutes / 60
        widget.setDrawFunc { [weak widget] _, ctx, width, height in
            MainActor.assumeIsolated {
                guard let widget else { return }
                let cr: UnsafeMutablePointer<cairo_t> = ctx._ptr
                let radius = min(Double(width), Double(height)) / 2 - 1
                let center = (x: Double(width) / 2, y: Double(height) / 2)
                let text = widget.textColor
                func hand(_ turns: Double, from start: Double, to length: Double) {
                    let angle = turns * 2 * .pi
                    cairo_move_to(cr, center.x + sin(angle) * start, center.y - cos(angle) * start)
                    cairo_line_to(cr, center.x + sin(angle) * length, center.y - cos(angle) * length)
                    cairo_stroke(cr)
                }
                text.scalingAlpha(by: 0.5).setSource(on: cr)
                cairo_set_line_width(cr, 1)
                cairo_arc(cr, center.x, center.y, radius, 0, 2 * .pi)
                cairo_stroke(cr)
                for tick in 0..<12 {
                    cairo_set_line_width(cr, tick % 3 == 0 ? 2 : 1)
                    hand(Double(tick) / 12, from: radius * (tick % 3 == 0 ? 0.8 : 0.88), to: radius)
                }
                text.setSource(on: cr)
                cairo_set_line_cap(cr, Cairo.LineCap.round.value)
                cairo_set_line_width(cr, 3)
                hand(hours / 12, from: 0, to: radius * 0.5)
                cairo_set_line_width(cr, 2)
                hand(minutes / 60, from: 0, to: radius * 0.75)
                cairo_set_source_rgb(cr, 0.88, 0.11, 0.14)
                cairo_set_line_width(cr, 1)
                hand(seconds / 60, from: 0, to: radius * 0.85)
            }
        }
    }
}

@MainActor
private final class SignalArea: DrawnArea {
    let widget: DrawingArea

    init(segments: [PatternVisualization.SignalSegment]) {
        widget = DrawingArea()
        widget.setSizeRequest(width: 600, height: 200)
        widget.setDrawFunc { [weak widget] _, ctx, width, height in
            MainActor.assumeIsolated {
                guard let widget else { return }
                Self.draw(segments, on: ctx, width: Double(width), height: Double(height), text: widget.textColor)
            }
        }
    }

    private static func draw(
        _ segments: [PatternVisualization.SignalSegment], on ctx: Cairo.ContextRef, width: Double, height: Double, text: GdkRGBA
    ) {
        let cr: UnsafeMutablePointer<cairo_t> = ctx._ptr
        let totalBits = Double(max(segments.reduce(0) { $0 + $1.bits }, 1))
        let plotHeight = height - 14
        let levels = -0.1...1.1
        func x(_ bit: Int) -> Double { width * Double(bit) / totalBits }
        func y(_ level: Double) -> Double { plotHeight - plotHeight * (level - levels.lowerBound) / (levels.upperBound - levels.lowerBound) }

        cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 11)
        var bit = 0
        var levelPath: [(Double, Double)] = [(x(0), y(0))]
        for (index, segment) in segments.enumerated() {
            let color = PatternPalette.color(for: segment.color.flatMap(PatternTint.init(hex:)) ?? .palette(index))
            let start = x(bit)
            let end = x(bit + segment.bits)
            color.scalingAlpha(by: 0.2).setSource(on: cr)
            cairo_rectangle(cr, start, y(1), end - start, y(0) - y(1))
            cairo_fill(cr)
            let level = segment.isHigh ? 1.0 : 0.0
            levelPath += [(start, y(level)), (end, y(level))]
            color.setSource(on: cr)
            centered(segment.label, x: (start + end) / 2, y: y(0.55), on: cr)
            centered(segment.value, x: (start + end) / 2, y: y(0.40), on: cr)
            text.scalingAlpha(by: 0.6).setSource(on: cr)
            cairo_move_to(cr, start + 2, height - 2)
            cairo_show_text(cr, "\(bit)")
            bit += segment.bits
        }
        levelPath.append((x(bit), y(0)))
        text.setSource(on: cr)
        cairo_set_line_width(cr, 2)
        for (index, point) in levelPath.enumerated() {
            if index == 0 {
                cairo_move_to(cr, point.0, point.1)
            } else {
                cairo_line_to(cr, point.0, point.1)
            }
        }
        cairo_stroke(cr)
    }

    private static func centered(_ text: String, x: Double, y: Double, on cr: UnsafeMutablePointer<cairo_t>) {
        var extents = cairo_text_extents_t()
        cairo_text_extents(cr, text, &extents)
        cairo_move_to(cr, x - extents.x_advance / 2, y + extents.height / 2)
        cairo_show_text(cr, text)
    }
}

extension Widget {
    fileprivate var textColor: GdkRGBA {
        var color = GdkRGBA()
        gtk_widget_get_color(widget_ptr, &color)
        return color
    }
}
