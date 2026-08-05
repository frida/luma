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
}

@MainActor
public enum PharoCanvasHost {
    /// Set by each frontend to open, feed and close its own canvas.
    public static var onShow: ((CanvasEffect) -> Void)?
    public static var onReport: ((Float) -> Void)?
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
