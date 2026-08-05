import Foundation

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
    /// Named by the author, in the order they declared them.
    public var uniforms: [CanvasUniform] = []
    public var isVisible = true

    public static let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    public init(geometry: CanvasGeometry = CanvasGeometry(attributes: [])) {
        self.geometry = geometry
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
@MainActor
public final class CanvasRegistry {
    public static let shared = CanvasRegistry()

    private var scenes: [Int: CanvasScene] = [:]
    private var nextHandle = 1

    /// Told when a scene changes, so whatever is showing it can redraw.
    public var onChange: ((Int, CanvasScene) -> Void)?

    public func makeScene() -> Int {
        let handle = nextHandle
        nextHandle += 1
        scenes[handle] = CanvasScene()
        return handle
    }

    public func scene(_ handle: Int) -> CanvasScene? {
        scenes[handle]
    }

    public func discard(_ handle: Int) {
        scenes[handle] = nil
    }

    public func makeDrawable(in handle: Int) -> Int {
        guard var scene = scenes[handle] else { return 0 }

        let drawable = nextHandle
        nextHandle += 1
        scene.drawables[drawable] = CanvasDrawable()
        scene.order.append(drawable)
        scenes[handle] = scene
        return drawable
    }

    /// Changes one drawable and tells whoever is showing the scene. Every edit
    /// goes through here, so a scene never draws half-changed.
    public func update(_ drawable: Int, in handle: Int, _ change: (inout CanvasDrawable) -> Void) {
        guard var scene = scenes[handle], var subject = scene.drawables[drawable] else { return }

        change(&subject)
        scene.drawables[drawable] = subject
        scenes[handle] = scene
        onChange?(handle, scene)
    }

    public func remove(_ drawable: Int, from handle: Int) {
        guard var scene = scenes[handle] else { return }

        scene.drawables[drawable] = nil
        scene.order.removeAll { $0 == drawable }
        scenes[handle] = scene
        onChange?(handle, scene)
    }
}
