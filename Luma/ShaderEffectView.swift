import Metal
import MetalKit
import QuartzCore
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A fullscreen fragment effect drawn by a pair of functions in the default
/// Metal library, fed the same resolution/time/scheme uniforms the GTK
/// frontend's `luma_shader_effect_*` widget feeds its GLSL.
struct ShaderEffectView {
    let vertexFunction: String
    let fragmentFunction: String
    let scheme: Float

    func makeCoordinator() -> ShaderEffectRenderer {
        ShaderEffectRenderer(vertexFunction: vertexFunction, fragmentFunction: fragmentFunction)
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
        context.coordinator.scheme = scheme
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
        context.coordinator.scheme = scheme
    }
}
#endif

final class ShaderEffectRenderer: NSObject, MTKViewDelegate {
    var scheme: Float = 1.0
    private let vertexFunction: String
    private let fragmentFunction: String
    private weak var view: MTKView?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private let proxy = DisplayLinkProxy()
    private let startTime = CACurrentMediaTime()

    init(vertexFunction: String, fragmentFunction: String) {
        self.vertexFunction = vertexFunction
        self.fragmentFunction = fragmentFunction
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

        var uniforms = Uniforms(
            resolution: SIMD2(Float(view.drawableSize.width),
                              Float(view.drawableSize.height)),
            time: Float(CACurrentMediaTime() - startTime),
            scheme: scheme
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
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
              let library = try? device.makeDefaultLibrary(bundle: Bundle.main),
              let vertex = library.makeFunction(name: vertexFunction),
              let fragment = library.makeFunction(name: fragmentFunction),
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

    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var scheme: Float
    }
}

private final class DisplayLinkProxy: NSObject {
    weak var renderer: ShaderEffectRenderer?

    @objc func fire(_ link: CADisplayLink) {
        renderer?.tick()
    }
}
