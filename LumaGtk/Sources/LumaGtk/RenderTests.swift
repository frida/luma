import Cairo
import CGtk
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

/// Draws widgets offscreen and says what came out, the way GTK's own tests
/// do: a paintable over the widget, a renderer over that, and a texture to
/// look at. Nothing here needs a pointer or a person.
///
///     LUMA_RENDER_TESTS=<directory> LumaGtk
///
/// Each case writes a PNG and a line of what it found. A case that draws
/// nothing at all is a failure -- most of what has gone wrong in this
/// drawing has been visible at a glance and invisible to a compiler.
@MainActor
enum RenderTests {
    /// Where to write them, when asked. An environment variable rather than
    /// an argument: GTK parses those itself, and does not activate at all on
    /// one it does not know.
    static var asked: String? {
        ProcessInfo.processInfo.environment["LUMA_RENDER_TESTS"]
    }

    /// Plays a snippet in a canvas for a while and says what the process is
    /// holding as it goes, so a leak shows as a line that keeps climbing.
    static func soak(_ snippetPath: String, seconds: Int) -> Int32 {
        guard let snippet = try? String(contentsOfFile: snippetPath, encoding: .utf8),
              let scene = sceneFromTheImage(evaluating: snippet)
        else {
            say("soak: the image did not answer a scene")
            return 1
        }

        let canvas = PharoCanvasArea(scene: scene)
        let window = Window()
        window.setDefaultSize(width: 480, height: 640)
        window.set(child: canvas.widget)
        window.present()

        for tick in 0...(seconds / 10) {
            settle(for: 10_000)
            // What the snippet is doing, so a flat line is not mistaken for
            // a loop that died.
            // What the snippet moves, it moves with drivers: the declared
            // value stays where it started by design.
            let moving = CanvasRegistry.shared.scene(scene)?.ordered
                .compactMap { $0.drivers.first { $0.name == "at" }?.to.last }
                .map { String(format: "%.2f", $0) }
                .joined(separator: " ") ?? ""
            say("t+\(tick * 10)s  rss \(resident()) MB  scenes \(CanvasRegistry.shared.sceneCount)"
                + "  atlases \(GlyphAtlasRasteriser.count)  at \(moving)")
        }
        window.close()
        return 0
    }

