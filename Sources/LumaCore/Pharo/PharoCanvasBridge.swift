import Foundation
import Synchronization

/// What the image may do to a canvas. A scene is held by handle and changed;
/// whatever view is drawing it follows.
public enum PharoCanvasBridge {
    /// No Swift caller reaches the exports below, and a static archive only
    /// yields the object files something references -- so without this touch
    /// the linker drops them and the image's dlsym comes up empty.
    public static func ensureExported() {}
}

private let canvasError = Mutex("")
private nonisolated(unsafe) var canvasErrorBuffer: UnsafeMutablePointer<CChar>?

/// What the shader compiler said about the last stages that would not build.
@_cdecl("luma_canvas_last_error")
public func luma_canvas_last_error() -> UnsafeMutablePointer<CChar>? {
    canvasErrorBuffer.map { free($0) }
    canvasErrorBuffer = strdup(canvasError.withLock { $0 })
    return canvasErrorBuffer
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
    CanvasRegistry.shared.publish(Int(scene))
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
    guard CanvasRegistry.shared.update(Int(drawable), in: Int(scene), { subject in
        subject.geometry.vertices = vertices
        subject.geometry.primitive = CanvasGeometry.Primitive(rawValue: primitive) ?? .triangles
        subject.primitive = subject.geometry.primitive
    }) != nil else { return }

    // Fresh vertices for stages that are already built need no commit, so
    // this is what carries them to whoever is drawing.
    CanvasRegistry.shared.publish(Int(scene))
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
    guard CanvasRegistry.shared.update(Int(drawable), in: Int(scene), {
        $0.isVisible = visible == 1
    }) != nil else { return }
    CanvasRegistry.shared.publish(Int(scene))
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
    let declared = subject.uniforms
    let sheets = subject.buffers
    let pictures = subject.images
    let vertexGLSL = geometry.vertexPreamble(
        .openGL, uniforms: declared, buffers: sheets, images: pictures) + subject.authorVertex
    let fragmentGLSL = geometry.fragmentPreamble(
        .openGL, uniforms: declared, buffers: sheets, images: pictures) + subject.authorFragment
    var vertexMetal = ""
    var fragmentMetal = ""
    #if canImport(Metal)
    // Only a Metal host reads these, and only there is there a toolchain to
    // write them with. OpenGL takes the GLSL as it stands.
    do {
        vertexMetal = try ShaderTranslator.metalSource(
            forComplete: geometry.vertexPreamble(
                .metal, uniforms: declared, buffers: sheets, images: pictures)
                + subject.authorVertex,
            stage: .vertex, entryPoint: "canvasVertex")
        fragmentMetal = try ShaderTranslator.metalSource(
            forComplete: geometry.fragmentPreamble(
                .metal, uniforms: declared, buffers: sheets, images: pictures)
                + subject.authorFragment,
            stage: .fragment, entryPoint: "canvasFragment")
    } catch {
        canvasError.withLock { $0 = "\(error)" }
        return 0
    }
    #endif
    canvasError.withLock { $0 = "" }

    guard CanvasRegistry.shared.update(Int(drawable), in: Int(scene), { subject in
        subject.vertexGLSL = vertexGLSL
        subject.fragmentGLSL = fragmentGLSL
        subject.vertexMetal = vertexMetal
        subject.fragmentMetal = fragmentMetal
    }) != nil else { return 0 }

    CanvasRegistry.shared.publish(Int(scene))
    return 1
}

/// A uniform the author named, of whatever width they gave it. Declaring it
/// is what lets the host write the declaration and pack the buffer to match.
@_cdecl("luma_drawable_set_uniform")
public func luma_drawable_set_uniform(
    _ scene: Int32,
    _ drawable: Int32,
    _ name: UnsafePointer<CChar>,
    _ values: UnsafePointer<Float>,
    _ count: Int32
) {
    let uniform = CanvasUniform(
        name: String(cString: name),
        values: Array(UnsafeBufferPointer(start: values, count: Int(max(count, 0)))))

    guard CanvasRegistry.shared.update(Int(drawable), in: Int(scene), { subject in
        if let existing = subject.uniforms.firstIndex(where: { $0.name == uniform.name }) {
            subject.uniforms[existing] = uniform
        } else {
            subject.uniforms.append(uniform)
        }
    }) != nil else { return }

    CanvasRegistry.shared.publish(Int(scene))
}

