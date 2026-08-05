import Foundation

/// Lets the image put a shader effect on screen and feed it.
///
/// Unlike the synthesiser, which the image reaches through a lock-free queue,
/// a canvas is a window: the exports below hop to the main thread before the
/// frontend hears about it.
@MainActor
public enum PharoCanvasHost {
    /// Set by each frontend to open, feed and close its own canvas.
    public static var onShow: ((String) -> Void)?
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

    let effect = names[Int(index)]
    DispatchQueue.main.async {
        MainActor.assumeIsolated { PharoCanvasHost.onShow?(effect) }
    }
    return 1
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
