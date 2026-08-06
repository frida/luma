import Foundation
import Synchronization

/// One thing a scene draws: the author's own stages, over their own vertices,
/// with their own uniforms and where it sits. A scene holds as many as the
/// author cares to make, and each can be changed on its own.
public struct CanvasDrawable: Sendable, Equatable {
    public var geometry: CanvasGeometry
    public var vertexGLSL: String = ""
    public var fragmentGLSL: String = ""
    public var vertexMetal: String = ""
    public var fragmentMetal: String = ""
    public var transform: [Float] = CanvasDrawable.identity
    /// What the author wrote, before the host wrapped it in declarations.
    public var authorVertex: String = ""
    public var authorFragment: String = ""
    public var primitive: CanvasGeometry.Primitive = .triangles
    /// Named by the author, in the order they declared them.
    public var uniforms: [CanvasUniform] = []
    /// Those of them that are moving.
    public var drivers: [CanvasDriver] = []
    /// Runs of values the shader reads by index.
    public var buffers: [CanvasBuffer] = []
    public var isVisible = true

    public static let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    public init(geometry: CanvasGeometry = CanvasGeometry(attributes: [])) {
        self.geometry = geometry
    }

    /// The uniforms as they stand `elapsed` seconds after the drivers began,
    /// so a moving value needs no word from the image to keep moving.
    public func uniforms(after elapsed: Float) -> [CanvasUniform] {
        guard !drivers.isEmpty else { return uniforms }

        return uniforms.map { uniform in
            guard let driver = drivers.first(where: { $0.name == uniform.name }) else {
                return uniform
            }
            return CanvasUniform(name: uniform.name, values: driver.value(after: elapsed))
        }
    }

    /// The author's uniforms laid out as the generated block declares them,
    /// so Metal reads each where it expects to.
    public func packedParams(after elapsed: Float = 0) -> [Float] {
        var packed: [Float] = []
        for uniform in uniforms(after: elapsed) {
            let padding = (uniform.alignment - packed.count % uniform.alignment) % uniform.alignment
            packed.append(contentsOf: repeatElement(0, count: padding))
            packed.append(contentsOf: uniform.values.prefix(uniform.components))
            if uniform.values.count < uniform.components {
                packed.append(contentsOf: repeatElement(
                    0, count: uniform.components - uniform.values.count))
            }
        }
        // A block is rounded up to a whole vec4.
        let tail = (4 - packed.count % 4) % 4
        packed.append(contentsOf: repeatElement(0, count: tail))
        return packed
    }
}

/// A run of values too large for a uniform: a memory window, a waveform, a
/// point cloud's worth of samples. Carried as a texture the shader reads by
/// index, so scrubbing is a fresh window rather than a rebuilt scene.
public struct CanvasBuffer: Sendable, Equatable {
    public let name: String
    public var values: [Float]

    public init(name: String, values: [Float]) {
        self.name = name
        self.values = values
    }

    /// Texture side, chosen so the run fits a square-ish sheet the driver
    /// will accept. A row is the unit an index divides by.
    public var width: Int {
        max(1, min(4096, Int(Double(values.count).squareRoot().rounded(.up))))
    }

    public var height: Int {
        max(1, (values.count + width - 1) / width)
    }

    /// The values padded out to fill the sheet.
    public func padded() -> [Float] {
        var sheet = values
        sheet.append(contentsOf: repeatElement(0, count: width * height - values.count))
        return sheet
    }
}

/// What a value should do over time, said once rather than driven frame by
/// frame. The renderers work it out on their own clock, so the image is
/// never in the frame path.
public struct CanvasDriver: Sendable, Equatable {
    public enum Kind: Int32, Sendable, Equatable {
        case ramp = 0
        case oscillate = 1
    }

    public let name: String
    public let kind: Kind
    public let from: [Float]
    public let to: [Float]
    /// Seconds a ramp takes, or a full swing of an oscillation.
    public let seconds: Float

    public init(name: String, kind: Kind, from: [Float], to: [Float], seconds: Float) {
        self.name = name
        self.kind = kind
        self.from = from
        self.to = to
        self.seconds = seconds
    }

