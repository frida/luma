import Foundation
import Observation

@Observable
@MainActor
final class QemuDisplayConnection: VirtualMachineFrameSource {
    private(set) var frame: VirtualMachineFrame?
    private(set) var revision: UInt64 = 0
    let pointerIsAbsolute: Bool

    private let listener: QemuDisplayListener

    init(monitor: QemuMonitor, pointerIsAbsolute: Bool, processID: Int32) async throws {
        self.pointerIsAbsolute = pointerIsAbsolute
        listener = QemuDisplayListener()
        listener.onScanout = { [weak self] frame in
            Task { @MainActor in
                self?.adopt(frame)
            }
        }
        listener.onUpdate = { [weak self] in
            Task { @MainActor in
                self?.invalidate()
            }
        }
        try await listener.attach(to: monitor, processID: processID)
    }

    func send(_ event: VirtualMachineInputEvent) {
        listener.send(event)
    }

    func close() {
        listener.close()
    }

    private func adopt(_ frame: VirtualMachineFrame) {
        self.frame = frame
        revision &+= 1
    }

    private func invalidate() {
        revision &+= 1
    }
}

