import LumaCore
import Metal
import MetalKit
import QuartzCore
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A fullscreen fragment effect from the default Metal library, fed the same
/// resolution/time/scheme/activity/pulse uniforms the GTK frontend's widget
/// feeds its GLSL. Both sides are generated from one authored effect
/// in `Shaders/` by `LumaShaderCompiler`.
/// Either a function the build already carries, or Metal source translated
/// from GLSL on the spot, for an effect written in a snippet.
enum ShaderEffectProgram: Equatable {
    case builtIn(function: String)
    case translated(metal: String, function: String)
    /// The author's own stages, drawing their own vertices.
    case geometry(
        vertexMetal: String,
        vertexFunction: String,
        fragmentMetal: String,
        fragmentFunction: String,
        geometry: CanvasGeometry
    )
}

struct ShaderEffectView {
    let program: ShaderEffectProgram
    let scheme: Float

    /// Bumped by the caller whenever events arrive; the renderer decays what it
    /// was last handed, so a caller only sets this when there is news.
    var activity: Float = 0

    /// Values the effect reads through `dataAt()`, up to 64.
    var data: [Float] = []

    /// Where vertices land. Identity draws them in clip space as they stand.
    var transform: [Float] = ShaderEffectRenderer.identity

    func makeCoordinator() -> ShaderEffectRenderer {
        ShaderEffectRenderer(program: program)
    }

    fileprivate func install(into view: MTKView, coordinator: ShaderEffectRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        // Geometry with any depth to it needs this, and a screen-filling
        // effect is no worse off for having it.
        view.depthStencilPixelFormat = .depth32Float
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = coordinator
        coordinator.attach(to: view)
        coordinator.scheme = scheme
    }

    fileprivate func refresh(_ coordinator: ShaderEffectRenderer) {
        coordinator.scheme = scheme
        coordinator.data = data
        coordinator.transform = transform
        coordinator.reportActivity(activity)
    }
}

#if os(macOS)
extension ShaderEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.layer?.isOpaque = true
        install(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        refresh(context.coordinator)
    }
}
#else
extension ShaderEffectView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.isOpaque = true
        install(into: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        refresh(context.coordinator)
    }
}
#endif

final class ShaderEffectRenderer: NSObject, MTKViewDelegate {
    var scheme: Float = 1.0
    var data: [Float] = []
    var transform: [Float] = ShaderEffectRenderer.identity
    private let program: ShaderEffectProgram
    private weak var view: MTKView?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var depthState: MTLDepthStencilState?
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private let proxy = DisplayLinkProxy()
    private let startTime = CACurrentMediaTime()

    private var activity: Float = 0
    private var pulsedAt: TimeInterval?
    private var renderedAt: TimeInterval

    /// Seconds for a reported arrival to fall to 1/e.
    private let pulseHalfLife: Float = 0.4
    private let activityHalfLife: Float = 1.2

    init(program: ShaderEffectProgram) {
        self.program = program
        renderedAt = CACurrentMediaTime()
    }

    func reportActivity(_ reported: Float) {
        guard reported > 0 else { return }
        activity = reported
        pulsedAt = CACurrentMediaTime()
    }

    func attach(to view: MTKView) {
        self.view = view
        guard buildPipeline(for: view) else { return }
        startDisplayLink()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor
        else { return }

        guard let commandQueue,
              let pipeline,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let now = CACurrentMediaTime()
        activity *= exp(-Float(now - renderedAt) / activityHalfLife)
        renderedAt = now

        var uniforms = [Float](repeating: 0, count: Self.uniformWordCount)
        uniforms[0] = Float(view.drawableSize.width)
        uniforms[1] = Float(view.drawableSize.height)
        uniforms[2] = Float(now - startTime)
        uniforms[3] = scheme
        uniforms[4] = activity
        uniforms[5] = pulsedAt.map { exp(-Float(now - $0) / pulseHalfLife) } ?? 0
        uniforms[6] = Float(min(data.count, Self.dataCapacity))
        uniforms[7] = Float(view.window?.backingScaleFactor ?? 1)
        for (offset, value) in data.prefix(Self.dataCapacity).enumerated() {
            uniforms[Self.dataWordOffset + offset] = value
        }
        for (offset, value) in transform.prefix(16).enumerated() {
            uniforms[Self.transformWordOffset + offset] = value
        }

        encoder.setRenderPipelineState(pipeline)
        let uniformLength = uniforms.count * MemoryLayout<Float>.stride
        encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
        encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)

