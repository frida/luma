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

    public func toJSON() -> [String: Any] {
        return [
            "name": name,
            "path": path,
            "base": String(format: "0x%llx", base),
            "size": Int(size),
        ]
    }

    public static func fromJSON(_ obj: [String: Any]) -> ProcessModule? {
        guard let name = obj["name"] as? String,
            let path = obj["path"] as? String,
            let baseStr = obj["base"] as? String,
            let size = obj["size"] as? Int
        else { return nil }

        let base = UInt64(baseStr.dropFirst(2), radix: 16) ?? 0
        return ProcessModule(name: name, path: path, base: base, size: UInt64(size))
    }
}