/// What a named value should do over time. Said once: the renderers work it
/// out on their own clock, so the image never drives a frame.
@_cdecl("luma_drawable_drive_uniform")
public func luma_drawable_drive_uniform(
    _ scene: Int32,
    _ drawable: Int32,
    _ name: UnsafePointer<CChar>,
    _ kind: Int32,
    _ from: UnsafePointer<Float>,
    _ to: UnsafePointer<Float>,
    _ count: Int32,
    _ seconds: Float
) {
    let width = Int(max(count, 0))
    let driver = CanvasDriver(
        name: String(cString: name),
        kind: CanvasDriver.Kind(rawValue: kind) ?? .ramp,
        from: Array(UnsafeBufferPointer(start: from, count: width)),
        to: Array(UnsafeBufferPointer(start: to, count: width)),
        seconds: seconds)

    guard CanvasRegistry.shared.update(Int(drawable), in: Int(scene), { subject in
        subject.drivers.removeAll { $0.name == driver.name }
        subject.drivers.append(driver)
        // A driven value still needs declaring, so the shader has it.
        if !subject.uniforms.contains(where: { $0.name == driver.name }) {
            subject.uniforms.append(CanvasUniform(name: driver.name, values: driver.from))
        }
    }) != nil else { return }

    CanvasRegistry.shared.publish(Int(scene))
}

/// A run of values the shader reads by index. Handing over a fresh window is
/// what scrubbing costs: the scene itself is untouched.
@_cdecl("luma_drawable_set_buffer")
public func luma_drawable_set_buffer(
    _ scene: Int32,
    _ drawable: Int32,
    _ name: UnsafePointer<CChar>,
    _ values: UnsafePointer<Float>,
    _ count: Int32
) {
    let buffer = CanvasBuffer(
        name: String(cString: name),
        values: Array(UnsafeBufferPointer(start: values, count: Int(max(count, 0)))),
        stamp: CanvasRegistry.shared.nextStamp())

    guard CanvasRegistry.shared.update(Int(drawable), in: Int(scene), { subject in
        if let existing = subject.buffers.firstIndex(where: { $0.name == buffer.name }) {
            subject.buffers[existing] = buffer
        } else {
            subject.buffers.append(buffer)
        }
        // The reader needs to know the row length to divide an index by.
        let size = CanvasUniform(
            name: buffer.name + "_size",
            values: [Float(buffer.width), Float(buffer.height)])
        if let existing = subject.uniforms.firstIndex(where: { $0.name == size.name }) {
            subject.uniforms[existing] = size
        } else {
            subject.uniforms.append(size)
        }
    }) != nil else { return }

    CanvasRegistry.shared.publish(Int(scene))
}

/// A picture the shader samples. Pixels come as the image holds them, one
/// word per pixel, which is what both renderers upload.
@_cdecl("luma_drawable_set_image")
public func luma_drawable_set_image(
    _ scene: Int32,
    _ drawable: Int32,
    _ name: UnsafePointer<CChar>,
    _ pixels: UnsafePointer<UInt32>,
    _ width: Int32,
    _ height: Int32
) {
    let image = CanvasImage(
        name: String(cString: name),
        pixels: Array(UnsafeBufferPointer(start: pixels, count: Int(width) * Int(height))),
        width: Int(width),
        height: Int(height),
        stamp: CanvasRegistry.shared.nextStamp())

    guard CanvasRegistry.shared.update(Int(drawable), in: Int(scene), { subject in
        if let existing = subject.images.firstIndex(where: { $0.name == image.name }) {
            subject.images[existing] = image
        } else {
            subject.images.append(image)
        }
    }) != nil else { return }

    CanvasRegistry.shared.publish(Int(scene))
}

