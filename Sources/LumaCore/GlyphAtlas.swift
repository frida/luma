import Foundation
import Synchronization

/// The printable range drawn into one picture, on a grid of equal cells, with
/// what a caller needs to lay a string out over it.
///
/// The host rasterises this, not the image: what fonts an image can reach is
/// its own business, and on one of ours the answer is a single bitmap size.
public struct GlyphAtlas: Sendable {
    /// One word a pixel, in the order the renderers upload.
    public let pixels: [UInt32]
    public let width: Int
    public let height: Int
    public let cellWidth: Int
    public let cellHeight: Int
    public let columns: Int
    /// The rows of a cell the lettering actually touches, so a caller can lay
    /// out to the ink rather than to the leading around it.
    public let inkTop: Int
    public let inkBottom: Int
    /// How far the pen moves for each code in `first...last`, in pixels.
    public let advances: [Float]

    public static let first = 32
    public static let last = 126

    public init(
        pixels: [UInt32],
        width: Int,
        height: Int,
        cellWidth: Int,
        cellHeight: Int,
        columns: Int,
        inkTop: Int,
        inkBottom: Int,
        advances: [Float]
    ) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.columns = columns
        self.inkTop = inkTop
        self.inkBottom = inkBottom
        self.advances = advances
    }

    public func advance(for code: Int) -> Float {
        let at = code - Self.first
        guard advances.indices.contains(at) else { return Float(cellWidth) / 2 }
        return advances[at]
    }
}

/// Whoever can rasterise one. The frontends register their own on the way up
/// -- Core Text on Apple platforms, Pango elsewhere -- since neither travels.
public enum GlyphAtlasRasteriser {
    private static let held = Mutex<[Int: GlyphAtlas]>([:])
    private static let nextHandle = Mutex(0)

    /// Set once by the host. Answers nil for a size it cannot draw.
    public nonisolated(unsafe) static var rasterise: (@Sendable (_ pixelSize: Int) -> GlyphAtlas?)?

    /// Rasterises and keeps it, so the image can ask about it a field at a
    /// time and then hand it to a drawable.
    public static func make(pixelSize: Int) -> Int {
        guard let atlas = rasterise?(pixelSize) else { return 0 }

        let handle = nextHandle.withLock { handle in
            handle += 1
            return handle
        }
        held.withLock { $0[handle] = atlas }
        return handle
    }

    public static func atlas(_ handle: Int) -> GlyphAtlas? {
        held.withLock { $0[handle] }
    }

    public static func discard(_ handle: Int) {
        held.withLock { $0[handle] = nil }
    }
}
