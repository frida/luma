import Foundation

/// What the pointer and keyboard are doing over a scene, as the frontends
/// report it. Read rather than delivered: whoever drives the scene asks when
/// it suits them, so neither renderer has to reach into the image.
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
