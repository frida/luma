import Foundation
import GRDB

public struct ModuleAnalysis: Codable, Sendable {
    public var sessionID: UUID
    public var modulePath: String
    public var moduleUUID: String?
    public var mappedRanges: [ProcessNode.ModuleRange]
    public var functions: [Function]
    public var analyzedAt: Date

    public enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case modulePath = "module_path"
        case moduleUUID = "module_uuid"
        case mappedRanges = "mapped_ranges"
        case functions
        case analyzedAt = "analyzed_at"
    }

    public init(
        sessionID: UUID,
        modulePath: String,
        moduleUUID: String? = nil,
        mappedRanges: [ProcessNode.ModuleRange],
        functions: [Function],
        analyzedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.modulePath = modulePath
        self.moduleUUID = moduleUUID
        self.mappedRanges = mappedRanges
        self.functions = functions
        self.analyzedAt = analyzedAt
    }

    public struct Function: Codable, Sendable, Hashable {
        public enum Source: String, Codable, Sendable {
            case exported
            case symbol
            case prelude
            case unwind
        }

        public struct Block: Codable, Sendable, Hashable {
            public var offset: UInt64
            public var size: UInt64

            public init(offset: UInt64, size: UInt64) {
                self.offset = offset
                self.size = size
            }

            private enum CodingKeys: String, CodingKey {
                case offset
                case size
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                offset = try ModuleOffset.decode(.offset, from: c)
                size = try c.decode(UInt64.self, forKey: .size)
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(ModuleOffset.number(offset), forKey: .offset)
                try c.encode(size, forKey: .size)
            }
        }

        public var offset: UInt64
        public var name: String?
        public var source: Source
        public var blocks: [Block]

        public init(offset: UInt64, name: String?, source: Source, blocks: [Block] = []) {
            self.offset = offset
            self.name = name
            self.source = source
            self.blocks = blocks
        }

        private enum CodingKeys: String, CodingKey {
            case offset
            case name
            case source
            case blocks
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            offset = try ModuleOffset.decode(.offset, from: c)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            source = try c.decode(Source.self, forKey: .source)
            blocks = try c.decode([Block].self, forKey: .blocks)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ModuleOffset.number(offset), forKey: .offset)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encode(source, forKey: .source)
            try c.encode(blocks, forKey: .blocks)
        }
    }
}

extension ModuleAnalysis {
    private static let wireEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let wireDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func toWireJSON() -> [String: Any]? {
        guard let data = try? Self.wireEncoder.encode(self),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> ModuleAnalysis? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
            let analysis = try? wireDecoder.decode(ModuleAnalysis.self, from: data)
        else { return nil }
        return analysis
    }

}
