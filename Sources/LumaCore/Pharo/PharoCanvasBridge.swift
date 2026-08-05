import Foundation
import Synchronization

/// Lets the image put a shader effect on screen and feed it.
///
/// Unlike the synthesiser, which the image reaches through a lock-free queue,
/// a canvas is a window: the exports below hop to the main thread before the
/// frontend hears about it.
/// What a canvas needs to draw: the authored GLSL an OpenGL host takes as it
/// stands, and the Metal a Metal host needs translated from it.
public struct CanvasEffect: Sendable, Equatable {
    public let glsl: String
    public let metal: String
    public let function: String

    /// Set when the author supplied a vertex stage of their own, which is
    /// what turns the canvas from a screen-filling effect into a drawing of
    /// whatever they handed over.
    public var vertexGLSL: String?
    public var vertexMetal: String?
    public var vertexFunction: String?
    public var geometry: CanvasGeometry?
}

@MainActor
public enum PharoCanvasHost {
    /// Set by each frontend to open, feed and close its own canvas.
    public static var onShow: ((CanvasEffect) -> Void)?
    public static var onReport: ((Float) -> Void)?
    public static var onData: (([Float]) -> Void)?
    public static var onTransform: (([Float]) -> Void)?
    public static var onClose: (() -> Void)?
}

public enum PharoCanvasBridge {
    /// No Swift caller reaches the exports below, and a static archive only
    /// yields the object files something references -- so without this touch
    /// the linker drops them and the image's dlsym comes up empty.
    public static func ensureExported() {}

    /// Sorted, so an index means the same thing to both sides.
    static let effectNames = ShaderEffects.all.keys.sorted()
}

/// The names the image may ask for, as a JSON array. The image reads strings
/// out of the host readily; handing one back in is what it has no good way to
/// do, so a canvas is chosen by index instead.
@_cdecl("luma_canvas_effect_names")
public func luma_canvas_effect_names() -> UnsafeMutablePointer<CChar>? {
    if canvasNames == nil {
        let json = (try? JSONEncoder().encode(PharoCanvasBridge.effectNames))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        canvasNames = strdup(json)
    }
    return canvasNames
}

private nonisolated(unsafe) var canvasNames: UnsafeMutablePointer<CChar>?

@_cdecl("luma_canvas_show")
public func luma_canvas_show(_ index: Int32) -> Int32 {
    let names = PharoCanvasBridge.effectNames
    guard index >= 0, Int(index) < names.count else { return 0 }
    return present(glsl: ShaderEffects.all[names[Int(index)]]!, named: names[Int(index)])
}

/// Draws GLSL the image wrote itself. Answers 0 and keeps the compiler's
/// complaint for `luma_canvas_last_error` when it will not compile.
@_cdecl("luma_canvas_show_source")
public func luma_canvas_show_source(_ glsl: UnsafePointer<CChar>) -> Int32 {
    present(glsl: String(cString: glsl), named: "userEffect")
}

/// The layout the author is describing, until they commit vertices to it.
private let stagedAttributes = Mutex([ShaderAttribute]())
private let stagedVaryings = Mutex([ShaderAttribute]())
private let stagedSource = Mutex(["", ""])
private let stagedVertices = Mutex([Float]())

@_cdecl("luma_canvas_add_attribute")
public func luma_canvas_add_attribute(_ name: UnsafePointer<CChar>, _ components: Int32, _ isVarying: Int32) {
    let attribute = ShaderAttribute(name: String(cString: name), components: Int(components))
    if isVarying == 1 {
        stagedVaryings.withLock { $0.append(attribute) }
    } else {
        stagedAttributes.withLock { $0.append(attribute) }
    }
}

@_cdecl("luma_canvas_clear_layout")
public func luma_canvas_clear_layout() {
    stagedAttributes.withLock { $0.removeAll() }
    stagedVaryings.withLock { $0.removeAll() }
}

@_cdecl("luma_canvas_set_geometry_source")
public func luma_canvas_set_geometry_source(_ vertex: UnsafePointer<CChar>, _ fragment: UnsafePointer<CChar>) {
    stagedSource.withLock { $0 = [String(cString: vertex), String(cString: fragment)] }
}

/// One value at a time, which suits a handful of vertices written by hand.
@_cdecl("luma_canvas_set_vertex")
public func luma_canvas_set_vertex(_ index: Int32, _ value: Float) {
    guard index >= 0 else { return }
    stagedVertices.withLock { values in
        if values.count <= Int(index) {
            values.append(contentsOf: repeatElement(0, count: Int(index) + 1 - values.count))
        }
        values[Int(index)] = value
    }
}

/// A whole buffer at once, which is the only way a mesh arrives in reasonable
/// time: the image lays the floats out itself and hands over the address.
@_cdecl("luma_canvas_set_vertex_buffer")
public func luma_canvas_set_vertex_buffer(_ values: UnsafePointer<Float>, _ count: Int32) {
    let incoming = UnsafeBufferPointer(start: values, count: Int(max(count, 0)))
    stagedVertices.withLock { $0 = Array(incoming) }
}

