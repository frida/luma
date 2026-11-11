import Foundation

#if canImport(Virtualization)
import Virtualization
#endif

@MainActor
public enum VirtualMachineDisplay {
    case frames(any VirtualMachineFrameSource)
    case hostedWindow(any VirtualMachineWindowSource)
    #if canImport(Virtualization)
    /// A guest the framework draws itself, given a view to draw into.
    @available(macOS 13, *)
    case virtualizationGuest(VZVirtualMachine)
    #endif
}

@MainActor
public protocol VirtualMachineFrameSource: AnyObject {
    var frame: VirtualMachineFrame? { get }
    var revision: UInt64 { get }
    var pointerIsAbsolute: Bool { get }

    func send(_ event: VirtualMachineInputEvent)
}

/// A display that belongs to a window of somebody else's, which the host
/// places where it wants the guest to appear.
@MainActor
public protocol VirtualMachineWindowSource: AnyObject {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }

    func place(in rect: VirtualMachineScreenRect)
    func hide()
}

/// Screen coordinates, measured from the bottom left as the window server
/// counts them.
public struct VirtualMachineScreenRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct VirtualMachineFrame: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let format: VirtualMachineFrameFormat
    private let pixels: UnsafeRawPointer
    private let length: Int
    private let owner: any VirtualMachineFrameStorage

    public init(
        width: Int,
        height: Int,
        stride: Int,
        format: VirtualMachineFrameFormat,
        pixels: UnsafeRawPointer,
        length: Int,
        owner: any VirtualMachineFrameStorage
    ) {
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.pixels = pixels
        self.length = length
        self.owner = owner
    }

    public func withPixels<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: pixels, count: length))
    }
}

public protocol VirtualMachineFrameStorage: AnyObject, Sendable {
}

public enum VirtualMachineFrameFormat: Sendable {
    case bgrx8888
    case bgra8888
}

public enum VirtualMachineInputEvent: Sendable, Equatable {
    case keyDown(code: UInt32)
    case keyUp(code: UInt32)
    case pointerMoved(x: Double, y: Double)
    case pointerMovedBy(dx: Double, dy: Double)
    case pointerButtonDown(button: VirtualMachinePointerButton)
    case pointerButtonUp(button: VirtualMachinePointerButton)
    case scrolled(deltaX: Double, deltaY: Double)
}

public enum VirtualMachinePointerButton: Sendable, Equatable {
    case left
    case middle
    case right
}