    private static func resident() -> Int {
        #if canImport(Darwin)
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
            let answer = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return answer == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : 0
        #else
            // statm counts pages, and the resident set is its second field.
            let fields = (try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8))?
                .split(separator: " ") ?? []
            let pages = fields.count > 1 ? Int(fields[1]) ?? 0 : 0
            return pages * Int(getpagesize()) / 1_048_576
        #endif
    }

    static func run(writingTo directory: String) -> Int32 {
        let cases: [(name: String, effect: ShaderEffect, size: (width: Int, height: Int))] = [
            ("welcome-backdrop", ShaderEffect(fragmentSource: ShaderEffects.welcomeBackdrop),
             (480, 320)),
            ("event-field", ShaderEffect(fragmentSource: ShaderEffects.eventField), (480, 24)),
            ("lettering", lettering(), (480, 160)),
        ]

        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        var failures = fromTheImage(writingTo: directory)

        for probe in cases {
            let coverage = draw(
                probe.effect, width: probe.size.width, height: probe.size.height,
                to: "\(directory)/\(probe.name).png")
            // Anything at all beats nothing: what has gone wrong in this
            // drawing has been a blank frame, not a subtly wrong one.
            if coverage <= 0 {
                failures += 1
            }
            let marked = String(format: "%.2f%%", coverage * 100)
            say("\(probe.name): \(coverage > 0 ? "drew" : "DREW NOTHING"), \(marked) marked")
        }
        return failures
    }

    /// The same again, but built by the image rather than here: what the
    /// examples actually do, through the bindings, the bridge and the
    /// canvas view.
    private static func fromTheImage(writingTo directory: String) -> Int32 {
        guard let scene = sceneFromTheImage() else {
            say("pharo-lettering: NO SCENE, the image did not answer one")
            return 1
        }

        let canvas = PharoCanvasArea(scene: scene)
        let coverage = draw(
            canvas.area, showing: canvas.widget, width: 480, height: 160,
            to: "\(directory)/pharo-lettering.png")
        let marked = String(format: "%.2f%%", coverage * 100)
        say("pharo-lettering: \(coverage > 0 ? "drew" : "DREW NOTHING"), \(marked) marked")
        return coverage > 0 ? 0 : 1
    }

    /// Asks the image for a lettered scene and answers which one, letting the
    /// loop run while it boots -- it answers on the same thread the drawing
    /// happens on.
    private static func sceneFromTheImage(evaluating snippet: String = letteringSnippet) -> Int? {
        final class Answer {
            var scene: Int?
            var settled = false
        }

        let answer = Answer()
        Task { @MainActor in
            defer { answer.settled = true }
            PharoRuntime.bootBundledImage()
            try? await PharoRuntime.shared.runningState()
            try? await PharoLumaBindings.install(into: PharoRuntime.shared)
            // A snippet may ask the host what it knows; nothing has published
            // any of it here.
            for feed in PharoHostFeed.allCases {
                PharoHostBridge.shared.publish([], as: feed)
            }
            let handle = try? await PharoRuntime.shared.evaluate(snippet)
            answer.scene = handle.flatMap { Int($0.printString.trimmingCharacters(in: .whitespaces)) }
        }

        // Booting an image takes a while, and none of it happens unless the
        // loop is running.
        for _ in 0..<60 where !answer.settled {
            settle(for: 500)
        }
        return answer.scene
    }

    private static let letteringSnippet = """
        | canvas sign |
        canvas := LumaCanvas new.
        sign := LumaText on: canvas addDrawable pointSize: 34.
        sign pad: #(20 18) tint: #(0.2 0.95 0.75); show: 'GTK'.
        canvas handle
        """

    /// A scene of the kind the image builds: lettering over the atlas the
    /// host rasterised, which is what the examples lean on.
    private static func lettering() -> ShaderEffect {
        let effect = ShaderEffect()
        effect.setClearColor(red: 0.05, green: 0.02, blue: 0.09)

        let atlas = GlyphAtlasRasteriser.make(pixelSize: 48)
        guard let sheet = GlyphAtlasRasteriser.atlas(atlas) else { return effect }

        let drawable = effect.addDrawable()
        effect.setProgram(
            drawable,
            vertex: CanvasGeometry(
                attributes: [ShaderAttribute(name: "p", components: 2),
                             ShaderAttribute(name: "glyph", components: 2)],
                varyings: [ShaderAttribute(name: "uv", components: 2)])
                .vertexPreamble(.openGL, uniforms: uniforms(of: sheet), images: [picture(of: sheet)])
                + vertexBody,
            fragment: CanvasGeometry(
                attributes: [ShaderAttribute(name: "p", components: 2),
                             ShaderAttribute(name: "glyph", components: 2)],
                varyings: [ShaderAttribute(name: "uv", components: 2)])
                .fragmentPreamble(.openGL, uniforms: uniforms(of: sheet), images: [picture(of: sheet)])
                + fragmentBody)
        effect.addAttribute(drawable, name: "p", components: 2)
        effect.addAttribute(drawable, name: "glyph", components: 2)
        for uniform in uniforms(of: sheet) {
            effect.setUniform(drawable, name: uniform.name, values: uniform.values)
        }
        effect.setImage(
            drawable, name: "glyphs", pixels: sheet.pixels,
            width: sheet.width, height: sheet.height)
        effect.setVertices(drawable, corners(for: "HELLO", in: sheet), primitive: .triangles)
        return effect
    }

    private static func uniforms(of sheet: GlyphAtlas) -> [CanvasUniform] {
        [
            CanvasUniform(name: "pad", values: [16, 16]),
            CanvasUniform(name: "size", values: [Float(sheet.cellHeight)]),
            CanvasUniform(name: "tint", values: [1, 0.95, 0.8]),
        ]
    }

    private static func picture(of sheet: GlyphAtlas) -> CanvasImage {
        CanvasImage(
            name: "glyphs", pixels: sheet.pixels,
            width: sheet.width, height: sheet.height, stamp: 1)
    }

    /// As `LumaText` lays a string out, in cells.
    private static func corners(for text: String, in sheet: GlyphAtlas) -> [Float] {
        let cell = Float(sheet.cellHeight)
        let band = Float(sheet.inkBottom - sheet.inkTop)
        var vertices: [Float] = []
        var pen: Float = 0
        for character in text.unicodeScalars {
            let code = Int(character.value)
            guard code >= GlyphAtlas.first, code <= GlyphAtlas.last else { continue }

            let index = code - GlyphAtlas.first
            let originX = Float(index % sheet.columns * sheet.cellWidth)
            let originY = Float(index / sheet.columns * sheet.cellHeight)
            let wide = Float(sheet.cellWidth) / cell
            let high = band / cell
            for corner in [(0, 0), (1, 0), (0, 1), (1, 0), (1, 1), (0, 1)] {
                let x = Float(corner.0)
                let y = Float(corner.1)
                vertices += [
                    pen + x * wide,
                    (y - 1) * high,
                    (originX + x * Float(sheet.cellWidth)) / Float(sheet.width),
                    (originY + Float(sheet.inkTop) + (1 - y) * band) / Float(sheet.height),
                ]
            }
            pen += sheet.advance(for: code) / cell
        }
        return vertices
    }

    private static let vertexBody = """
        void main() {
            uv = glyph;
            vec2 pixel = 2.0 / u_resolution;
            vec2 origin = vec2(-1.0, 1.0) + vec2(pad.x, -pad.y) * pixel;
            gl_Position = vec4(origin + p * size * pixel, 0.15, 1.0);
        }
        """

    private static let fragmentBody = """
        void main() {
            float ink = texture(glyphs, uv).a;
            if (ink < 0.02) discard;
            frag_color = vec4(tint * ink, ink);
        }
        """

    /// Answers how much of the frame the widget marked, so a case that drew
    /// nothing is told apart from one that drew.
    private static func draw(
        _ effect: ShaderEffect,
        showing: Widget? = nil,
        width: Int,
        height: Int,
        to path: String
    ) -> Double {
        let window = Window()
        window.setDefaultSize(width: width, height: height)
        // What goes in the window is not always the area itself: a canvas
        // keeps its own inside a box, and a widget has one parent.
        window.set(child: showing ?? effect.widget)
        window.present()

        // A frame only comes round while the loop is running, and the widget
        // keeps the one it is asked for.
        effect.wantsCapture = true
        settle(for: 900)
        window.close()

        guard let frame = effect.captured else { return 0 }
        write(frame, to: path)
        return coverage(of: frame)
    }

    /// Lets the loop run for a while, so what was presented gets painted.
    private static func settle(for milliseconds: Int) {
        let loop = g_main_loop_new(nil, gboolean(0))
        g_timeout_add(
            guint(milliseconds),
            { data in
                g_main_loop_quit(data?.assumingMemoryBound(to: GMainLoop.self))
                return gboolean(0)
            },
            UnsafeMutableRawPointer(loop))
        g_main_loop_run(loop)
        g_main_loop_unref(loop)
    }

    /// Whatever came back, the right way up: a frame is read from the bottom
    /// and written from the top.
    private static func write(_ frame: (pixels: [UInt8], width: Int, height: Int), to path: String) {
        var upright = [UInt8](repeating: 0, count: frame.pixels.count)
        let stride = frame.width * 4
        for row in 0..<frame.height {
            let source = (frame.height - 1 - row) * stride
            upright[(row * stride)..<((row + 1) * stride)] =
                frame.pixels[source..<(source + stride)]
        }
        upright.withUnsafeMutableBytes { raw in
            let surface = cairo_image_surface_create_for_data(
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                Cairo.Format.argb32.value,
                Int32(frame.width), Int32(frame.height), Int32(stride))
            cairo_surface_write_to_png(surface, path)
            cairo_surface_destroy(surface)
        }
    }

    /// The share of pixels that differ from the one in the corner.
    private static func coverage(of frame: (pixels: [UInt8], width: Int, height: Int)) -> Double {
        let corner = Array(frame.pixels[0..<3])
        var marked = 0
        for index in stride(from: 0, to: frame.pixels.count, by: 4)
        where Array(frame.pixels[index..<(index + 3)]) != corner {
            marked += 1
        }
        return Double(marked) / Double(frame.width * frame.height)
    }
}

/// Says a line straight down the descriptor, so what a run found arrives as
/// it happens rather than whenever a buffer fills.
private func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
