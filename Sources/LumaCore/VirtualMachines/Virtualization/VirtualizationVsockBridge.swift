import Foundation

#if canImport(Virtualization)
import Darwin
import Virtualization

/// The agent's line is a vsock port inside the guest, which only this process
/// can dial. Frida speaks to a socket in the file system instead, so what
/// arrives there is carried to the guest and back.
@available(macOS 13, *)
@MainActor
final class VirtualizationVsockBridge {
    let socketPath: URL

    private let port: UInt32
    private let device: VZVirtioSocketDevice
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(socketPath: URL, port: UInt32, device: VZVirtioSocketDevice) {
        self.socketPath = socketPath
        self.port = port
        self.device = device
    }

    func start() throws {
        try? FileManager.default.removeItem(at: socketPath)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw VirtualMachineError.launchFailed(reason: "Unable to make the agent's socket")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw VirtualMachineError.launchFailed(reason: "The agent's socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8.enumerated().forEach { destination[$0.offset] = $0.element }
        }

        let bound = withUnsafePointer(to: &address) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            close(listener)
            listener = -1
            throw VirtualMachineError.launchFailed(reason: "Unable to open the agent's socket")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptClient() }
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        if listener >= 0 {
            close(listener)
            listener = -1
        }
        try? FileManager.default.removeItem(at: socketPath)
    }

    private func acceptClient() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }

        device.connect(toPort: port) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let connection):
                    Self.carry(between: client, and: connection)
                case .failure:
                    close(client)
                }
            }
        }
    }

    /// The guest's end belongs to the connection object, so it is held for as
    /// long as either side has something to say.
    private static func carry(between client: Int32, and connection: VZVirtioSocketConnection) {
        let guest = connection.fileDescriptor
        let done = DispatchGroup()

        for (source, destination) in [(client, guest), (guest, client)] {
            done.enter()
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let received = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
                    guard received > 0 else { break }

                    var sent = 0
                    while sent < received {
                        let wrote = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + sent, received - sent) }
                        guard wrote > 0 else { break }
                        sent += wrote
                    }
                    guard sent == received else { break }
                }
                shutdown(destination, SHUT_WR)
                done.leave()
            }
        }

        done.notify(queue: .main) {
            close(client)
            connection.close()
        }
    }
}

#endif
