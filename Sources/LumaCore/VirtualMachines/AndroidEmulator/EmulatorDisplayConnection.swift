import Foundation
import Observation
import SwiftProtobuf

#if canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

typealias EmulatorImageFormat = Android_Emulation_Control_ImageFormat
typealias EmulatorImage = Android_Emulation_Control_Image
typealias EmulatorMouseEvent = Android_Emulation_Control_MouseEvent
typealias EmulatorKeyboardEvent = Android_Emulation_Control_KeyboardEvent

/// Where a running emulator's gRPC control endpoint lives, and the bearer token it
/// guards it with. The launcher writes both into the running-avd discovery ini.
struct EmulatorControlEndpoint: Sendable {
    let host: String
    let port: Int
    let token: String?

    static func discover(launcherPID: Int32, port: Int, gdbPort: UInt16) -> EmulatorControlEndpoint {
        let contents = runningAVDEntry(launcherPID: launcherPID, gdbPort: gdbPort)
        let token = contents
            .flatMap { text in
                text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("grpc.token=") }
            }
            .map { String($0.dropFirst("grpc.token=".count)) }
        return EmulatorControlEndpoint(host: "127.0.0.1", port: port, token: token)
    }

    private static func runningAVDEntry(launcherPID: Int32, gdbPort: UInt16) -> String? {
        let directory = runningAVDDirectory
        let named = directory.appendingPathComponent("pid_\(launcherPID).ini")
        if let contents = try? String(contentsOf: named, encoding: .utf8) {
            return contents
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("pid_") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .first { $0.contains("tcp::\(gdbPort)") }
    }

    private static var runningAVDDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        let base = home.appendingPathComponent("Library/Caches/TemporaryItems", isDirectory: true)
        #elseif os(Windows)
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #else
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".android", isDirectory: true)
        #endif
        return base.appendingPathComponent("avd/running", isDirectory: true)
    }

    var callHeaders: [(name: String, value: String)] {
        guard let token else { return [] }
        return [(name: "authorization", value: "Bearer \(token)")]
    }

    func connect() async throws -> EmulatorControlClient {
        EmulatorControlClient(
            connection: try await GRPCConnection(host: host, port: port, headers: callHeaders))
    }

    func runSnapshot(_ verb: EmulatorControlClient.SnapshotVerb, name: String) async throws {
        let client = try await connect()
        defer { Task { await client.close() } }
        try await client.runSnapshot(verb, name: name)
    }
}

@Observable
@MainActor
final class EmulatorDisplayConnection: VirtualMachineFrameSource {
    private(set) var frame: VirtualMachineFrame?
    private(set) var revision: UInt64 = 0
    let pointerIsAbsolute = true

    private let endpoint: EmulatorControlEndpoint
    private let sharedFrame: SharedFrameBuffer?
    private var client: EmulatorControlClient?
    private var tasks: [Task<Void, Never>] = []
    private var screenshotStream: Task<Void, Never>?
    private var heldButtons: Int32 = 0
    private var lastPointer: (x: Double, y: Double)?

    init(endpoint: EmulatorControlEndpoint) {
        self.endpoint = endpoint
        self.sharedFrame = SharedFrameBuffer.make()
        tasks.append(Task { await self.run() })
    }

    private func run() async {
        do {
            client = try await endpoint.connect()
        } catch {
            Self.log("unable to reach the emulator's control endpoint: \(error)")
            return
        }
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
        for task in tasks { task.cancel() }
        tasks.removeAll()
        if let client {
            Task { await client.close() }
        }
        client = nil
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
        guard let client else { return }
        do {
            for try await notification in client.notifications() {
                if case .displayConfigurationsChangedNotification = notification.type {
                    restartStream()
                }
            }
        } catch {
        }
    }

    private func restartStream() {
        screenshotStream?.cancel()
    }

    private func displaySize() async -> (width: Int, height: Int)? {
        guard let client else { return nil }
        let configurations = try? await client.displayConfigurations()
        let display = configurations?.displays.first { $0.display == 0 } ?? configurations?.displays.first
        guard let display, display.width > 0, display.height > 0 else {
            Self.log("no display configuration")
            return nil
        }
        return (Int(display.width), Int(display.height))
    }