        if case let .geometry(_, _, _, _, geometry) = program, let vertexBuffer {
            if let depthState {
                encoder.setDepthStencilState(depthState)
            }
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Self.vertexBufferIndex)
            encoder.drawPrimitives(
                type: Self.metalPrimitive(geometry.primitive),
                vertexStart: 0,
                vertexCount: geometry.vertexCount)
        } else {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    fileprivate func tick() {
        view?.draw()
    }

    private func buildPipeline(for view: MTKView) -> Bool {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return false }

        let desc = MTLRenderPipelineDescriptor()
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        if case let .geometry(vertexMetal, vertexName, fragmentMetal, fragmentName, geometry) = program {
            guard let vertexLibrary = try? device.makeLibrary(source: vertexMetal, options: nil),
                  let fragmentLibrary = try? device.makeLibrary(source: fragmentMetal, options: nil),
                  let vertex = vertexLibrary.makeFunction(name: vertexName),
                  let fragment = fragmentLibrary.makeFunction(name: fragmentName)
            else { return false }

            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
            desc.vertexDescriptor = Self.vertexDescriptor(for: geometry)
            vertexBuffer = device.makeBuffer(
                bytes: geometry.vertices,
                length: max(geometry.vertices.count, 1) * MemoryLayout<Float>.stride,
                options: [])

            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .less
            depth.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: depth)
        } else {
            guard let bundled = try? device.makeDefaultLibrary(bundle: Bundle.main),
                  let vertex = bundled.makeFunction(name: "shaderEffectVertex"),
                  let fragment = fragmentFunction(from: device, bundled: bundled)
            else { return false }
            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
        }

        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return false }

        commandQueue = queue
        pipeline = state
        return true
    }

    /// Buffers 0 and 1 go to the two uniform blocks, as spirv-cross assigns
    /// them by binding, so the vertices sit clear at the top of the range.
    static let vertexBufferIndex = 30
    static let paramsBufferIndex = 1

    private static func vertexDescriptor(for geometry: CanvasGeometry) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        var offset = 0
        for (index, attribute) in geometry.attributes.enumerated() {
            descriptor.attributes[index].format = format(components: attribute.components)
            descriptor.attributes[index].offset = offset
            descriptor.attributes[index].bufferIndex = vertexBufferIndex
            offset += attribute.components * MemoryLayout<Float>.stride
        }
        descriptor.layouts[vertexBufferIndex].stride = offset
        return descriptor
    }

    static let identity: [Float] = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1]

    private static func format(components: Int) -> MTLVertexFormat {
        switch components {
        case 1: return .float
        case 2: return .float2
        case 3: return .float3
        default: return .float4
        }
    }

    private static func metalPrimitive(_ primitive: CanvasGeometry.Primitive) -> MTLPrimitiveType {
        switch primitive {
        case .points: return .point
        case .lines: return .line
        case .lineStrip: return .lineStrip
        case .triangles: return .triangle
        case .triangleStrip: return .triangleStrip
        }
    }

    /// A built-in effect is already in the default library; a translated one
    /// is compiled here, which is what lets a snippet author its own.
    private func fragmentFunction(from device: MTLDevice, bundled: MTLLibrary) -> MTLFunction? {
        switch program {
        case let .builtIn(function):
            return bundled.makeFunction(name: function)
        case let .translated(metal, function):
            guard let library = try? device.makeLibrary(source: metal, options: nil) else { return nil }
            return library.makeFunction(name: function)
        case .geometry:
            // Built alongside its own vertex stage, in buildPipeline.
            return nil
        }
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        proxy.renderer = self
        guard let link = makeScreenDisplayLink() else { return }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func makeScreenDisplayLink() -> CADisplayLink? {
        let selector = #selector(DisplayLinkProxy.fire(_:))
        #if os(macOS)
        return (view?.window?.screen ?? NSScreen.main)?.displayLink(target: proxy, selector: selector)
        #else
        return CADisplayLink(target: proxy, selector: selector)
        #endif
    }

    deinit {
        displayLink?.invalidate()
    }

    /// The block std140 lays out: resolution, time, scheme, activity, pulse,
    /// the value count and the scale fill the first eight words, which is
    /// what the vec4 array's sixteen-byte alignment leaves, and the values
    /// follow.
    public static let dataCapacity = 64
    static let dataWordOffset = 8
    /// A mat4 aligns to sixteen bytes, so it follows the value array.
    static let transformWordOffset = dataWordOffset + dataCapacity
    static let uniformWordCount = transformWordOffset + 16
}

private final class DisplayLinkProxy: NSObject {
    weak var renderer: ShaderEffectRenderer?

    @objc func fire(_ link: CADisplayLink) {
        renderer?.tick()
    }
}