/// Builds the author's program against the layout they declared, and draws it.
@_cdecl("luma_canvas_commit_vertices")
public func luma_canvas_commit_vertices(_ count: Int32, _ primitive: Int32) -> Int32 {
    let geometry = CanvasGeometry(
        attributes: stagedAttributes.withLock { $0 },
        varyings: stagedVaryings.withLock { $0 },
        primitive: CanvasGeometry.Primitive(rawValue: primitive) ?? .triangles,
        vertices: stagedVertices.withLock { Array($0.prefix(Int(max(count, 0)))) }
    )
    let source = stagedSource.withLock { $0 }

    let vertexGLSL = geometry.vertexPreamble(.openGL) + source[0]
    let fragmentGLSL = geometry.fragmentPreamble(.openGL) + source[1]
    let vertexMetal: String
    let fragmentMetal: String
    do {
        vertexMetal = try ShaderTranslator.metalSource(
            forComplete: geometry.vertexPreamble(.metal) + source[0],
            stage: .vertex, entryPoint: "canvasVertex")
        fragmentMetal = try ShaderTranslator.metalSource(
            forComplete: geometry.fragmentPreamble(.metal) + source[1],
            stage: .fragment, entryPoint: "canvasFragment")
    } catch {
        canvasError.withLock { $0 = "\(error)" }
        return 0
    }
    canvasError.withLock { $0 = "" }

    var effect = CanvasEffect(glsl: fragmentGLSL, metal: fragmentMetal, function: "canvasFragment")
    effect.vertexGLSL = vertexGLSL
    effect.vertexMetal = vertexMetal
    effect.vertexFunction = "canvasVertex"
    effect.geometry = geometry

    DispatchQueue.main.async {
        MainActor.assumeIsolated { PharoCanvasHost.onShow?(effect) }
    }
    return 1
}

private func present(glsl: String, named name: String) -> Int32 {
    let function = name + "Fragment"
    let metal: String
    do {
        metal = try ShaderTranslator.metalSource(for: glsl, entryPoint: function)
    } catch {
        canvasError.withLock { $0 = "\(error)" }
        return 0
    }
    canvasError.withLock { $0 = "" }

    let effect = CanvasEffect(glsl: glsl, metal: metal, function: function)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { PharoCanvasHost.onShow?(effect) }
    }
    return 1
}

private let canvasError = Mutex("")
private nonisolated(unsafe) var canvasErrorBuffer: UnsafeMutablePointer<CChar>?

/// What the shader compiler said about the last source that would not build.
@_cdecl("luma_canvas_last_error")
public func luma_canvas_last_error() -> UnsafeMutablePointer<CChar>? {
    canvasErrorBuffer.map { free($0) }
    canvasErrorBuffer = strdup(canvasError.withLock { $0 })
    return canvasErrorBuffer
}

/// Values arrive one at a time, then land together: the image has no way to
/// hand over an array, and a scalar call per value is cheap enough for the
/// sixty-four an effect can read.
@_cdecl("luma_canvas_set_data")
public func luma_canvas_set_data(_ index: Int32, _ value: Float) {
    staged.withLock { values in
        guard index >= 0, Int(index) < values.count else { return }
        values[Int(index)] = value
    }
}

@_cdecl("luma_canvas_commit_data")
public func luma_canvas_commit_data(_ count: Int32) {
    let values = staged.withLock { Array($0.prefix(Int(max(count, 0)))) }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { PharoCanvasHost.onData?(values) }
    }
}

private let staged = Mutex([Float](repeating: 0, count: 64))

@_cdecl("luma_canvas_set_transform")
public func luma_canvas_set_transform(_ index: Int32, _ value: Float) {
    stagedTransform.withLock { values in
        guard index >= 0, Int(index) < values.count else { return }
        values[Int(index)] = value
    }
}

@_cdecl("luma_canvas_commit_transform")
public func luma_canvas_commit_transform() {
    let values = stagedTransform.withLock { $0 }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { PharoCanvasHost.onTransform?(values) }
    }
}

private let stagedTransform = Mutex([Float](repeating: 0, count: 16))

@_cdecl("luma_canvas_report")
public func luma_canvas_report(_ activity: Float) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { PharoCanvasHost.onReport?(activity) }
    }
}

@_cdecl("luma_canvas_close")
public func luma_canvas_close() {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { PharoCanvasHost.onClose?() }
    }
}

// MARK: Scenes the image holds by handle

@_cdecl("luma_scene_create")
public func luma_scene_create() -> Int32 {
    Int32(CanvasRegistry.shared.makeScene())
}

@_cdecl("luma_scene_destroy")
public func luma_scene_destroy(_ scene: Int32) {
    CanvasRegistry.shared.discard(Int(scene))
}

@_cdecl("luma_scene_add_drawable")
public func luma_scene_add_drawable(_ scene: Int32) -> Int32 {
    Int32(CanvasRegistry.shared.makeDrawable(in: Int(scene)))
}

