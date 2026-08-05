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
}

struct ShaderEffectView {
    let program: ShaderEffectProgram
    let scheme: Float

    /// Bumped by the caller whenever events arrive; the renderer decays what it
    /// was last handed, so a caller only sets this when there is news.
    var activity: Float = 0

    /// Values the effect reads through `dataAt()`, up to 64.
    var data: [Float] = []

    func makeCoordinator() -> ShaderEffectRenderer {
        ShaderEffectRenderer(program: program)
    }

    fileprivate func install(into view: MTKView, coordinator: ShaderEffectRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
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
    private let program: ShaderEffectProgram
    private weak var view: MTKView?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
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
        for (offset, value) in data.prefix(Self.dataCapacity).enumerated() {
            uniforms[Self.dataWordOffset + offset] = value
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: uniforms.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    fileprivate func tick() {
        view?.draw()
    }

    private func buildPipeline(for view: MTKView) -> Bool {
        guard let device = view.device,
              let bundled = try? device.makeDefaultLibrary(bundle: Bundle.main),
              let vertex = bundled.makeFunction(name: "shaderEffectVertex"),
              let fragment = fragmentFunction(from: device, bundled: bundled),
              let queue = device.makeCommandQueue()
        else { return false }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return false }

        commandQueue = queue
        pipeline = state
        return true
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

    /// The block std140 lays out: resolution, time, scheme, activity, pulse
    /// and the value count fill the first six words, a seventh pads the vec4
    /// array to its sixteen-byte alignment, and the values follow.
    static let dataCapacity = 64
    static let dataWordOffset = 8
    static let uniformWordCount = dataWordOffset + dataCapacity
}

private final class DisplayLinkProxy: NSObject {
    weak var renderer: ShaderEffectRenderer?

    @objc func fire(_ link: CADisplayLink) {
        renderer?.tick()
    }
}
