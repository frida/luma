import Foundation

public struct PatternMemoryDecoding: Sendable {
    public let value: DecodedPattern
    public let data: Data
}

public enum PatternMemoryError: LocalizedError {
    case detached
    case patternMissing

    public var errorDescription: String? {
        switch self {
        case .detached:
            return "The session is not attached."
        case .patternMissing:
            return "Its pattern is no longer in the project."
        }
    }
}

extension Engine {
    public static let largestPatternRead = 1 << 20

    public func describePatternLibrary() async -> [[String: Any]] {
        var described: [[String: Any]] = []
        for source in patterns.placeableSources {
            var entry: [String: Any] = [
                "id": source.id, "name": source.name, "kind": source.kind == .library ? "library" : "pattern",
                "file": source.workspacePath,
            ]
            switch source.origin {
            case .project:
                break
            case .package(let package):
                entry["package"] = package
            case .instrument(let instrument):
                entry["instrument"] = instrument
            }
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

    public func describe(_ source: PatternSource, forSession sessionID: UUID?) async throws -> PatternSummary {
        let target = patternTarget(forSession: sessionID)
        return try await patternDecoder.summary(of: source, platform: target?.platform, arch: target?.arch)
    }

    public func decode(
        _ placement: PatternPlacement, in data: Data, at baseAddress: UInt64, forSession sessionID: UUID?
    ) async throws -> DecodedPattern {
        let target = patternTarget(forSession: sessionID)
        return try await patternDecoder.decode(
            try source(of: placement), typeName: placement.typeName, data: Self.bytes(of: data, at: placement),
            address: baseAddress &+ UInt64(placement.offset), platform: target?.platform, arch: target?.arch)
    }

    public func call(
        _ function: String, on nodeID: UInt, of placement: PatternPlacement, in data: Data, at baseAddress: UInt64,
        forSession sessionID: UUID?
    ) async throws -> String {
        let target = patternTarget(forSession: sessionID)
        return try await patternDecoder.callFunction(
            function, on: nodeID, of: try source(of: placement), typeName: placement.typeName,
            data: Self.bytes(of: data, at: placement), address: baseAddress &+ UInt64(placement.offset), platform: target?.platform,
            arch: target?.arch)
    }

    public func patternTarget(forSession sessionID: UUID?) -> ProcessSession.ProcessInfo? {
        sessionID.flatMap(session(id:))?.processInfo
    }

    private func source(of placement: PatternPlacement) throws -> PatternSource {
        guard let source = patterns.source(withID: placement.sourceID) else {
            throw PatternMemoryError.patternMissing
        }
        return source
    }

    private static func bytes(of data: Data, at placement: PatternPlacement) -> Data {
        data.suffix(from: data.startIndex + min(placement.offset, data.count))
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