@_cdecl("luma_scene_remove_drawable")
public func luma_scene_remove_drawable(_ scene: Int32, _ drawable: Int32) {
    guard let updated = CanvasRegistry.shared.remove(Int(drawable), from: Int(scene)) else { return }
    CanvasRegistry.shared.publish(Int(scene), updated)
}

@_cdecl("luma_drawable_add_attribute")
public func luma_drawable_add_attribute(
    _ scene: Int32,
    _ drawable: Int32,
    _ name: UnsafePointer<CChar>,
    _ components: Int32,
    _ isVarying: Int32
) {
    let attribute = ShaderAttribute(name: String(cString: name), components: Int(components))
    CanvasRegistry.shared.update(Int(drawable), in: Int(scene)) { subject in
        if isVarying == 1 {
            subject.geometry.varyings.append(attribute)
        } else {
            subject.geometry.attributes.append(attribute)
        }
    }
}

@_cdecl("luma_drawable_clear_layout")
public func luma_drawable_clear_layout(_ scene: Int32, _ drawable: Int32) {
    CanvasRegistry.shared.update(Int(drawable), in: Int(scene)) { subject in
        subject.geometry.attributes.removeAll()
        subject.geometry.varyings.removeAll()
    }
}

@_cdecl("luma_drawable_set_source")
public func luma_drawable_set_source(
    _ scene: Int32,
    _ drawable: Int32,
    _ vertex: UnsafePointer<CChar>,
    _ fragment: UnsafePointer<CChar>
) {
    let vertexSource = String(cString: vertex)
    let fragmentSource = String(cString: fragment)
    CanvasRegistry.shared.update(Int(drawable), in: Int(scene)) { subject in
        subject.authorVertex = vertexSource
        subject.authorFragment = fragmentSource
    }
}

@_cdecl("luma_drawable_set_vertices")
public func luma_drawable_set_vertices(
    _ scene: Int32,
    _ drawable: Int32,
    _ values: UnsafePointer<Float>,
    _ count: Int32,
    _ primitive: Int32
) {
    let vertices = Array(UnsafeBufferPointer(start: values, count: Int(max(count, 0))))
    CanvasRegistry.shared.update(Int(drawable), in: Int(scene)) { subject in
        subject.geometry.vertices = vertices
        subject.geometry.primitive = CanvasGeometry.Primitive(rawValue: primitive) ?? .triangles
        subject.primitive = subject.geometry.primitive
    }
}

@_cdecl("luma_drawable_set_transform")
public func luma_drawable_set_transform(
    _ scene: Int32,
    _ drawable: Int32,
    _ values: UnsafePointer<Float>
) {
    let transform = Array(UnsafeBufferPointer(start: values, count: 16))
    CanvasRegistry.shared.update(Int(drawable), in: Int(scene)) { $0.transform = transform }
}

@_cdecl("luma_drawable_set_visible")
public func luma_drawable_set_visible(_ scene: Int32, _ drawable: Int32, _ visible: Int32) {
    guard let updated = CanvasRegistry.shared.update(Int(drawable), in: Int(scene), {
        $0.isVisible = visible == 1
    }) else { return }
    CanvasRegistry.shared.publish(Int(scene), updated)
}

/// Wraps the author's stages in declarations matching the layout they gave,
/// and translates them for Metal. Answers 0 and keeps the compiler's
/// complaint when either will not compile.
@_cdecl("luma_drawable_commit")
public func luma_drawable_commit(_ scene: Int32, _ drawable: Int32) -> Int32 {
    guard let subject = CanvasRegistry.shared.scene(Int(scene))?.drawables[Int(drawable)] else {
        return 0
    }

    let geometry = subject.geometry
    let vertexGLSL = geometry.vertexPreamble(.openGL) + subject.authorVertex
    let fragmentGLSL = geometry.fragmentPreamble(.openGL) + subject.authorFragment
    let vertexMetal: String
    let fragmentMetal: String
    do {
        vertexMetal = try ShaderTranslator.metalSource(
            forComplete: geometry.vertexPreamble(.metal) + subject.authorVertex,
            stage: .vertex, entryPoint: "canvasVertex")
        fragmentMetal = try ShaderTranslator.metalSource(
            forComplete: geometry.fragmentPreamble(.metal) + subject.authorFragment,
            stage: .fragment, entryPoint: "canvasFragment")
    } catch {
        canvasError.withLock { $0 = "\(error)" }
        return 0
    }
    canvasError.withLock { $0 = "" }

    guard let updated = CanvasRegistry.shared.update(Int(drawable), in: Int(scene), { subject in
        subject.vertexGLSL = vertexGLSL
        subject.fragmentGLSL = fragmentGLSL
        subject.vertexMetal = vertexMetal
        subject.fragmentMetal = fragmentMetal
    }) else { return 0 }

    CanvasRegistry.shared.publish(Int(scene), updated)
    return 1
}

@_cdecl("luma_scene_show")
public func luma_scene_show(_ scene: Int32) -> Int32 {
    guard let subject = CanvasRegistry.shared.scene(Int(scene)) else { return 0 }
    CanvasRegistry.shared.publish(Int(scene), subject)
    return 1
}
