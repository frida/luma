import CGtk
@preconcurrency import CLuma
import Foundation
import GLib
import Gtk
import LumaCore

/// A GL widget that draws either a screen-filling fragment effect or a scene
/// of the author's own drawables, redrawing off the frame clock.
///
/// The GL entry points come from epoxy, which resolves them at run time: the
/// plain `gl*` spellings are macros, so what is written here is what Swift can
/// see, and they are mutable globals, which is what the import concedes.
@MainActor
final class ShaderEffect {
    let widget: GLArea

    /// Seconds for a reported arrival to fall to 1/e.
    private static let pulseHalfLife: Float = 0.4
    private static let activityHalfLife: Float = 1.2

    /// The screen-filling effect, when the widget is showing one of those.
    private let fragmentSource: String?
    private var screen: ScreenFilling?
    private var drawables: [Drawable] = []
    private var nextHandle: Int32 = 1

    private var startedAt: gint64 = 0
    private var renderedAt: gint64 = 0
    private var pulsedAt: gint64 = 0
    private var scheme: Float = 1
    private var activity: Float = 0
    private var data = [Float](repeating: 0, count: 64)
    private var dataCount = 0
    private var transform = CanvasDrawable.identity
    private var clearColor: (red: Float, green: Float, blue: Float) = (0, 0, 0)
    /// Set to have the next frame kept, which is how the render tests see
    /// what was drawn: a widget's own framebuffer, read where it is bound.
    var wantsCapture = false
    private(set) var captured: (pixels: [UInt8], width: Int, height: Int)?

    /// Pass no source to make a widget that draws a scene rather than a
    /// screen-filling effect.
    init(fragmentSource: String? = nil) {
        self.fragmentSource = fragmentSource

        widget = GLArea()
        // Geometry with any depth to it needs this, and a screen-filling
        // effect is no worse off for having it.
        widget.hasDepthBuffer = true
        widget.hasStencilBuffer = false
        widget.autoRender = true

        widget.onRealize { [weak self] _ in
            MainActor.assumeIsolated { self?.realize() }
        }
        widget.onUnrealize { [weak self] _ in
            MainActor.assumeIsolated { self?.unrealize() }
        }
        widget.onRender { [weak self] _, _ in
            MainActor.assumeIsolated { self?.render() ?? false }
        }
        gtk_widget_add_tick_callback(
            widget.widget_ptr!,
            { widget, _, _ in
                gtk_gl_area_queue_render(
                    UnsafeMutableRawPointer(widget!).assumingMemoryBound(to: GtkGLArea.self))
                return gboolean(1)
            },
            nil, nil)
    }

    /// A widget draws as many of these as the author made, in the order they
    /// were added, instead of a screen-filling quad.
    func addDrawable() -> Int32 {
        let drawable = Drawable(handle: nextHandle)
        nextHandle += 1
        drawables.append(drawable)
        return drawable.handle
    }

    /// Both sources are complete GLSL: the caller writes the declarations
    /// matching the attributes named here.
    func setProgram(_ handle: Int32, vertex: String, fragment: String) {
        guard let drawable = drawable(handle) else { return }

        drawable.vertexSource = vertex
        drawable.fragmentSource = fragment
        drawable.attributes = []
        drawable.changed = true
    }

    func addAttribute(_ handle: Int32, name: String, components: Int) {
        guard let drawable = drawable(handle) else { return }

        drawable.attributes.append(Attribute(name: name, components: components))
        drawable.changed = true
    }

    func setVertices(_ handle: Int32, _ values: [Float], primitive: CanvasGeometry.Primitive) {
        guard let drawable = drawable(handle) else { return }

        drawable.vertices = values
        drawable.primitive = primitive
        drawable.changed = true
    }

    /// A uniform the author named, of whatever width they asked for.
    func setUniform(_ handle: Int32, name: String, values: [Float]) {
        guard let drawable = drawable(handle) else { return }

        if let existing = drawable.params.firstIndex(where: { $0.name == name }) {
            drawable.params[existing].values = Array(values.prefix(16))
            return
        }
        var param = Param(name: name)
        param.values = Array(values.prefix(16))
        drawable.params.append(param)
        drawable.changed = true
    }