    /// Where the value sits `elapsed` seconds in.
    public func value(after elapsed: Float) -> [Float] {
        let fraction: Float
        switch kind {
        case .ramp:
            fraction = seconds <= 0 ? 1 : min(max(elapsed / seconds, 0), 1)
        case .oscillate:
            let period = seconds <= 0 ? 1 : seconds
            fraction = 0.5 - 0.5 * cos(2 * .pi * elapsed / period)
        }
        return zip(from, to).map { $0 + ($1 - $0) * fraction }
    }
}

/// A value the author named, of whatever width they asked for. Declaring it
/// is what lets the host write the declaration and pack the buffer to match,
/// so a scene is not confined to a vocabulary chosen here.
public struct CanvasUniform: Sendable, Equatable {
    public let name: String
    public var values: [Float]

    public init(name: String, values: [Float]) {
        self.name = name
        self.values = values
    }

    var components: Int { min(max(values.count, 1), 16) }

    /// Floats it occupies, and what it must start on, by std140's rules.
    var alignment: Int {
        switch components {
        case 1: return 1
        case 2: return 2
        default: return 4
        }
    }

    var glslType: String {
        switch components {
        case 1: return "float"
        case 2: return "vec2"
        case 3: return "vec3"
        case 16: return "mat4"
        default: return "vec4"
        }
    }
}

/// What a canvas window shows. Held by handle so the image can keep hold of
/// one, change it, and have the drawing follow.
public struct CanvasScene: Sendable, Equatable {
    public var drawables: [Int: CanvasDrawable] = [:]
    /// The order they draw in.
    public var order: [Int] = []

    public init() {}

    public var ordered: [CanvasDrawable] {
        order.compactMap { drawables[$0] }.filter(\.isVisible)
    }
}

/// The scenes the image is holding. Handles rather than one staged canvas, so
/// a snippet can build several and change any of them.
///
/// Reached from the image's own thread, which is why the state sits behind a
/// lock rather than on the main actor: a handle has to come back at once.
public final class CanvasRegistry: Sendable {
    public static let shared = CanvasRegistry()

    private let state = Mutex(State())

    private struct State {
        var scenes: [Int: CanvasScene] = [:]
        var nextHandle = 1
    }

    /// Told when a scene changes, so whatever shows it can follow. Called on
    /// the main thread.
    @MainActor public static var onChange: ((Int, CanvasScene) -> Void)?

    public func makeScene() -> Int {
        state.withLock { state in
            let handle = state.nextHandle
            state.nextHandle += 1
            state.scenes[handle] = CanvasScene()
            return handle
        }
    }

    public func scene(_ handle: Int) -> CanvasScene? {
        state.withLock { $0.scenes[handle] }
    }

    public func discard(_ handle: Int) {
        state.withLock { $0.scenes[handle] = nil }
    }

    public func makeDrawable(in handle: Int) -> Int {
        state.withLock { state in
            guard var scene = state.scenes[handle] else { return 0 }

            let drawable = state.nextHandle
            state.nextHandle += 1
            scene.drawables[drawable] = CanvasDrawable()
            scene.order.append(drawable)
            state.scenes[handle] = scene
            return drawable
        }
    }

    /// Changes one drawable. Answers the scene as it now stands, so the caller
    /// can hand it to whatever is showing it.
    @discardableResult
    public func update(
        _ drawable: Int,
        in handle: Int,
        _ change: (inout CanvasDrawable) -> Void
    ) -> CanvasScene? {
        state.withLock { state in
            guard var scene = state.scenes[handle], var subject = scene.drawables[drawable] else {
                return nil
            }

            change(&subject)
            scene.drawables[drawable] = subject
            state.scenes[handle] = scene
            return scene
        }
    }

    public func remove(_ drawable: Int, from handle: Int) -> CanvasScene? {
        state.withLock { state in
            guard var scene = state.scenes[handle] else { return nil }

            scene.drawables[drawable] = nil
            scene.order.removeAll { $0 == drawable }
            state.scenes[handle] = scene
            return scene
        }
    }

    /// Hands the scene to whoever shows it, on the thread they expect.
    public func publish(_ handle: Int, _ scene: CanvasScene) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CanvasRegistry.onChange?(handle, scene) }
        }
    }
}
