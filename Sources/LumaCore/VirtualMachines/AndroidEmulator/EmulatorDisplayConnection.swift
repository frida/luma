import Foundation
import Darwin
import Accelerate
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

#if os(macOS)

typealias EmulatorController = Android_Emulation_Control_EmulatorController
typealias EmulatorImageFormat = Android_Emulation_Control_ImageFormat
typealias EmulatorImage = Android_Emulation_Control_Image
typealias EmulatorMouseEvent = Android_Emulation_Control_MouseEvent
typealias EmulatorKeyboardEvent = Android_Emulation_Control_KeyboardEvent

/// Where a running emulator's gRPC control endpoint lives, and the bearer token it
/// guards it with. The launcher writes both into the running-avd discovery ini.
struct EmulatorControlEndpoint {
    let host: String
    let port: Int
    let token: String?

    static func discover(launcherPID: Int32, port: Int) -> EmulatorControlEndpoint {
        let ini = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TemporaryItems/avd/running/pid_\(launcherPID).ini")
        let token = (try? String(contentsOf: ini, encoding: .utf8))
            .flatMap { contents in
                contents.split(separator: "\n").first { $0.hasPrefix("grpc.token=") }
            }
            .map { String($0.dropFirst("grpc.token=".count)) }
        return EmulatorControlEndpoint(host: "127.0.0.1", port: port, token: token)
    }

    var callMetadata: Metadata {
        guard let token else { return [:] }
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        return metadata
    }

    enum SnapshotVerb {
        case save
        case load
        case delete
    }

    func runSnapshot(_ verb: SnapshotVerb, name: String) async throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port), transportSecurity: .plaintext)
        let metadata = callMetadata
        try await withGRPCClient(transport: transport) { client in
            let service = Android_Emulation_Control_SnapshotService.Client(wrapping: client)
            var package = Android_Emulation_Control_SnapshotPackage()
            package.snapshotID = name

            let reply: Android_Emulation_Control_SnapshotPackage
            switch verb {
            case .save: reply = try await service.saveSnapshot(package, metadata: metadata)
            case .load: reply = try await service.loadSnapshot(package, metadata: metadata)
            case .delete: reply = try await service.deleteSnapshot(package, metadata: metadata)
            }

            if !reply.success {
                let reason = String(data: reply.err, encoding: .utf8) ?? "the emulator refused the snapshot"
                throw VirtualMachineError.snapshotFailed(reason: reason)
            }
        }
    }
}

@Observable
@MainActor
final class EmulatorDisplayConnection: VirtualMachineFrameSource {
    private(set) var frame: VirtualMachineFrame?
    private(set) var revision: UInt64 = 0
    let pointerIsAbsolute = true

    // Room for a 4096x4096 RGBA frame, which covers any emulated display and rotation.
    private static let sharedFrameBytes = 4096 * 4096 * 4

    private let endpoint: EmulatorControlEndpoint
    private let client: GRPCClient<HTTP2ClientTransport.Posix>
    private let controller: EmulatorController.Client<HTTP2ClientTransport.Posix>
    private let sharedFramePath: String
    private let sharedFrame: UnsafeRawPointer
    private var tasks: [Task<Void, Never>] = []
    private var screenshotStream: Task<Void, Never>?
    private var heldButtons: Int32 = 0
    private var lastPointer: (x: Double, y: Double)?