    /// A run of values the shader reads by index, held as a texture of the
    /// given side so it can be far larger than a uniform allows.
    func setBuffer(_ handle: Int32, name: String, values: [Float], width: Int, height: Int) {
        guard let drawable = drawable(handle) else { return }

        if let existing = drawable.sheets.firstIndex(where: { $0.name == name }) {
            drawable.sheets[existing].adopt(values: values, width: width, height: height)
            return
        }
        var sheet = Sheet(name: name)
        sheet.adopt(values: values, width: width, height: height)
        drawable.sheets.append(sheet)
        drawable.changed = true
    }

    /// A picture the shader samples across, one word per pixel.
    func setImage(_ handle: Int32, name: String, pixels: [UInt32], width: Int, height: Int) {
        guard let drawable = drawable(handle) else { return }

        if let existing = drawable.pictures.firstIndex(where: { $0.name == name }) {
            drawable.pictures[existing].adopt(pixels: pixels, width: width, height: height)
            return
        }
        var picture = Picture(name: name)
        picture.adopt(pixels: pixels, width: width, height: height)
        drawable.pictures.append(picture)
        drawable.changed = true
    }

    /// What a named value should do over time. Worked out on the frame clock,
    /// so the caller says it once.
    func drive(
        _ handle: Int32,
        name: String,
        kind: CanvasDriver.Kind,
        from: [Float],
        to: [Float],
        seconds: Float
    ) {
        guard let drawable = drawable(handle) else { return }

        let at = drawable.params.firstIndex(where: { $0.name == name }) ?? {
            drawable.params.append(Param(name: name))
            drawable.changed = true
            return drawable.params.count - 1
        }()
        drawable.params[at].drive(kind: kind, from: from, to: to, seconds: seconds)
    }

    /// Where the author's vertices land: sixteen floats, column-major.
    func setTransform(_ handle: Int32, _ values: [Float]) {
        drawable(handle)?.transform = values
    }

    func setVisible(_ handle: Int32, _ visible: Bool) {
        drawable(handle)?.isVisible = visible
    }

    func removeDrawable(_ handle: Int32) {
        drawables.removeAll { $0.handle == handle }
    }

    /// Feed u_scheme, by convention 1 for light and 0 for dark.
    func setScheme(_ value: Float) {
        scheme = value
    }

    /// Report that events arrived at the given 0..1 rate. Feeds u_activity and
    /// spikes u_pulse; both decay here, so a caller only calls when there is
    /// news.
    func reportActivity(_ rate: Float) {
        activity = rate
        pulsedAt = g_get_monotonic_time()
    }

    /// Feed u_data and u_data_count, which is how a caller pictures something
    /// it has measured.
    func setData(_ values: [Float]) {
        data = Array(values.prefix(64))
        data.append(contentsOf: repeatElement(0, count: 64 - data.count))
        dataCount = min(values.count, 64)
    }

    /// Feed u_mvp: orthographic for a flat drawing, perspective for one with
    /// depth.
    func setTransform(_ values: [Float]) {
        transform = values
    }

    /// Colour shown until the effect's program has linked.
    func setClearColor(red: Float, green: Float, blue: Float) {
        clearColor = (red, green, blue)
    }

    private func realize() {
        widget.makeCurrent()
        guard widget.getError() == nil else { return }

        startedAt = g_get_monotonic_time()
        renderedAt = startedAt

        // A widget made for a scene has no screen-filling source to link.
        guard let fragmentSource else { return }

        let gles = widget.context?.api.contains(.gles) ?? false
        screen = ScreenFilling(fragmentSource: fragmentSource, gles: gles)
    }

    private func unrealize() {
        widget.makeCurrent()
        screen = nil
        for drawable in drawables {
            drawable.releaseResources()
        }
    }

