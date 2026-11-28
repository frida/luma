import LumaCore
import Metal
import MetalKit
import SwiftUI

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// A scene drawn inside an object's views. The image holds the scene and
/// changes it; this follows, rebuilding only what differs so moving a
/// drawable does not recompile its shaders.
struct PharoCanvasSceneView: View {
    let scene: Int

    var body: some View {
        CanvasSceneRepresentable(scene: scene)
            .id(scene)
    }
}

private struct CanvasSceneRepresentable: PlatformViewRepresentable {
    let scene: Int

    func makeCoordinator() -> CanvasSceneRenderer {
        CanvasSceneRenderer()
    }

    #if canImport(AppKit)
        func makeNSView(context: Context) -> MTKView {
            makeSceneView(context: context)
        }

        func updateNSView(_ view: MTKView, context: Context) {}
    #else
        func makeUIView(context: Context) -> MTKView {
            makeSceneView(context: context)
        }

        func updateUIView(_ view: MTKView, context: Context) {}
    #endif

    private func makeSceneView(context: Context) -> MTKView {
        let view = CanvasSceneInputView(scene: scene)
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.delegate = context.coordinator
        context.coordinator.attach(to: view, scene: scene)
        return view
    }
}

/// Reports what the pointer and keyboard are doing, for whoever drives the
/// scene to read.
final class CanvasSceneInputView: OnScreenMTKView {
    private let scene: Int
    private let engagement: CanvasEngagement
    private(set) var scheme = Scheme.light
    private var pressed: Int32 = 0

    enum Scheme {
        case light
        case dark

        var uniform: Float {
            switch self {
            case .light: 1
            case .dark: 0
            }
        }

        var clearColor: MTLClearColor {
            switch self {
            case .light: MTLClearColor(red: 0.994, green: 0.991, blue: 0.986, alpha: 1)
            case .dark: MTLClearColor(red: 0.075, green: 0.050, blue: 0.065, alpha: 1)
            }
        }
    }

    #if canImport(AppKit)
        private var tracking: NSTrackingArea?
    #endif

