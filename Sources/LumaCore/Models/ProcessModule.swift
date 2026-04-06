public struct ProcessModule: Hashable, Identifiable, Codable, Sendable {
    public var id: String { "\(path)@0x\(String(base, radix: 16))" }
    public let name: String
    public let path: String
    public let base: UInt64
    public let size: UInt64

    public init(name: String, path: String, base: UInt64, size: UInt64) {
        self.name = name
        self.path = path
        self.base = base
        self.size = size
    }
}