    private func streamScreenshots(width: Int, height: Int) async {
        guard let client else { return }
        var format = EmulatorImageFormat()
        format.format = .rgba8888
        format.display = 0
        format.width = UInt32(width)
        format.height = UInt32(height)
        if let sharedFrame {
            format.transport.channel = .mmap
            format.transport.handle = sharedFrame.handle
        }
        Self.log("streaming \(width)x\(height)\(sharedFrame.map { " into \($0.handle)" } ?? "")")
        do {
            for try await image in client.screenshots(format: format) {
                adopt(image)
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
        guard let client else { return }
        Task { try? await client.sendMouse(event) }
    }

    private func adopt(_ image: EmulatorImage) {
        let width = Int(image.format.width)
        let height = Int(image.format.height)
        let byteCount = width * height * 4
        guard width > 0, height > 0 else { return }
        if revision == 0 { Self.log("first frame: \(width)x\(height)") }

        let converted: PixelBuffer
        if !image.image.isEmpty {
            guard image.image.count >= byteCount else { return }
            converted = image.image.withUnsafeBytes { source in
                Self.bgra(from: source.baseAddress!, width: width, height: height)
            }
        } else if let sharedFrame, byteCount <= sharedFrame.byteCount {
            converted = Self.bgra(from: sharedFrame.baseAddress, width: width, height: height)
        } else {
            return
        }

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
        let count = width * height
        let buffer = PixelBuffer(length: count * 4)
        let input = source.bindMemory(to: UInt32.self, capacity: count)
        let output = buffer.baseAddress.bindMemory(to: UInt32.self, capacity: count)
        for index in 0..<count {
            let pixel = input[index]
            output[index] =
                (pixel & 0xff00_ff00) | ((pixel & 0x00ff_0000) >> 16) | ((pixel & 0x0000_00ff) << 16)
        }
        return buffer
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

final class SharedFrameBuffer {
    static let byteCount = 4096 * 4096 * 4

    let baseAddress: UnsafeRawPointer
    let handle: String
    private let path: String
    #if os(Windows)
    private let mapping: HANDLE
    #endif

    var byteCount: Int { Self.byteCount }

    static func make() -> SharedFrameBuffer? {
        let path = NSTemporaryDirectory() + "frida-emulator-\(UUID().uuidString).rgba"
        #if os(Windows)
        guard let file = path.withCString(encodedAs: UTF16.self, { wide in
            CreateFileW(
                wide,
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                nil,
                DWORD(CREATE_ALWAYS),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }), file != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(file) }

        let size = UInt64(byteCount)
        guard let mapping = CreateFileMappingW(
            file, nil, DWORD(PAGE_READWRITE), DWORD(size >> 32), DWORD(size & 0xffff_ffff), nil
        ) else { return nil }

        guard let base = MapViewOfFile(mapping, DWORD(FILE_MAP_READ), 0, 0, SIZE_T(byteCount)) else {
            CloseHandle(mapping)
            return nil
        }
        return SharedFrameBuffer(baseAddress: UnsafeRawPointer(base), path: path, mapping: mapping)
        #else
        let descriptor = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(byteCount)) == 0,
            let base = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0),
            base != MAP_FAILED
        else { return nil }
        return SharedFrameBuffer(baseAddress: UnsafeRawPointer(base), path: path)
        #endif
    }

    #if os(Windows)
    private init(baseAddress: UnsafeRawPointer, path: String, mapping: HANDLE) {
        self.baseAddress = baseAddress
        self.path = path
        self.mapping = mapping
        self.handle = "file://" + path.replacingOccurrences(of: "\\", with: "/")
    }
    #else
    private init(baseAddress: UnsafeRawPointer, path: String) {
        self.baseAddress = baseAddress
        self.path = path
        self.handle = "file://" + path
    }
    #endif

    deinit {
        #if os(Windows)
        UnmapViewOfFile(baseAddress)
        CloseHandle(mapping)
        try? FileManager.default.removeItem(atPath: path)
        #else
        munmap(UnsafeMutableRawPointer(mutating: baseAddress), Self.byteCount)
        unlink(path)
        #endif
    }
}