    init(scene: Int) {
        self.scene = scene
        engagement = CanvasEngagement(scene: scene)
        super.init(frame: .zero, device: nil)
        holdStill()
        visibilityChanged = { [weak self] _ in
            self?.sceneChanged()
        }
        CanvasSceneViews.register(self, for: scene)
        followAppearance()
        #if canImport(AppKit)
            engagement.onChange = { [weak self] _ in
                self?.noteFocusRingMaskChanged()
            }
        #else
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CanvasSceneInputView, _) in
                view.followAppearance()
            }
            isMultipleTouchEnabled = true
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
            scroll.minimumNumberOfTouches = 2
            scroll.maximumNumberOfTouches = 2
            for recognizer in [pinch, scroll] {
                recognizer.delegate = self
                addGestureRecognizer(recognizer)
            }
        #endif
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sceneChanged() {
        #if canImport(AppKit)
            needsDisplay = true
        #else
            setNeedsDisplay()
        #endif
        followMotion(after: CanvasDriver.now)
    }

    func followMotion(after frameTime: Double) {
        guard visibility == .onScreen, CanvasRegistry.shared.scene(scene)?.isMoving(at: frameTime) == true else {
            holdStill()
            return
        }
        enableSetNeedsDisplay = false
        isPaused = false
    }

    private func holdStill() {
        isPaused = true
        enableSetNeedsDisplay = true
    }

    private func followAppearance() {
        scheme = currentScheme
        clearColor = scheme.clearColor
        sceneChanged()
    }

    private var currentScheme: Scheme {
        #if canImport(AppKit)
            effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        #else
            traitCollection.userInterfaceStyle == .dark ? .dark : .light
        #endif
    }

    override func resignFirstResponder() -> Bool {
        engagement.end()
        return super.resignFirstResponder()
    }

    #if canImport(AppKit)
        override var acceptsFirstResponder: Bool { true }

        override var focusRingMaskBounds: NSRect {
            engagement.isEngaged ? bounds : .zero
        }

        override func drawFocusRingMask() {
            bounds.fill()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            followAppearance()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            guard let window else { return reportPaneClosed() }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
        }

        @objc private func windowResignedKey(_ notification: Notification) {
            engagement.end()
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
            reportPointer(at: location(of: event))
            deliver(.move, at: location(of: event))
        }

        override func mouseDragged(with event: NSEvent) {
            reportPointer(at: location(of: event))
            deliver(.move, at: location(of: event))
        }

        override func rightMouseDragged(with event: NSEvent) {
            deliver(.move, at: location(of: event))
        }

        override func otherMouseDragged(with event: NSEvent) {
            deliver(.move, at: location(of: event))
        }

        override func mouseExited(with event: NSEvent) {
            report { $0.isPointerInside = false }
            deliver(.leave, at: location(of: event))
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            reportPointer(at: location(of: event))
            report { $0.buttons |= 1 << 0 }
            press(1 << 0, at: location(of: event))
        }

        override func mouseUp(with event: NSEvent) {
            report { $0.buttons &= ~(1 << 0) }
            release(1 << 0, at: location(of: event))
        }

        override func rightMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            report { $0.buttons |= 1 << 1 }
            press(1 << 1, at: location(of: event))
        }

        override func rightMouseUp(with event: NSEvent) {
            report { $0.buttons &= ~(1 << 1) }
            release(1 << 1, at: location(of: event))
        }

        override func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == Self.middleButtonNumber else { return super.otherMouseDown(with: event) }
            window?.makeFirstResponder(self)
            report { $0.buttons |= 1 << 2 }
            press(1 << 2, at: location(of: event))
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == Self.middleButtonNumber else { return super.otherMouseUp(with: event) }
            report { $0.buttons &= ~(1 << 2) }
            release(1 << 2, at: location(of: event))
        }

        private static let middleButtonNumber = 2

        override func scrollWheel(with event: NSEvent) {
            if !deliver(.scroll, at: location(of: event), dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY)) {
                super.scrollWheel(with: event)
            }
        }

        override func magnify(with event: NSEvent) {
            deliver(.zoom, at: location(of: event), factor: Float(1 + event.magnification))
        }

        override func keyDown(with event: NSEvent) {
            if !deliver(.keyDown, at: .zero, key: Self.code(for: event)) {
                super.keyDown(with: event)
            }
        }

        override func keyUp(with event: NSEvent) {
            if !deliver(.keyUp, at: .zero, key: Self.code(for: event)) {
                super.keyUp(with: event)
            }
        }

        private func location(of event: NSEvent) -> CGPoint {
            let at = convert(event.locationInWindow, from: nil)
            return CGPoint(x: at.x, y: bounds.height - at.y)
        }

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
    #else
        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window == nil else { return }
            reportPaneClosed()
        }

        /// A finger is the pointer and its only button, so touching down is both
        /// moving there and pressing.
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            becomeFirstResponder()
            reportTouch(touches)
            report { $0.buttons |= 1 << 0 }
            if pressed == 0, let touch = touches.first {
                press(1 << 0, at: touch.location(in: self))
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            reportTouch(touches)
            if let touch = touches.first {
                deliver(.move, at: touch.location(in: self))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            report {
                $0.buttons &= ~(1 << 0)
                $0.isPointerInside = false
            }
            if pressed != 0, let touch = touches.first {
                release(1 << 0, at: touch.location(in: self))
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            touchesEnded(touches, with: event)
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let codes = presses.compactMap(Self.code)
            guard !codes.isEmpty else { return super.pressesBegan(presses, with: event) }
            codes.forEach { deliver(.keyDown, at: .zero, key: $0) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let codes = presses.compactMap(Self.code)
            guard !codes.isEmpty else { return super.pressesEnded(presses, with: event) }
            codes.forEach { deliver(.keyUp, at: .zero, key: $0) }
        }

        @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
            deliver(.zoom, at: pinch.location(in: self), factor: Float(pinch.scale))
            pinch.scale = 1
        }

        @objc private func scrolled(_ scroll: UIPanGestureRecognizer) {
            if scroll.state == .began {
                becomeFirstResponder()
                engagement.engage()
            }
            let moved = scroll.translation(in: self)
            deliver(.scroll, at: scroll.location(in: self), dx: Float(moved.x), dy: Float(moved.y))
            scroll.setTranslation(.zero, in: self)
        }

        private func reportTouch(_ touches: Set<UITouch>) {
            guard let touch = touches.first else { return }
            reportPointer(at: touch.location(in: self))
        }

        private static func code(for press: UIPress) -> Int32? {
            guard let key = press.key else { return nil }
            switch key.keyCode {
            case .keyboardLeftArrow: return CanvasKey.left.rawValue
            case .keyboardRightArrow: return CanvasKey.right.rawValue
            case .keyboardDownArrow: return CanvasKey.down.rawValue
            case .keyboardUpArrow: return CanvasKey.up.rawValue
            case .keyboardReturnOrEnter, .keypadEnter: return CanvasKey.enter.rawValue
            case .keyboardEscape: return CanvasKey.escape.rawValue
            default:
                guard let character = key.charactersIgnoringModifiers.first else { return nil }
                return CanvasKey.code(for: character)
            }
        }
    #endif

    /// Closing the pane a scene is drawn in says what Escape says, and whoever
    /// drives the scene is already watching for that.
    private func reportPaneClosed() {
        report { $0.isPointerInside = false }
        deliver(.leave, at: .zero)
        report { $0.keysDown.insert(CanvasKey.escape.rawValue) }
    }

    /// Clip space, so what a snippet reads is in the coordinates it gave its
    /// vertices in, taken from a point measured down from the view's top.
    private func reportPointer(at point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        report {
            $0.pointerX = Float(point.x / bounds.width * 2 - 1)
            $0.pointerY = Float(1 - point.y / bounds.height * 2)
            $0.isPointerInside = true
        }
    }

    private func press(_ button: Int32, at point: CGPoint) {
        pressed |= button
        deliver(.down, at: point)
    }

    private func release(_ button: Int32, at point: CGPoint) {
        pressed &= ~button
        deliver(.up, at: point)
    }

    private func report(_ change: (inout CanvasInput) -> Void) {
        CanvasRegistry.shared.reportInput(scene, change)
    }

    @discardableResult
    private func deliver(
        _ kind: CanvasInputEvent.Kind,
        at point: CGPoint,
        dx: Float = 0,
        dy: Float = 0,
        factor: Float = 1,
        key: Int32 = 0
    ) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let event = CanvasInputEvent(
            kind,
            x: Float(point.x / bounds.width * 2 - 1),
            y: Float(1 - point.y / bounds.height * 2),
            buttons: pressed,
            dx: dx,
            dy: dy,
            factor: factor,
            key: key,
            width: Float(bounds.width),
            height: Float(bounds.height))
        return engagement.offer(event)
    }
}

