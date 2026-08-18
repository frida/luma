import Foundation
import Observation

#if os(macOS)

@Observable
@MainActor
final class VPhoneMachine: VirtualMachine {
    let id: UUID
    let name: String
    let template: VirtualMachineTemplate
    private(set) var state: VirtualMachineState = .starting
    private(set) var display: VirtualMachineDisplay?
    private(set) var debugStub: BareboneDebugStub?
    private(set) var agentTransport: BareboneAgentTransport?

    var capabilities: VirtualMachineCapabilities {
        [.liveDisplay, .input]
    }

    private let executable: URL
    private let config: URL
    private let variant: VPhoneVariant
    private let control: VPhoneControlClient
    private let process = Process()

    init(executable: URL, config: URL, variant: VPhoneVariant, request: VirtualMachineLaunchRequest) {
        self.id = request.id
        self.name = request.name
        self.template = request.template
        self.executable = executable
        self.config = config
        self.variant = variant
        self.control = VPhoneControlClient(socketPath: config.deletingLastPathComponent().appendingPathComponent("vphone.sock"))
    }

    func start() async throws {
        let output = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = config.deletingLastPathComponent()
        process.arguments = [
            "--config", config.lastPathComponent,
            "--variant", variant.rawValue,
            "--embed",
            "--frida",
        ]
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            state = .failed(reason: error.localizedDescription)
            throw VirtualMachineError.launchFailed(reason: error.localizedDescription)
        }

        do {
            let announced = try await VPhoneAnnouncements.read(from: output.fileHandleForReading)
            display = .hostedWindow(
                VPhoneDisplay(
                    pixelWidth: announced.pixelWidth,
                    pixelHeight: announced.pixelHeight,
                    control: control
                )
            )
            debugStub = .gdbRemote(host: announced.gdbHost, port: announced.gdbPort)
            agentTransport = .vsock(socketPath: announced.hostlinkSocket, port: VPhoneAnnouncements.hostlinkPort)
            state = .running
            control.wakeScreen()
        } catch {
            await shutDown()
            state = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    func captureReadySnapshot() async throws {
        throw VirtualMachineError.snapshotFailed(reason: "A vphone guest cannot be snapshotted")
    }

    func restoreReadySnapshot() async throws {
        throw VirtualMachineError.snapshotFailed(reason: "A vphone guest cannot be snapshotted")
    }

    func discardReadySnapshot() async throws {
        throw VirtualMachineError.snapshotFailed(reason: "A vphone guest cannot be snapshotted")
    }

    func shutDown() async {
        await process.terminateAndWaitForExit()
        display = nil
        debugStub = nil
        agentTransport = nil
        state = .stopped
    }
}

@MainActor
final class VPhoneDisplay: VirtualMachineWindowSource {
    let pixelWidth: Int
    let pixelHeight: Int

    private let control: VPhoneControlClient
    private var placement: VirtualMachineScreenRect?

    init(pixelWidth: Int, pixelHeight: Int, control: VPhoneControlClient) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.control = control
    }

    func place(in rect: VirtualMachineScreenRect) {
        guard placement != rect else { return }
        placement = rect
        control.place(in: rect)
    }

    func hide() {
        placement = nil
        control.hide()
    }
}

/// What vphone-cli says on the way up: where its display lives, and how to
/// reach the guest's stub and the agent that connects back out of it.
struct VPhoneAnnouncements {
    let pixelWidth: Int
    let pixelHeight: Int
    let gdbHost: String
    let gdbPort: UInt16
    let hostlinkSocket: URL

    static let hostlinkPort: UInt = 1339

    /// The guest's serial console shares this stream, and it is not text, so
    /// the bytes are split by hand and decoded leniently.
    static func read(from handle: FileHandle) async throws -> VPhoneAnnouncements {
        var display: (Int, Int)?
        var gdb: (String, UInt16)?
        var socket: URL?

        for try await line in handle.lines {
            display = self.display(in: line) ?? display
            gdb = gdbEndpoint(in: line) ?? gdb
            socket = hostlinkSocket(in: line) ?? socket

            if let display, let gdb, let socket {
                return VPhoneAnnouncements(
                    pixelWidth: display.0,
                    pixelHeight: display.1,
                    gdbHost: gdb.0,
                    gdbPort: gdb.1,
                    hostlinkSocket: socket
                )
            }
        }

        throw VirtualMachineError.launchFailed(reason: "vphone-cli stopped before the guest was reachable")
    }

    private static func display(in line: String) -> (Int, Int)? {
        guard line.contains("[embed] ready size:") else { return nil }

        let fields = line.components(separatedBy: .whitespaces)
        guard let size = fields.last?.components(separatedBy: "x"),
            size.count == 2,
            let width = Int(size[0]),
            let height = Int(size[1])
        else {
            return nil
        }

        return (width, height)
    }

    private static func gdbEndpoint(in line: String) -> (String, UInt16)? {
        guard line.contains("gdb stub bridged at"), let endpoint = line.components(separatedBy: " at ").last else {
            return nil
        }

        let parts = endpoint.components(separatedBy: .whitespaces)[0].components(separatedBy: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }

        return (parts[0], port)
    }

    private static func hostlinkSocket(in line: String) -> URL? {
        guard line.contains("hostlink socket:"), let path = line.components(separatedBy: "hostlink socket: ").last else {
            return nil
        }
        return URL(fileURLWithPath: path.trimmingCharacters(in: .whitespaces))
    }
}

#endif

private final class PendingBytes: @unchecked Sendable {
    var data = Data()
}

extension FileHandle {
    var lines: AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = PendingBytes()

            readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }

                buffer.data.append(chunk)
                while let end = buffer.data.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer.data[buffer.data.startIndex..<end]
                    buffer.data = buffer.data[buffer.data.index(after: end)...]
                    continuation.yield(String(decoding: line, as: UTF8.self))
                }
            }

            continuation.onTermination = { _ in
                self.readabilityHandler = nil
            }
        }
    }
}