    private func render() -> Bool {
        let scale = Float(widget.scaleFactor)
        let width = Float(widget.width) * scale
        let height = Float(widget.height) * scale

        let now = g_get_monotonic_time()
        let elapsed = Float(now - startedAt) / 1_000_000
        let sincePulse = Float(now - pulsedAt) / 1_000_000
        let pulse = pulsedAt == 0 ? 0 : expf(-sincePulse / Self.pulseHalfLife)
        let sinceRender = Float(now - renderedAt) / 1_000_000
        renderedAt = now
        activity *= expf(-sinceRender / Self.activityHalfLife)

        let showing = drawables.filter(\.isVisible)

        epoxy_glClearColor(clearColor.red, clearColor.green, clearColor.blue, 1)
        if showing.isEmpty {
            epoxy_glDisable(GLenum(GL_DEPTH_TEST))
            epoxy_glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        } else {
            epoxy_glEnable(GLenum(GL_DEPTH_TEST))
            // Premultiplied: what a drawable leaves transparent shows what it
            // was drawn over, rather than coming out black.
            epoxy_glEnable(GLenum(GL_BLEND))
            epoxy_glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA))
            epoxy_glClear(GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT))
        }

        guard showing.isEmpty else {
            for drawable in showing {
                draw(drawable, now: now, width: width, height: height, elapsed: elapsed, pulse: pulse)
            }
            epoxy_glUseProgram(0)
            capture(width: width, height: height)
            return true
        }

        guard let screen else {
            capture(width: width, height: height)
            return false
        }

        epoxy_glUseProgram(screen.program)
        feedUniforms(
            screen.locations, transform: transform,
            width: width, height: height, elapsed: elapsed, pulse: pulse)
        epoxy_glBindVertexArray(screen.vao)
        epoxy_glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
        epoxy_glBindVertexArray(0)
        epoxy_glUseProgram(0)
        capture(width: width, height: height)
        return true
    }

    /// Reads the frame back out of whatever is bound, which inside a render
    /// is the area's own buffer.
    private func capture(width: Float, height: Float) {
        guard wantsCapture else { return }
        wantsCapture = false

        let wide = Int(width)
        let high = Int(height)
        var pixels = [UInt8](repeating: 0, count: wide * high * 4)
        pixels.withUnsafeMutableBytes { raw in
            epoxy_glReadPixels(
                0, 0, GLsizei(wide), GLsizei(high),
                GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), raw.baseAddress)
        }
        captured = (pixels, wide, high)
    }

    private func draw(
        _ drawable: Drawable,
        now: gint64,
        width: Float,
        height: Float,
        elapsed: Float,
        pulse: Float
    ) {
        if drawable.changed {
            drawable.rebuild()
        }
        guard drawable.program != 0, !drawable.vertices.isEmpty, drawable.stride != 0 else { return }

        epoxy_glUseProgram(drawable.program)
        drawable.bindTextures()
        drawable.feedParams(now: now)
        feedUniforms(
            drawable.locations, transform: drawable.transform,
            width: width, height: height, elapsed: elapsed, pulse: pulse)
        epoxy_glBindVertexArray(drawable.vao)
        epoxy_glDrawArrays(
            drawable.primitive.glPrimitive, 0, GLsizei(drawable.vertices.count / drawable.stride))
        epoxy_glBindVertexArray(0)
    }

    private func feedUniforms(
        _ locations: Locations,
        transform: [Float],
        width: Float,
        height: Float,
        elapsed: Float,
        pulse: Float
    ) {
        epoxy_glUniform1f(locations.scale, Float(widget.scaleFactor))
        epoxy_glUniform2f(locations.resolution, width, height)
        epoxy_glUniform1f(locations.time, elapsed)
        epoxy_glUniform1f(locations.scheme, scheme)
        epoxy_glUniform1f(locations.activity, activity)
        epoxy_glUniform1f(locations.pulse, pulse)
        epoxy_glUniform1f(locations.dataCount, Float(dataCount))
        epoxy_glUniform4fv(locations.data, 16, data)
        epoxy_glUniformMatrix4fv(locations.mvp, 1, GLboolean(GL_FALSE), transform)
    }

    private func drawable(_ handle: Int32) -> Drawable? {
        drawables.first { $0.handle == handle }
    }
}

/// Where a linked program keeps the values every effect is fed.
struct Locations {
    var resolution: GLint = -1
    var time: GLint = -1
    var scheme: GLint = -1
    var activity: GLint = -1
    var pulse: GLint = -1
    var dataCount: GLint = -1
    var scale: GLint = -1
    var data: GLint = -1
    var mvp: GLint = -1

    init() {}

    init(program: GLuint) {
        resolution = program.location("u_resolution")
        time = program.location("u_time")
        scheme = program.location("u_scheme")
        activity = program.location("u_activity")
        pulse = program.location("u_pulse")
        dataCount = program.location("u_data_count")
        scale = program.location("u_scale")
        data = program.location("u_data")
        mvp = program.location("u_mvp")
    }
}

/// One value per vertex, named by whoever wrote the shader.
private struct Attribute {
    let name: String
    let components: Int
}

