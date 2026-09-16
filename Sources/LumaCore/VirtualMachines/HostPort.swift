import Foundation

#if canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Windows) || os(macOS) || os(Linux)

enum HostPort {
    static func reserveEphemeral() -> UInt16? {
        withBoundSocket(port: 0) { handle in
            var assigned = sockaddr_in()
            var length = socketLength(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &assigned) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    getsockname(handle, address, &length)
                }
            }
            return UInt16(bigEndian: assigned.sin_port)
        }
    }

    static func isFree(_ port: UInt16) -> Bool {
        withBoundSocket(port: port) { _ in true } ?? false
    }

    private static func withBoundSocket<T>(port: UInt16, _ body: (SocketHandle) -> T) -> T? {
        let handle = socket(AF_INET, streamSocketType, 0)
        guard handle != invalidSocket else { return nil }
        defer { closeSocket(handle) }

        var address = sockaddr_in()
        address.sin_family = addressFamily(AF_INET)
        address.sin_port = port.bigEndian
        #if os(Windows)
        address.sin_addr.S_un.S_addr = INADDR_ANY.bigEndian
        #else
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        #endif

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(handle, address, socketLength(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        return body(handle)
    }

    #if os(Windows)
    private typealias SocketHandle = SOCKET
    private static var invalidSocket: SOCKET { INVALID_SOCKET }
    private static var streamSocketType: Int32 { SOCK_STREAM }
    private static func addressFamily(_ family: Int32) -> ADDRESS_FAMILY { ADDRESS_FAMILY(family) }
    private static func socketLength(_ size: Int) -> Int32 { Int32(size) }
    private static func closeSocket(_ handle: SOCKET) { closesocket(handle) }
    #else
    private typealias SocketHandle = Int32
    private static var invalidSocket: Int32 { -1 }
    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }
    private static func addressFamily(_ family: Int32) -> sa_family_t { sa_family_t(family) }
    private static func socketLength(_ size: Int) -> socklen_t { socklen_t(size) }
    private static func closeSocket(_ handle: Int32) { close(handle) }
    #endif
}

#endif
