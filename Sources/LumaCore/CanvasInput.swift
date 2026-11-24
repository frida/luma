import Foundation

/// What the pointer and keyboard are doing over a scene, as the frontends
/// report it.
public struct CanvasInput: Sendable, Equatable {
    /// Where the pointer sits in clip space: -1 to 1, y upwards, so it lands
    /// in the same coordinates the vertices were given in.
    public var pointerX: Float = 0
    public var pointerY: Float = 0
    public var isPointerInside = false
    /// Bit 0 primary, bit 1 secondary, bit 2 middle.
    public var buttons: Int32 = 0
    public var keysDown: Set<Int32> = []

    public init() {}

    public func isDown(_ key: CanvasKey) -> Bool {
        keysDown.contains(key.rawValue)
    }
}

/// The keys a scene can be asked about, named so a frontend can map its own
/// codes onto them once. Printable keys are their own lowercase character, so
/// only the rest need naming.
public enum CanvasKey: Int32, Sendable {
    case left = 1
    case right = 2
    case up = 3
    case down = 4
    case space = 32
    case enter = 13
    case escape = 27

    /// What a typed character answers to, so `isDown: $a` needs no table.
    public static func code(for character: Character) -> Int32 {
        guard let scalar = character.lowercased().unicodeScalars.first else { return 0 }
        return Int32(scalar.value)
    }
}

public struct CanvasInputEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case down
        case move
        case up
        case scroll
        case zoom
        case keyDown
        case keyUp
        case leave
    }

    public var kind: Kind
    public var x: Float
    public var y: Float
    public var buttons: Int32
    public var dx: Float
    public var dy: Float
    public var factor: Float
    public var key: Int32
    public var width: Float
    public var height: Float

    public init(
        _ kind: Kind,
        x: Float = 0,
        y: Float = 0,
        buttons: Int32 = 0,
        dx: Float = 0,
        dy: Float = 0,
        factor: Float = 1,
        key: Int32 = 0,
        width: Float = 0,
        height: Float = 0
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.buttons = buttons
        self.dx = dx
        self.dy = dy
        self.factor = factor
        self.key = key
        self.width = width
        self.height = height
    }

    public var pharoJSON: [String: Any] {
        [
            "kind": kind.rawValue, "x": x, "y": y, "buttons": buttons, "dx": dx, "dy": dy, "factor": factor, "key": key,
            "width": width, "height": height,
        ]
    }
}

@MainActor
public final class CanvasEngagement {
    public private(set) var isEngaged = false {
        didSet {
            if isEngaged != oldValue {
                onChange?(isEngaged)
            }
        }
    }
    public var onChange: ((Bool) -> Void)?

    private let scene: Int
    private var held: Set<Int32> = []
    private var last = CanvasInputEvent(.leave)

    public init(scene: Int) {
        self.scene = scene
    }

    @discardableResult
    public func offer(_ event: CanvasInputEvent) -> Bool {
        last = event
        switch event.kind {
        case .down:
            engage()
        case .scroll, .keyDown:
            guard isEngaged else { return false }
        case .keyUp:
            guard held.contains(event.key) else { return false }
        case .leave:
            end()
        case .move, .up, .zoom:
            break
        }
        pass(event)
        return true
    }

    public func engage() {
        isEngaged = true
    }

    public func end() {
        isEngaged = false
        for key in held {
            pass(CanvasInputEvent(.keyUp, x: last.x, y: last.y, buttons: last.buttons, key: key, width: last.width, height: last.height))
        }
    }

    private func pass(_ event: CanvasInputEvent) {
        switch event.kind {
        case .keyDown:
            held.insert(event.key)
            CanvasRegistry.shared.reportInput(scene) { $0.keysDown.insert(event.key) }
        case .keyUp:
            held.remove(event.key)
            CanvasRegistry.shared.reportInput(scene) { $0.keysDown.remove(event.key) }
        default:
            break
        }
        CanvasInputListeners.deliver(event, to: scene)
    }
}

@MainActor
public enum CanvasInputListeners {
    private static var handlers: [Int: (CanvasInputEvent) -> Void] = [:]

    public static func deliver(_ event: CanvasInputEvent, to scene: Int) {
        handlers[scene]?(event)
    }

    static func listen(to scene: Int, with handler: @escaping (CanvasInputEvent) -> Void) {
        handlers[scene] = handler
    }

    static func stopListening(to scene: Int) {
        handlers[scene] = nil
    }
}