/// A uniform the author named. OpenGL takes them loose, so each is set by the
/// name it was given.
private struct Param {
    let name: String
    var values: [Float] = []
    var location: GLint = -1
    /// Set when the value is moving on its own: worked out on the frame clock
    /// rather than pushed from whoever owns the scene.
    var driver: CanvasDriver?
    var startedAt: gint64 = 0

    init(name: String) {
        self.name = name
    }

    mutating func drive(kind: CanvasDriver.Kind, from: [Float], to: [Float], seconds: Float) {
        driver = CanvasDriver(name: name, kind: kind, from: from, to: to, seconds: seconds)
        startedAt = g_get_monotonic_time()
        values = from
    }

    mutating func feed(now: gint64) {
        guard location >= 0 else { return }

        if let driver {
            values = driver.value(after: Float(now - startedAt) / 1_000_000)
        }
        switch values.count {
        case 1: epoxy_glUniform1fv(location, 1, values)
        case 2: epoxy_glUniform2fv(location, 1, values)
        case 3: epoxy_glUniform3fv(location, 1, values)
        case 16: epoxy_glUniformMatrix4fv(location, 1, GLboolean(GL_FALSE), values)
        default: epoxy_glUniform4fv(location, 1, values)
        }
    }
}

/// A run of values the shader reads by index, held as a texture so it can be
/// far larger than a uniform allows.
private struct Sheet {
    let name: String
    var values: [Float] = []
    var width = 0
    var height = 0
    var texture: GLuint = 0
    var location: GLint = -1
    var isDirty = false

    init(name: String) {
        self.name = name
    }

    mutating func adopt(values: [Float], width: Int, height: Int) {
        self.values = values
        self.width = width
        self.height = height
        isDirty = true
    }

    /// Nearest, clamped: a value is read at its own index, never blended with
    /// a neighbour's.
    mutating func bind(unit: Int) {
        guard location >= 0, !values.isEmpty else { return }

        if texture == 0 {
            epoxy_glGenTextures(1, &texture)
        }
        epoxy_glActiveTexture(GLenum(GL_TEXTURE0 + Int32(unit)))
        epoxy_glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        if isDirty {
            texture.clampNearest()
            epoxy_glTexImage2D(
                GLenum(GL_TEXTURE_2D), 0, GL_R32F, GLsizei(width), GLsizei(height), 0,
                GLenum(GL_RED), GLenum(GL_FLOAT), values)
            isDirty = false
        }
        epoxy_glUniform1i(location, GLint(unit))
    }
}

/// A picture the shader samples across, one word per pixel, in the order the
/// caller holds them.
private struct Picture {
    let name: String
    var pixels: [UInt32] = []
    var width = 0
    var height = 0
    var texture: GLuint = 0
    var location: GLint = -1
    var isDirty = false

    init(name: String) {
        self.name = name
    }

    mutating func adopt(pixels: [UInt32], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
        isDirty = true
    }

    mutating func bind(unit: Int) {
        guard location >= 0, !pixels.isEmpty else { return }

        if texture == 0 {
            epoxy_glGenTextures(1, &texture)
        }
        epoxy_glActiveTexture(GLenum(GL_TEXTURE0 + Int32(unit)))
        epoxy_glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        if isDirty {
            texture.clampSmooth()
            epoxy_glTexImage2D(
                GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(width), GLsizei(height), 0,
                GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), pixels)
            isDirty = false
        }
        epoxy_glUniform1i(location, GLint(unit))
    }
}

/// One thing the widget draws, with its own stages, vertices and place. A
/// scene is however many of these the author made.
@MainActor
private final class Drawable {
    let handle: Int32
    var isVisible = true
    var changed = false
    var vertexSource = ""
    var fragmentSource = ""
    var attributes: [Attribute] = []
    var vertices: [Float] = []
    var primitive: CanvasGeometry.Primitive = .triangles
    var transform = CanvasDrawable.identity
    var params: [Param] = []
    var sheets: [Sheet] = []
    var pictures: [Picture] = []
    private(set) var program: GLuint = 0
    private(set) var vao: GLuint = 0
    private(set) var locations = Locations()
    private var vbo: GLuint = 0

    init(handle: Int32) {
        self.handle = handle
    }

    /// Floats per vertex.
    var stride: Int {
        attributes.reduce(0) { $0 + $1.components }
    }