/// Where the pointer sits over the scene, in the clip space the vertices were
/// given in. Asked for rather than delivered, so a snippet reads it when it
/// suits: the image is never called from a frame.
@_cdecl("luma_scene_pointer_x")
public func luma_scene_pointer_x(_ scene: Int32) -> Float {
    CanvasRegistry.shared.input(Int(scene)).pointerX
}

@_cdecl("luma_scene_pointer_y")
public func luma_scene_pointer_y(_ scene: Int32) -> Float {
    CanvasRegistry.shared.input(Int(scene)).pointerY
}

/// Bit 0 primary, bit 1 secondary, bit 2 middle.
@_cdecl("luma_scene_buttons")
public func luma_scene_buttons(_ scene: Int32) -> Int32 {
    CanvasRegistry.shared.input(Int(scene)).buttons
}

/// A printable key answers to its own lowercase character; the rest are named
/// by `CanvasKey`.
@_cdecl("luma_scene_key_down")
public func luma_scene_key_down(_ scene: Int32, _ key: Int32) -> Int32 {
    CanvasRegistry.shared.input(Int(scene)).keysDown.contains(key) ? 1 : 0
}

/// Physical pixels to a logical one, for whoever is rasterising something the
/// scene will draw. Zero until a view has drawn it.
@_cdecl("luma_scene_scale")
public func luma_scene_scale(_ scene: Int32) -> Float {
    CanvasRegistry.shared.scale(Int(scene))
}

// MARK: Lettering the host rasterises

/// Draws the printable range at the given pixel size and keeps it. Answers 0
/// where the host has nothing to draw with.
@_cdecl("luma_glyphs_make")
public func luma_glyphs_make(_ pixelSize: Int32) -> Int32 {
    Int32(GlyphAtlasRasteriser.make(pixelSize: Int(pixelSize)))
}

@_cdecl("luma_glyphs_discard")
public func luma_glyphs_discard(_ atlas: Int32) {
    GlyphAtlasRasteriser.discard(Int(atlas))
}

/// What a caller needs to lay a string out: the cell it is drawn on, the grid
/// it sits in, and the rows the ink touches.
@_cdecl("luma_glyphs_metric")
public func luma_glyphs_metric(_ atlas: Int32, _ which: Int32) -> Float {
    guard let atlas = GlyphAtlasRasteriser.atlas(Int(atlas)) else { return 0 }

    switch which {
    case 0: return Float(atlas.width)
    case 1: return Float(atlas.height)
    case 2: return Float(atlas.cellWidth)
    case 3: return Float(atlas.cellHeight)
    case 4: return Float(atlas.columns)
    case 5: return Float(atlas.inkTop)
    case 6: return Float(atlas.inkBottom)
    default: return 0
    }
}

@_cdecl("luma_glyphs_advance")
public func luma_glyphs_advance(_ atlas: Int32, _ code: Int32) -> Float {
    GlyphAtlasRasteriser.atlas(Int(atlas))?.advance(for: Int(code)) ?? 0
}

/// Hands the picture to a drawable, so the image never carries the pixels.
@_cdecl("luma_glyphs_apply")
public func luma_glyphs_apply(
    _ atlas: Int32,
    _ scene: Int32,
    _ drawable: Int32,
    _ name: UnsafePointer<CChar>
) {
    guard let held = GlyphAtlasRasteriser.atlas(Int(atlas)) else { return }

    let image = CanvasImage(
        name: String(cString: name),
        pixels: held.pixels,
        width: held.width,
        height: held.height,
        stamp: CanvasRegistry.shared.nextStamp())

    guard CanvasRegistry.shared.update(Int(drawable), in: Int(scene), { subject in
        if let existing = subject.images.firstIndex(where: { $0.name == image.name }) {
            subject.images[existing] = image
        } else {
            subject.images.append(image)
        }
    }) != nil else { return }

    CanvasRegistry.shared.publish(Int(scene))
}
