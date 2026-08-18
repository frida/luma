import Foundation
import Frida

#if os(macOS)

/// vphone-cli's control socket: one JSON object per line, one reply, and the
/// connection closes again.
struct VPhoneControlClient: Sendable {
    let socketPath: URL

    func wakeScreen() {
        press(.home)
    }

    func touch(phase: VPhoneTouchPhase, x: Double, y: Double) {
        send(["t": "touch", "phase": phase.rawValue, "x": Int(x), "y": Int(y), "screen": false])
    }

    func press(_ key: VPhoneHardwareKey) {
        send(["t": "key", "name": key.rawValue, "screen": false])
    }

    func place(in rect: VirtualMachineScreenRect) {
        send(["t": "place", "x": rect.x, "y": rect.y, "w": rect.width, "h": rect.height])
    }

    func hide() {
        send(["t": "hide"])
    }

    private func send(_ command: [String: Any]) {
        guard let request = try? JSONSerialization.data(withJSONObject: command) else { return }

        Task.detached {
            guard let socket = try? GLib.Socket.connect(unixPath: socketPath.path) else { return }
            defer { socket.close() }

            try? socket.send(Array(request) + [UInt8(ascii: "\n")])
            _ = try? socket.receive(upTo: 4096)
        }
    }
}

enum VPhoneTouchPhase: Int, Sendable {
    case began = 0
    case moved = 1
    case ended = 3
}

enum VPhoneHardwareKey: String, Sendable {
    case home
    case power
    case volumeUp = "volup"
    case volumeDown = "voldown"
}

#endif