    /// Lays the author's own attributes out over their vertices, binding each
    /// by the name they gave it, so their shader needs no layout qualifier
    /// that the GLSL version here would refuse.
    func rebuild() {
        changed = false
        guard !vertexSource.isEmpty, !vertices.isEmpty else { return }

        if program != 0 {
            epoxy_glDeleteProgram(program)
        }
        program = link()
        guard program != 0 else { return }

        locations = Locations(program: program)
        for at in params.indices {
            params[at].location = program.location(params[at].name)
        }
        for at in sheets.indices {
            sheets[at].location = program.location(sheets[at].name)
            sheets[at].isDirty = true
        }
        for at in pictures.indices {
            pictures[at].location = program.location(pictures[at].name)
            pictures[at].isDirty = true
        }

        if vao == 0 {
            epoxy_glGenVertexArrays(1, &vao)
        }
        if vbo == 0 {
            epoxy_glGenBuffers(1, &vbo)
        }
        epoxy_glBindVertexArray(vao)
        epoxy_glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        epoxy_glBufferData(
            GLenum(GL_ARRAY_BUFFER), vertices.count * MemoryLayout<Float>.stride,
            vertices, GLenum(GL_STATIC_DRAW))

        var offset = 0
        for (index, attribute) in attributes.enumerated() {
            epoxy_glEnableVertexAttribArray(GLuint(index))
            epoxy_glVertexAttribPointer(
                GLuint(index), GLint(attribute.components), GLenum(GL_FLOAT), GLboolean(GL_FALSE),
                GLsizei(stride * MemoryLayout<Float>.stride),
                UnsafeRawPointer(bitPattern: offset * MemoryLayout<Float>.stride))
            offset += attribute.components
        }
        epoxy_glBindVertexArray(0)
    }

    /// The runs of values first, then the pictures, which is the order the
    /// generated declarations bind them in.
    func bindTextures() {
        for at in sheets.indices {
            sheets[at].bind(unit: at)
        }
        for at in pictures.indices {
            pictures[at].bind(unit: sheets.count + at)
        }
        epoxy_glActiveTexture(GLenum(GL_TEXTURE0))
    }

    func feedParams(now: gint64) {
        for at in params.indices {
            params[at].feed(now: now)
        }
    }

    func releaseResources() {
        if program != 0 {
            epoxy_glDeleteProgram(program)
            program = 0
        }
        if vbo != 0 {
            epoxy_glDeleteBuffers(1, &vbo)
            vbo = 0
        }
        if vao != 0 {
            epoxy_glDeleteVertexArrays(1, &vao)
            vao = 0
        }
        for at in sheets.indices where sheets[at].texture != 0 {
            epoxy_glDeleteTextures(1, &sheets[at].texture)
            sheets[at].texture = 0
        }
        for at in pictures.indices where pictures[at].texture != 0 {
            epoxy_glDeleteTextures(1, &pictures[at].texture)
            pictures[at].texture = 0
        }
    }

    private func link() -> GLuint {
        guard let vertex = GLuint.compile(GLenum(GL_VERTEX_SHADER), vertexSource),
              let fragment = GLuint.compile(GLenum(GL_FRAGMENT_SHADER), fragmentSource)
        else { return 0 }

        return GLuint.link(vertex: vertex, fragment: fragment) { program in
            for (index, attribute) in attributes.enumerated() {
                epoxy_glBindAttribLocation(program, GLuint(index), attribute.name)
            }
        }
    }
}

/// The screen-filling effect: the author's fragment source over a quad, with
/// the vertex stage handing down only where on screen the pixel sits.
@MainActor
private final class ScreenFilling {
    private(set) var program: GLuint = 0
    private(set) var vao: GLuint = 0
    private(set) var locations = Locations()
    private var vbo: GLuint = 0

    private static let vertexSource = """
        in vec2 a_pos;
        out vec2 v_uv;
        void main() {
            v_uv = a_pos * 0.5 + 0.5;
            gl_Position = vec4(a_pos, 0.0, 1.0);
        }
        """

    private static let fragmentPreamble = """
        in vec2 v_uv;
        out vec4 frag_color;
        uniform vec2 u_resolution;
        uniform float u_time;
        uniform float u_scheme;
        uniform float u_activity;
        uniform float u_pulse;
        uniform float u_data_count;
        uniform float u_scale;
        uniform vec4 u_data[16];
        uniform mat4 u_mvp;
        float dataAt(int i) { return u_data[i >> 2][i & 3]; }

        """

