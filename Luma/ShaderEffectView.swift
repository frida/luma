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

    fileprivate func install(into view: OnScreenMTKView, coordinator: ShaderEffectRenderer) {
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
    func makeNSView(context: Context) -> OnScreenMTKView {
        let view = OnScreenMTKView()
        view.layer?.isOpaque = true
        install(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: OnScreenMTKView, context: Context) {
        refresh(context.coordinator)
    }
}
#else
extension ShaderEffectView: UIViewRepresentable {
    func makeUIView(context: Context) -> OnScreenMTKView {
        let view = OnScreenMTKView()
        view.isOpaque = true
        install(into: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: OnScreenMTKView, context: Context) {
        refresh(context.coordinator)
    }
}
#endif

final class ShaderEffectRenderer: NSObject, MTKViewDelegate {
    var scheme: Float = 1.0 {
        didSet { painter?.change { $0.scheme = scheme } }
    }
    var data: [Float] = [] {
        didSet { painter?.change { $0.data = data } }
    }
    var transform: [Float] = ShaderEffectRenderer.identity {
        didSet { painter?.change { $0.transform = transform } }
    }
    private let program: ShaderEffectProgram
    private var painter: ShaderEffectPainter?
    private nonisolated(unsafe) var linkThread: DisplayLinkThread?

    private static let framesPerSecond = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    init(program: ShaderEffectProgram) {
        self.program = program
    }

    deinit {
        linkThread?.stop()
    }

    func attach(to view: OnScreenMTKView) {
        guard let painter = ShaderEffectPainter(program: program, view: view) else { return }
        painter.change { [scheme, data, transform] inputs in
            inputs.scheme = scheme
            inputs.data = data
            inputs.transform = transform
            inputs.pointsWide = view.bounds.width
        }
        self.painter = painter
        startDisplayLink(drivenBy: view, painting: painter)
    }

    private func startDisplayLink(drivenBy view: OnScreenMTKView, painting painter: ShaderEffectPainter) {
        let proxy = DisplayLinkProxy(painter: painter)
        let link = makeDisplayLink(for: view, proxy: proxy)
        link.preferredFrameRateRange = Self.framesPerSecond
        let thread = DisplayLinkThread(link: link, name: "luma.shader-effect")
        thread.setPaused(view.visibility == .offScreen)
        linkThread = thread
        view.visibilityChanged = { [weak thread] visibility in
            thread?.setPaused(visibility == .offScreen)
        }
    }

    private func makeDisplayLink(for view: OnScreenMTKView, proxy: DisplayLinkProxy) -> CADisplayLink {
        let selector = #selector(DisplayLinkProxy.fire(_:))
        #if os(macOS)
        return view.displayLink(target: proxy, selector: selector)
        #else
        return CADisplayLink(target: proxy, selector: selector)
        #endif
    }

    func reportActivity(_ reported: Float) {
        guard reported > 0 else { return }
        let now = CACurrentMediaTime()
        painter?.change { inputs in
            inputs.activity = reported
            inputs.pulsedAt = now
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        painter?.change { $0.pointsWide = view.bounds.width }
    }

    func draw(in view: MTKView) {}

    /// Buffers 0 and 1 go to the two uniform blocks, as spirv-cross assigns
    /// them by binding, so the vertices sit clear at the top of the range.
    nonisolated static let vertexBufferIndex = 30
    nonisolated static let paramsBufferIndex = 1

    nonisolated static let identity: [Float] = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1]

    /// The block std140 lays out: resolution, time, scheme, activity, pulse,
    /// the value count and the scale fill the first eight words, which is
    /// what the vec4 array's sixteen-byte alignment leaves, and the values
    /// follow.
    nonisolated public static let dataCapacity = 64
    nonisolated static let dataWordOffset = 8
    /// A mat4 aligns to sixteen bytes, so it follows the value array.
    nonisolated static let transformWordOffset = dataWordOffset + dataCapacity
    nonisolated static let uniformWordCount = transformWordOffset + 16
}

nonisolated final class ShaderEffectPainter: @unchecked Sendable {
    struct Inputs {
        var scheme: Float = 1.0
        var data: [Float] = []
        var transform: [Float] = ShaderEffectRenderer.identity
        var activity: Float = 0
        var pulsedAt: TimeInterval?
        var pointsWide: CGFloat = 0
    }

    private let program: ShaderEffectProgram
    private let layer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let buffers: CanvasGeometryBuffers?
    private let depthState: MTLDepthStencilState?
    private let depthFormat: MTLPixelFormat
    private let startTime = CACurrentMediaTime()
    private let inputsLock = NSLock()
    private var inputs = Inputs()
    private var renderedAt = CACurrentMediaTime()
    private var depthTexture: MTLTexture?

    /// Seconds for a reported arrival to fall to 1/e.
    private let pulseHalfLife: Float = 0.4
    private let activityHalfLife: Float = 1.2

    @MainActor
    init?(program: ShaderEffectProgram, view: MTKView) {
        guard let layer = view.layer as? CAMetalLayer,
              let device = view.device,
              let queue = device.makeCommandQueue(),
              let built = Self.buildPipeline(program: program, device: device, view: view)
        else { return nil }
        self.program = program
        self.layer = layer
        commandQueue = queue
        pipeline = built.pipeline
        buffers = built.buffers
        depthState = built.depthState
        depthFormat = view.depthStencilPixelFormat
    }

    func change(_ update: (inout Inputs) -> Void) {
        inputsLock.lock()
        update(&inputs)
        inputsLock.unlock()
    }

    func paint() {
        guard let drawable = layer.nextDrawable(),
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDescriptor(for: drawable.texture))
        else { return }

        let now = CACurrentMediaTime()
        let current = advance(to: now)
        let width = Float(drawable.texture.width)
        let height = Float(drawable.texture.height)

        var uniforms = [Float](repeating: 0, count: ShaderEffectRenderer.uniformWordCount)
        uniforms[0] = width
        uniforms[1] = height
        uniforms[2] = Float(now - startTime)
        uniforms[3] = current.scheme
        uniforms[4] = current.activity
        uniforms[5] = current.pulsedAt.map { exp(-Float(now - $0) / pulseHalfLife) } ?? 0
        uniforms[6] = Float(min(current.data.count, ShaderEffectRenderer.dataCapacity))
        uniforms[7] = current.pointsWide > 0 ? width / Float(current.pointsWide) : Float(layer.contentsScale)
        for (offset, value) in current.data.prefix(ShaderEffectRenderer.dataCapacity).enumerated() {
            uniforms[ShaderEffectRenderer.dataWordOffset + offset] = value
        }
        for (offset, value) in current.transform.prefix(16).enumerated() {
            uniforms[ShaderEffectRenderer.transformWordOffset + offset] = value
        }

        encoder.setRenderPipelineState(pipeline)
        let uniformLength = uniforms.count * MemoryLayout<Float>.stride
        encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
        encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)

        if case let .geometry(_, _, _, _, geometry) = program, let buffers {
            if let depthState {
                encoder.setDepthStencilState(depthState)
            }
            encoder.draw(geometry, from: buffers)
        } else {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func passDescriptor(for target: MTLTexture) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.texture = depthTexture(matching: target)
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 1
        descriptor.depthAttachment.storeAction = .dontCare
        return descriptor
    }

    private func advance(to now: TimeInterval) -> Inputs {
        inputsLock.lock()
        defer { inputsLock.unlock() }
        inputs.activity *= exp(-Float(now - renderedAt) / activityHalfLife)
        renderedAt = now
        return inputs
    }

    private func depthTexture(matching target: MTLTexture) -> MTLTexture? {
        if let depthTexture, depthTexture.width == target.width, depthTexture.height == target.height {
            return depthTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: target.width, height: target.height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        depthTexture = target.device.makeTexture(descriptor: descriptor)
        return depthTexture
    }

    @MainActor
    private static func buildPipeline(
        program: ShaderEffectProgram,
        device: MTLDevice,
        view: MTKView
    ) -> (pipeline: MTLRenderPipelineState, buffers: CanvasGeometryBuffers?, depthState: MTLDepthStencilState?)? {
        let desc = MTLRenderPipelineDescriptor()
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        var buffers: CanvasGeometryBuffers?
        var depthState: MTLDepthStencilState?

        if case let .geometry(vertexMetal, vertexName, fragmentMetal, fragmentName, geometry) = program {
            guard let vertexLibrary = try? device.makeLibrary(source: vertexMetal, options: nil),
                  let fragmentLibrary = try? device.makeLibrary(source: fragmentMetal, options: nil),
                  let vertex = vertexLibrary.makeFunction(name: vertexName),
                  let fragment = fragmentLibrary.makeFunction(name: fragmentName)
            else { return nil }

            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
            desc.vertexDescriptor = vertexDescriptor(for: geometry)
            buffers = CanvasGeometryBuffers(geometry, from: CanvasBufferStore(device: device))

            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .less
            depth.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: depth)
        } else {
            guard let bundled = try? device.makeDefaultLibrary(bundle: Bundle.main),
                  let vertex = bundled.makeFunction(name: "shaderEffectVertex"),
                  let fragment = fragmentFunction(of: program, from: device, bundled: bundled)
            else { return nil }
            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
        }

        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        return (state, buffers, depthState)
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

    /// A built-in effect is already in the default library; a translated one
    /// is compiled here, which is what lets a snippet author its own.
    private static func fragmentFunction(of program: ShaderEffectProgram, from device: MTLDevice, bundled: MTLLibrary) -> MTLFunction? {
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

    private static func format(components: Int) -> MTLVertexFormat {
        switch components {
        case 1: return .float
        case 2: return .float2
        case 3: return .float3
        default: return .float4
        }
    }
}

nonisolated private final class DisplayLinkProxy: NSObject {
    private let painter: ShaderEffectPainter

    init(painter: ShaderEffectPainter) {
        self.painter = painter
    }

    @objc func fire(_ link: CADisplayLink) {
        painter.paint()
    }
}
