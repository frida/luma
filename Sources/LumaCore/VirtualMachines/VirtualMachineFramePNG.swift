import Foundation

public enum VirtualMachineFrameEncoder {
    public nonisolated(unsafe) static var png: (@Sendable (_ frame: VirtualMachineFrame, _ width: Int) -> Data?)?
}

extension VirtualMachineFrame {
    public func pngData(maxWidth: Int) -> Data? {
        VirtualMachineFrameEncoder.png?(self, min(width, maxWidth))
    }
}
