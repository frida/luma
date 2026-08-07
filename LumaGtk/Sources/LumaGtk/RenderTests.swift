import Cairo
import CGtk
import Foundation
import Gtk
import LumaCore

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

    static func run(writingTo directory: String) -> Int32 {
        let cases: [(name: String, effect: ShaderEffect, size: (width: Int, height: Int))] = [
            ("welcome-backdrop", ShaderEffect(fragmentSource: ShaderEffects.welcomeBackdrop),
             (480, 320)),
            ("event-field", ShaderEffect(fragmentSource: ShaderEffects.eventField), (480, 24)),
            ("lettering", lettering(), (480, 160)),
        ]

        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        setvbuf(stdout, nil, _IONBF, 0)
        var failures: Int32 = 0
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
            print("\(probe.name): \(coverage > 0 ? "drew" : "DREW NOTHING"), \(marked) marked")
        }
        return failures
    }

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
        width: Int,
        height: Int,
        to path: String
    ) -> Double {
        let window = Window()
        window.setDefaultSize(width: width, height: height)
        window.set(child: effect.widget)
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
                CAIRO_FORMAT_ARGB32,
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
