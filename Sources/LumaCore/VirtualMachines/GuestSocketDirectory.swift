import Foundation

/// A unix socket's path is capped at 104 bytes, and a machine's storage
/// directory -- a UUID under Application Support -- leaves nowhere near enough
/// of that for a socket. Its sockets live somewhere short instead.
enum GuestSocketDirectory {
    static func make() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
