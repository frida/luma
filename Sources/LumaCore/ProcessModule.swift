import Foundation

public struct ProcessModule: Sendable, Identifiable, Hashable, Codable {
    public let name: String
    public let base: UInt64
    public let size: UInt64
    public let path: String

    public var id: UInt64 { base }

    public init(name: String, base: UInt64, size: UInt64, path: String) {
        self.name = name
        self.base = base
        self.size = size
        self.path = path
    }
}
