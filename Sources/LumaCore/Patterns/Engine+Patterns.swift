import Foundation

public struct PatternMemoryDecoding: Sendable {
    public let value: DecodedPattern
    public let data: Data
}

public enum PatternMemoryError: LocalizedError {
    case detached

    public var errorDescription: String? {
        switch self {
        case .detached:
            return "The session is not attached."
        }
    }
}

extension Engine {
    public static let largestPatternRead = 1 << 20

    public func describePatternLibrary() async -> [[String: Any]] {
        var described: [[String: Any]] = []
        for source in patterns.sources {
            var entry: [String: Any] = ["id": source.id, "name": source.name, "kind": source.kind == .library ? "library" : "pattern"]
            if let summary = try? await patternDecoder.summary(of: source) {
                entry.merge(summary.jsonObject) { _, new in new }
            }
            described.append(entry)
        }
        return described
    }

    public func decodePattern(
        text: String, typeName: String, sessionID: UUID, address: UInt64, byteCount: Int
    ) async throws -> PatternMemoryDecoding {
        guard let node = node(forSessionID: sessionID), let target = node.processInfo else {
            throw PatternMemoryError.detached
        }
        var data = Data(try await node.readRemoteMemory(at: address, count: byteCount))
        while true {
            let value = try await patternDecoder.decode(
                text: text, typeName: typeName, data: data, address: address, platform: target.platform, arch: target.arch)
            guard value.truncated, data.count < Self.largestPatternRead,
                let more = try? await node.readRemoteMemory(at: address, count: min(data.count * 2, Self.largestPatternRead))
            else {
                return PatternMemoryDecoding(value: value, data: data)
            }
            data = Data(more)
        }
    }
}

extension PatternSummary {
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "types": declaredTypes.map { type -> [String: Any] in
                var entry: [String: Any] = ["name": type.name, "kind": "\(type.kind)"]
                if let size = type.size {
                    entry["size"] = size
                }
                return entry
            },
            "diagnostics": diagnostics.map { ["line": $0.line + 1, "column": $0.character + 1, "message": $0.message] },
        ]
        if let rootType {
            object["root_type"] = rootType
        }
        return object
    }
}