    private static let quad: [Float] = [-1, -1, 1, -1, -1, 1, 1, 1]

    init(fragmentSource: String, gles: Bool) {
        let version = gles ? "#version 300 es\nprecision highp float;\n" : "#version 150 core\n"
        guard let vertex = GLuint.compile(GLenum(GL_VERTEX_SHADER), version + Self.vertexSource),
              let fragment = GLuint.compile(
                  GLenum(GL_FRAGMENT_SHADER), version + Self.fragmentPreamble + fragmentSource)
        else { return }

        program = GLuint.link(vertex: vertex, fragment: fragment) { program in
            epoxy_glBindAttribLocation(program, 0, "a_pos")
        }
        guard program != 0 else { return }
        locations = Locations(program: program)

        epoxy_glGenVertexArrays(1, &vao)
        epoxy_glBindVertexArray(vao)
        epoxy_glGenBuffers(1, &vbo)
        epoxy_glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        epoxy_glBufferData(
            GLenum(GL_ARRAY_BUFFER), Self.quad.count * MemoryLayout<Float>.stride,
            Self.quad, GLenum(GL_STATIC_DRAW))
        epoxy_glEnableVertexAttribArray(0)
        epoxy_glVertexAttribPointer(0, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 0, nil)
        epoxy_glBindVertexArray(0)
    }

    deinit {
        if vbo != 0 {
            epoxy_glDeleteBuffers(1, &vbo)
        }
        if vao != 0 {
            epoxy_glDeleteVertexArrays(1, &vao)
        }
        if program != 0 {
            epoxy_glDeleteProgram(program)
        }
    }
}

extension GLuint {
    static func link(
        vertex: GLuint,
        fragment: GLuint,
        bindAttributes: (GLuint) -> Void
    ) -> GLuint {
        let program = epoxy_glCreateProgram()
        epoxy_glAttachShader(program, vertex)
        epoxy_glAttachShader(program, fragment)
        bindAttributes(program)
        epoxy_glLinkProgram(program)
        epoxy_glDetachShader(program, vertex)
        epoxy_glDetachShader(program, fragment)
        epoxy_glDeleteShader(vertex)
        epoxy_glDeleteShader(fragment)

        var ok: GLint = 0
        epoxy_glGetProgramiv(program, GLenum(GL_LINK_STATUS), &ok)
        guard ok != 0 else {
            report("program link failed", program.log(epoxy_glGetProgramInfoLog))
            epoxy_glDeleteProgram(program)
            return 0
        }
        return program
    }

    static func compile(_ kind: GLenum, _ source: String) -> GLuint? {
        let shader = epoxy_glCreateShader(kind)
        source.withCString { text in
            var sources: [UnsafePointer<GLchar>?] = [text]
            epoxy_glShaderSource(shader, 1, &sources, nil)
        }
        epoxy_glCompileShader(shader)

        var ok: GLint = 0
        epoxy_glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &ok)
        guard ok != 0 else {
            report("shader compile failed", shader.log(epoxy_glGetShaderInfoLog))
            epoxy_glDeleteShader(shader)
            return nil
        }
        return shader
    }

    /// What the driver said went wrong, as it words it.
    func log(_ read: (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?, UnsafeMutablePointer<GLchar>?) -> Void) -> String {
        var text = [GLchar](repeating: 0, count: 1024)
        read(self, GLsizei(text.count), nil, &text)
        return String(cString: text)
    }

    func location(_ name: String) -> GLint {
        epoxy_glGetUniformLocation(self, name)
    }

    func clampNearest() {
        clamp(filter: GL_NEAREST)
    }

    func clampSmooth() {
        clamp(filter: GL_LINEAR)
    }

    private func clamp(filter: Int32) {
        epoxy_glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), filter)
        epoxy_glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), filter)
        epoxy_glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        epoxy_glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
    }
}

extension CanvasGeometry.Primitive {
    var glPrimitive: GLenum {
        switch self {
        case .points: return GLenum(GL_POINTS)
        case .lines: return GLenum(GL_LINES)
        case .lineStrip: return GLenum(GL_LINE_STRIP)
        case .triangles: return GLenum(GL_TRIANGLES)
        case .triangleStrip: return GLenum(GL_TRIANGLE_STRIP)
        }
    }
}

private func report(_ what: String, _ detail: String) {
    FileHandle.standardError.write(Data("shader effect: \(what): \(detail)\n".utf8))
}