    init(endpoint: EmulatorControlEndpoint) throws {
        self.endpoint = endpoint
        sharedFramePath = NSTemporaryDirectory() + "frida-emulator-\(UUID().uuidString).rgba"
        sharedFrame = try Self.mapSharedFrame(at: sharedFramePath)

        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: endpoint.host, port: endpoint.port),
            transportSecurity: .plaintext
        )
        client = GRPCClient(transport: transport)
        controller = EmulatorController.Client(wrapping: client)

        tasks.append(Task { [client] in
            do { try await client.runConnections() }
            catch { Self.log("runConnections failed: \(error)") }
        })
        tasks.append(Task { await self.pumpFrames() })
        tasks.append(Task { await self.watchDisplayChanges() })
    }

    private nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[emulator-display] \(message)\n".utf8))
    }

    func send(_ event: VirtualMachineInputEvent) {
        switch event {
        case .pointerMoved(let x, let y):
            sendMouse(x: x, y: y, buttons: heldButtons)
        case .pointerButtonDown:
            heldButtons = 1
            if let last = lastPointer { sendMouse(x: last.x, y: last.y, buttons: 1) }
        case .pointerButtonUp:
            heldButtons = 0
            if let last = lastPointer { sendMouse(x: last.x, y: last.y, buttons: 0) }
        default:
            break
        }
    }

    func close() {
        client.beginGracefulShutdown()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        munmap(UnsafeMutableRawPointer(mutating: sharedFrame), Self.sharedFrameBytes)
        unlink(sharedFramePath)
    }

    /// The emulator sizes the shared frame from the requested dimensions, so each stream is opened
    /// for the display's current size and re-opened whenever a notification says it changed.
    private func pumpFrames() async {
        while !Task.isCancelled {
            guard let size = await displaySize() else { return }
            let stream = Task { await self.streamScreenshots(width: size.width, height: size.height) }
            screenshotStream = stream
            await stream.value
        }
    }

    private func watchDisplayChanges() async {
        do {
            try await controller.streamNotification(Google_Protobuf_Empty(), metadata: endpoint.callMetadata) { response in
                for try await notification in response.messages {
                    if case .displayConfigurationsChangedNotification = notification.type {
                        await self.restartStream()
                    }
                }
            }
        } catch {
        }
    }

    private func restartStream() {
        screenshotStream?.cancel()
    }

    private func displaySize() async -> (width: Int, height: Int)? {
        let configurations = try? await controller.getDisplayConfigurations(
            Google_Protobuf_Empty(), metadata: endpoint.callMetadata)
        let display = configurations?.displays.first { $0.display == 0 } ?? configurations?.displays.first
        guard let display, display.width > 0, display.height > 0 else {
            Self.log("no display configuration")
            return nil
        }
        return (Int(display.width), Int(display.height))
    }

    private func streamScreenshots(width: Int, height: Int) async {
        var format = EmulatorImageFormat()
        format.format = .rgba8888
        format.display = 0
        format.width = UInt32(width)
        format.height = UInt32(height)
        format.transport.channel = .mmap
        format.transport.handle = "file://" + sharedFramePath
        Self.log("streaming \(width)x\(height) into \(sharedFramePath)")
        do {
            try await controller.streamScreenshot(format, metadata: endpoint.callMetadata) { response in
                for try await image in response.messages {
                    await self.adopt(image)
                }
            }
        } catch {
            Self.log("streamScreenshot failed: \(error)")
        }
    }

    private func sendMouse(x: Double, y: Double, buttons: Int32) {
        lastPointer = (x, y)
        var event = EmulatorMouseEvent()
        event.x = Int32(x)
        event.y = Int32(y)
        event.buttons = buttons
        let metadata = endpoint.callMetadata
        Task { [controller] in try? await controller.sendMouse(event, metadata: metadata) { _ in } }
    }

    private func adopt(_ image: EmulatorImage) {
        let width = Int(image.format.width)
        let height = Int(image.format.height)
        let byteCount = width * height * 4
        guard width > 0, height > 0, byteCount <= Self.sharedFrameBytes else { return }
        if revision == 0 { Self.log("first frame: \(width)x\(height)") }

        let converted = Self.bgra(from: sharedFrame, width: width, height: height)
        frame = VirtualMachineFrame(
            width: width,
            height: height,
            stride: width * 4,
            format: .bgra8888,
            pixels: converted.baseAddress,
            length: byteCount,
            owner: converted
        )
        revision &+= 1
    }

    /// The emulator writes top-down RGBA rows into shared memory; the renderer wants BGRA. Reorder
    /// the channels into our own buffer, off the shared region.
    private static func bgra(from source: UnsafeRawPointer, width: Int, height: Int) -> PixelBuffer {
        let buffer = PixelBuffer(length: width * height * 4)
        var src = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source),
            height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var dst = vImage_Buffer(
            data: buffer.baseAddress, height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: width * 4)
        var map: [UInt8] = [2, 1, 0, 3]
        vImagePermuteChannels_ARGB8888(&src, &dst, &map, vImage_Flags(kvImageNoFlags))
        return buffer
    }

    private static func mapSharedFrame(at path: String) throws -> UnsafeRawPointer {
        let descriptor = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else {
            throw VirtualMachineError.launchFailed(reason: "Unable to create the emulator display buffer")
        }
        defer { Darwin.close(descriptor) }
        guard ftruncate(descriptor, off_t(sharedFrameBytes)) == 0,
            let base = mmap(nil, sharedFrameBytes, PROT_READ, MAP_SHARED, descriptor, 0),
            base != MAP_FAILED
        else {
            throw VirtualMachineError.launchFailed(reason: "Unable to map the emulator display buffer")
        }
        return UnsafeRawPointer(base)
    }
}

final class PixelBuffer: VirtualMachineFrameStorage, @unchecked Sendable {
    let baseAddress: UnsafeMutableRawPointer
    private let length: Int

    init(length: Int) {
        self.length = length
        baseAddress = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
    }

    deinit {
        baseAddress.deallocate()
    }
}

#endif
