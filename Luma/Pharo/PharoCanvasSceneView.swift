import AppKit
import LumaCore
import Metal
import MetalKit
import SwiftUI

/// A scene drawn inside an object's views. The image holds the scene and
/// changes it; this follows, rebuilding only what differs so moving a
/// drawable does not recompile its shaders.
struct PharoCanvasSceneView: NSViewRepresentable {
    let scene: Int

    func makeCoordinator() -> CanvasSceneRenderer {
        CanvasSceneRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = CanvasSceneInputView(scene: scene)
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.994, green: 0.991, blue: 0.986, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.attach(to: view, scene: scene)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

/// Reports what the pointer and keyboard are doing, for whoever drives the
/// scene to read. Nothing is delivered into the image: a snippet asks.
final class CanvasSceneInputView: MTKView {
    private let scene: Int
    private var tracking: NSTrackingArea?

    init(scene: Int) {
        self.scene = scene
        super.init(frame: .zero, device: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    /// Closing the pane a scene is drawn in says what Escape says, and whoever
    /// drives the scene is already watching for that.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        report { $0.keysDown.insert(CanvasKey.escape.rawValue) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        reportPointer(event)
    }

    override func mouseDragged(with event: NSEvent) {
        reportPointer(event)
    }

    override func mouseExited(with event: NSEvent) {
        report { $0.isPointerInside = false }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        reportPointer(event)
        report { $0.buttons |= 1 << 0 }
    }

    override func mouseUp(with event: NSEvent) {
        report { $0.buttons &= ~(1 << 0) }
    }

    override func rightMouseDown(with event: NSEvent) {
        report { $0.buttons |= 1 << 1 }
    }

    override func rightMouseUp(with event: NSEvent) {
        report { $0.buttons &= ~(1 << 1) }
    }

    override func keyDown(with event: NSEvent) {
        report { $0.keysDown.insert(Self.code(for: event)) }
    }

    override func keyUp(with event: NSEvent) {
        report { $0.keysDown.remove(Self.code(for: event)) }
    }

    /// Clip space, so what a snippet reads is in the coordinates it gave its
    /// vertices in.
    private func reportPointer(_ event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }

        report {
            $0.pointerX = Float(at.x / bounds.width * 2 - 1)
            $0.pointerY = Float(at.y / bounds.height * 2 - 1)
            $0.isPointerInside = true
        }
    }

    private func report(_ change: (inout CanvasInput) -> Void) {
        CanvasRegistry.shared.reportInput(scene, change)
    }

    /// AppKit's own codes, mapped onto what a scene is asked about: the named
    /// keys, and otherwise whatever character was typed.
    private static func code(for event: NSEvent) -> Int32 {
        switch Int(event.keyCode) {
        case 123: return CanvasKey.left.rawValue
        case 124: return CanvasKey.right.rawValue
        case 125: return CanvasKey.down.rawValue
        case 126: return CanvasKey.up.rawValue
        case 36, 76: return CanvasKey.enter.rawValue
        case 53: return CanvasKey.escape.rawValue
        default:
            guard let character = event.charactersIgnoringModifiers?.first else { return 0 }
            return CanvasKey.code(for: character)
        }
    }
}

/// Which renderers are showing which scene, so a change reaches whichever
/// view happens to be drawing it.
@MainActor
enum PharoCanvasScenes {
    private static var renderers: [Int: [WeakRenderer]] = [:]
    private static var listening = false

    private struct WeakRenderer {
        weak var renderer: CanvasSceneRenderer?
    }

    static func register(_ renderer: CanvasSceneRenderer, for scene: Int) {
        listenOnce()
        renderers[scene, default: []].append(WeakRenderer(renderer: renderer))
    }

    private static func listenOnce() {
        guard !listening else { return }
        listening = true
        CanvasRegistry.onChange = { handle, scene in
            renderers[handle] = renderers[handle]?.filter { $0.renderer != nil }
            for entry in renderers[handle] ?? [] {
                entry.renderer?.scene = scene
            }
        }
    }
}

@MainActor
final class CanvasSceneRenderer: NSObject, MTKViewDelegate {
    var scene = CanvasScene()

    private var sceneHandle = 0
    private weak var view: MTKView?
    private var commandQueue: MTLCommandQueue?
    private var depthState: MTLDepthStencilState?
    private var byIndex: MTLSamplerState?
    private var acrossPicture: MTLSamplerState?
    private var built: [Int: Built] = [:]
    private let startTime = CACurrentMediaTime()
    private var tracedAt: CFTimeInterval = 0

    private struct Built {
        var pipeline: MTLRenderPipelineState
        var vertexBuffer: MTLBuffer?
        var vertexMetal: String
        var fragmentMetal: String
        var vertices: [Float]
        var drivers: [CanvasDriver] = []
        /// What the runs of values and pictures were stamped when their
        /// textures were made, so a frame tells them apart by the stamp
        /// rather than by reading every pixel back.
        var stamps: [UInt64] = []
        var textures: [MTLTexture] = []
        /// Stamped here rather than carried from the image, so a value moves
        /// on the clock that draws it.
        var driversStartedAt = CACurrentMediaTime()
    }

    func attach(to view: MTKView, scene handle: Int) {
        self.view = view
        sceneHandle = handle
        commandQueue = view.device?.makeCommandQueue()

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = view.device?.makeDepthStencilState(descriptor: depth)

        // Nearest, clamped: a value is read at its own index, never blended
        // with a neighbour's.
        let exact = MTLSamplerDescriptor()
        exact.minFilter = .nearest
        exact.magFilter = .nearest
        exact.sAddressMode = .clampToEdge
        exact.tAddressMode = .clampToEdge
        byIndex = view.device?.makeSamplerState(descriptor: exact)

        let smooth = MTLSamplerDescriptor()
        smooth.minFilter = .linear
        smooth.magFilter = .linear
        smooth.sAddressMode = .clampToEdge
        smooth.tAddressMode = .clampToEdge
        acrossPicture = view.device?.makeSamplerState(descriptor: smooth)

        PharoCanvasScenes.register(self, for: handle)
        if let current = CanvasRegistry.shared.scene(handle) {
            scene = current
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let device = view.device,
              let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        if let depthState {
            encoder.setDepthStencilState(depthState)
        }

        var uniforms = [Float](repeating: 0, count: ShaderEffectRenderer.uniformWordCount)
        uniforms[0] = Float(view.drawableSize.width)
        uniforms[1] = Float(view.drawableSize.height)
        uniforms[2] = Float(CACurrentMediaTime() - startTime)
        uniforms[3] = 1
        // What the view is actually drawing into against what it covers:
        // the window is not always there to be asked, and this is the ratio
        // that matters either way.
        let scale = view.bounds.width > 0
            ? Float(view.drawableSize.width / view.bounds.width)
            : Float(view.window?.backingScaleFactor ?? 1)
        uniforms[7] = scale
        CanvasRegistry.shared.reportScale(sceneHandle, scale)
        trace(view, scale: scale, uniformWidth: uniforms[0], uniformHeight: uniforms[1])

        for handle in scene.order {
            guard let subject = scene.drawables[handle], subject.isVisible,
                  let record = record(for: handle, subject, device: device),
                  let vertexBuffer = record.vertexBuffer
            else { continue }

            for (offset, value) in subject.transform.prefix(16).enumerated() {
                uniforms[ShaderEffectRenderer.transformWordOffset + offset] = value
            }

            encoder.setRenderPipelineState(record.pipeline)
            let length = uniforms.count * MemoryLayout<Float>.stride
            encoder.setVertexBytes(&uniforms, length: length, index: 0)
            encoder.setFragmentBytes(&uniforms, length: length, index: 0)
            var params = subject.packedParams(after: Float(CACurrentMediaTime() - record.driversStartedAt))
            if !params.isEmpty {
                let paramsLength = params.count * MemoryLayout<Float>.stride
                encoder.setVertexBytes(&params, length: paramsLength,
                                       index: ShaderEffectRenderer.paramsBufferIndex)
                encoder.setFragmentBytes(&params, length: paramsLength,
                                         index: ShaderEffectRenderer.paramsBufferIndex)
            }
            for (index, texture) in record.textures.enumerated() {
                encoder.setFragmentTexture(texture, index: index)
                encoder.setVertexTexture(texture, index: index)
                let sampler = index < subject.buffers.count ? byIndex : acrossPicture
                encoder.setFragmentSamplerState(sampler, index: index)
                encoder.setVertexSamplerState(sampler, index: index)
            }
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: ShaderEffectRenderer.vertexBufferIndex)
            encoder.drawPrimitives(
                type: Self.primitive(subject.geometry.primitive),
                vertexStart: 0,
                vertexCount: subject.geometry.vertexCount)
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// What a scene is actually being drawn with, for when what it looks like
    /// and what it was asked for disagree. Set LUMA_CANVAS_TRACE to see it.
    private func trace(_ view: MTKView, scale: Float, uniformWidth: Float, uniformHeight: Float) {
        guard ProcessInfo.processInfo.environment["LUMA_CANVAS_TRACE"] != nil else { return }
        let now = CACurrentMediaTime()
        guard now - tracedAt > 1 else { return }
        tracedAt = now

        let sizes = scene.order.compactMap { scene.drawables[$0] }.map { subject in
            subject.uniforms.map { "\($0.name)=\($0.values)" }.joined(separator: " ")
        }
        let uniformResolution = "\(uniformWidth) x \(uniformHeight)"
        FileHandle.standardError.write(Data("""
            canvas: drawable \(view.drawableSize) bounds \(view.bounds.size) \
            scale \(scale) u_resolution \(uniformResolution)
            canvas: \(sizes.joined(separator: " | "))

            """.utf8))
    }

    /// Compiles a drawable's stages only when they actually differ, and
    /// re-uploads its vertices only when those do.
    private func record(for handle: Int, _ subject: CanvasDrawable, device: MTLDevice) -> Built? {
        if var existing = built[handle],
           existing.vertexMetal == subject.vertexMetal,
           existing.fragmentMetal == subject.fragmentMetal {
            if existing.drivers != subject.drivers {
                existing.drivers = subject.drivers
                existing.driversStartedAt = CACurrentMediaTime()
                built[handle] = existing
            }
            if existing.vertices != subject.geometry.vertices {
                existing.vertexBuffer = Self.buffer(for: subject, device: device)
                existing.vertices = subject.geometry.vertices
                built[handle] = existing
            }
            if existing.stamps != Self.stamps(of: subject) {
                existing.stamps = Self.stamps(of: subject)
                existing.textures = Self.textures(for: subject, device: device)
                built[handle] = existing
            }
            return existing
        }

        guard !subject.vertexMetal.isEmpty,
              let vertexLibrary = try? device.makeLibrary(source: subject.vertexMetal, options: nil),
              let fragmentLibrary = try? device.makeLibrary(source: subject.fragmentMetal, options: nil),
              let vertexFunction = vertexLibrary.makeFunction(name: "canvasVertex"),
              let fragmentFunction = fragmentLibrary.makeFunction(name: "canvasFragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = Self.vertexDescriptor(for: subject.geometry)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Premultiplied: what a drawable leaves transparent shows what it was
        // drawn over, rather than coming out black.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = .depth32Float

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        let record = Built(
            pipeline: pipeline,
            vertexBuffer: Self.buffer(for: subject, device: device),
            vertexMetal: subject.vertexMetal,
            fragmentMetal: subject.fragmentMetal,
            vertices: subject.geometry.vertices,
            drivers: subject.drivers,
            stamps: Self.stamps(of: subject),
            textures: Self.textures(for: subject, device: device))
        built[handle] = record
        return record
    }

    private static func stamps(of subject: CanvasDrawable) -> [UInt64] {
        subject.buffers.map(\.stamp) + subject.images.map(\.stamp)
    }

    /// The drawable's samplers in the order the preamble declares them: its
    /// runs of values first, then its pictures.
    private static func textures(for subject: CanvasDrawable, device: MTLDevice) -> [MTLTexture] {
        subject.buffers.compactMap { sheet(for: $0, device: device) }
            + subject.images.compactMap { picture(for: $0, device: device) }
    }

    /// A run of values, read by index rather than sampled across.
    private static func sheet(for buffer: CanvasBuffer, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: buffer.width, height: buffer.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        buffer.padded().withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, buffer.width, buffer.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: buffer.width * MemoryLayout<Float>.stride)
        }
        return texture
    }

    private static func picture(for image: CanvasImage, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        image.pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: image.width * MemoryLayout<UInt32>.stride)
        }
        return texture
    }

    private static func buffer(for subject: CanvasDrawable, device: MTLDevice) -> MTLBuffer? {
        device.makeBuffer(
            bytes: subject.geometry.vertices,
            length: max(subject.geometry.vertices.count, 1) * MemoryLayout<Float>.stride,
            options: [])
    }

    private static func vertexDescriptor(for geometry: CanvasGeometry) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        var offset = 0
        for (index, attribute) in geometry.attributes.enumerated() {
            descriptor.attributes[index].format = format(components: attribute.components)
            descriptor.attributes[index].offset = offset
            descriptor.attributes[index].bufferIndex = ShaderEffectRenderer.vertexBufferIndex
            offset += attribute.components * MemoryLayout<Float>.stride
        }
        descriptor.layouts[ShaderEffectRenderer.vertexBufferIndex].stride = offset
        return descriptor
    }

    private static func format(components: Int) -> MTLVertexFormat {
        switch components {
        case 1: return .float
        case 2: return .float2
        case 3: return .float3
        default: return .float4
        }
    }

    private static func primitive(_ primitive: CanvasGeometry.Primitive) -> MTLPrimitiveType {
        switch primitive {
        case .points: return .point
        case .lines: return .line
        case .lineStrip: return .lineStrip
        case .triangles: return .triangle
        case .triangleStrip: return .triangleStrip
        }
    }
}