#if canImport(UIKit)
    extension CanvasSceneInputView: UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other.view === self
        }
    }
#endif

@MainActor
final class CanvasSceneRenderer: NSObject, MTKViewDelegate {
    var scene = CanvasScene()

    private var sceneHandle = 0
    private weak var view: CanvasSceneInputView?
    private var commandQueue: MTLCommandQueue?
    private var depthState: MTLDepthStencilState?
    private var byIndex: MTLSamplerState?
    private var acrossPicture: MTLSamplerState?
    private var built: [Int: Built] = [:]
    private var gpuBuffers: CanvasBufferStore?
    private let startTime = CACurrentMediaTime()
    private var tracedAt: CFTimeInterval = 0

    private struct Built {
        var pipeline: MTLRenderPipelineState
        var vertexMetal: String
        var fragmentMetal: String
        var geometry: CanvasGeometry?
        var buffers: CanvasGeometryBuffers?
        /// What the runs of values and pictures were stamped when their
        /// textures were made, so a frame tells them apart by the stamp
        /// rather than by reading every pixel back.
        var stamps: [UInt64] = []
        var textures: [MTLTexture] = []
    }

    func attach(to view: CanvasSceneInputView, scene handle: Int) {
        self.view = view
        sceneHandle = handle
        commandQueue = view.device?.makeCommandQueue()
        gpuBuffers = view.device.map(CanvasBufferStore.init)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = view.device?.makeDepthStencilState(descriptor: depth)

        // Nearest, clamped: a value is read at its own index, never blended
        // with a neighbor's.
        let exact = MTLSamplerDescriptor()
        exact.minFilter = .nearest
        exact.magFilter = .nearest
        exact.sAddressMode = .clampToEdge
        exact.tAddressMode = .clampToEdge
        byIndex = view.device?.makeSamplerState(descriptor: exact)

        let smooth = MTLSamplerDescriptor()
        smooth.minFilter = .linear
        smooth.magFilter = .linear
        smooth.mipFilter = .linear
        smooth.sAddressMode = .clampToEdge
        smooth.tAddressMode = .clampToEdge
        acrossPicture = view.device?.makeSamplerState(descriptor: smooth)

        if let current = CanvasRegistry.shared.scene(handle) {
            scene = current
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if let latest = CanvasRegistry.shared.scene(sceneHandle) {
            scene = latest
        }
        guard view.device != nil,
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
        uniforms[3] = (view as! CanvasSceneInputView).scheme.uniform
        // What the view is actually drawing into against what it covers:
        // the window is not always there to be asked, and this is the ratio
        // that matters either way.
        let scale = view.bounds.width > 0
            ? Float(view.drawableSize.width / view.bounds.width)
            : Float(view.pixelsPerPoint)
        uniforms[7] = scale
        CanvasRegistry.shared.reportScale(sceneHandle, scale)
        trace(view, scale: scale, uniformWidth: uniforms[0], uniformHeight: uniforms[1])

        let frameTime = CanvasDriver.now
        var drawn: [CanvasGeometry] = []
        for handle in scene.order {
            guard let subject = scene.drawables[handle], subject.isVisible,
                  let record = record(for: handle, subject, queue: commandQueue),
                  let buffers = record.buffers
            else { continue }

            for (offset, value) in subject.transform.prefix(16).enumerated() {
                uniforms[ShaderEffectRenderer.transformWordOffset + offset] = value
            }

            encoder.setRenderPipelineState(record.pipeline)
            let length = uniforms.count * MemoryLayout<Float>.stride
            encoder.setVertexBytes(&uniforms, length: length, index: 0)
            encoder.setFragmentBytes(&uniforms, length: length, index: 0)
            var params = subject.packedParams(at: frameTime)
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
            encoder.draw(subject.geometry, from: buffers)
            drawn.append(subject.geometry)
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.addCompletedHandler { [drawn] _ in
            withExtendedLifetime(drawn) {}
        }
        buffer.commit()
        forgetWhatIsNotShown()
        self.view?.followMotion(after: frameTime)
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
    private func record(for handle: Int, _ subject: CanvasDrawable, queue: MTLCommandQueue) -> Built? {
        let device = queue.device
        if var existing = built[handle],
           existing.vertexMetal == subject.vertexMetal,
           existing.fragmentMetal == subject.fragmentMetal {
            if existing.geometry != subject.geometry {
                existing.buffers = CanvasGeometryBuffers(subject.geometry, from: gpuBuffers!)
                existing.geometry = subject.geometry
                built[handle] = existing
            }
            if existing.stamps != Self.stamps(of: subject) {
                existing.stamps = Self.stamps(of: subject)
                existing.textures = Self.textures(for: subject, queue: queue)
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
            vertexMetal: subject.vertexMetal,
            fragmentMetal: subject.fragmentMetal,
            geometry: subject.geometry,
            buffers: CanvasGeometryBuffers(subject.geometry, from: gpuBuffers!),
            stamps: Self.stamps(of: subject),
            textures: Self.textures(for: subject, queue: queue))
        built[handle] = record
        return record
    }

    private func forgetWhatIsNotShown() {
        for (handle, record) in built {
            guard let subject = scene.drawables[handle] else {
                built[handle] = nil
                continue
            }
            if !subject.isVisible, record.geometry != subject.geometry {
                built[handle]?.geometry = nil
                built[handle]?.buffers = nil
            }
        }
        gpuBuffers?.keep(onlyWhat: built.values.compactMap(\.geometry))
    }

    private static func stamps(of subject: CanvasDrawable) -> [UInt64] {
        subject.buffers.map(\.stamp) + subject.images.map(\.stamp)
    }

    /// The drawable's samplers in the order the preamble declares them: its
    /// runs of values first, then its pictures.
    private static func textures(for subject: CanvasDrawable, queue: MTLCommandQueue) -> [MTLTexture] {
        subject.buffers.compactMap { sheet(for: $0, device: queue.device) }
            + subject.images.compactMap { picture(for: $0, queue: queue) }
    }

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

    private static func picture(for image: CanvasImage, queue: MTLCommandQueue) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: true)
        descriptor.mipmapLevelCount = min(descriptor.mipmapLevelCount, GlyphAtlas.mipmapLevels + 1)
        descriptor.usage = [.shaderRead]
        guard let texture = queue.device.makeTexture(descriptor: descriptor) else { return nil }

        image.pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: image.width * MemoryLayout<UInt32>.stride)
        }
        if let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
        }
        return texture
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
}

@MainActor
enum CanvasSceneViews {
    private static var views: [Int: [WeakView]] = [:]
    private static var listening = false

    private struct WeakView {
        weak var view: CanvasSceneInputView?
    }

    static func register(_ view: CanvasSceneInputView, for scene: Int) {
        listenOnce()
        views[scene, default: []].append(WeakView(view: view))
    }

    private static func listenOnce() {
        guard !listening else { return }
        listening = true
        CanvasRegistry.onChange = { handle, _ in
            changed(handle)
        }
    }

    private static func changed(_ handle: Int) {
        views[handle] = views[handle]?.filter { $0.view != nil }
        for entry in views[handle] ?? [] {
            entry.view?.sceneChanged()
        }
    }
}
