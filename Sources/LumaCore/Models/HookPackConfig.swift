import Foundation

public struct HookPackConfig: Codable, Equatable {
    public let packId: String
    public var features: [String: FeatureConfig]

    public init(packId: String, features: [String: FeatureConfig]) {
        self.packId = packId
        self.features = features
    }

    public static func decode(from data: Data) throws -> HookPackConfig {
        try JSONDecoder().decode(HookPackConfig.self, from: data)
    }

    public func encode() -> Data {
        try! JSONEncoder().encode(self)
    }

    public func toJSON() -> [String: Any] {
        [
            "packId": packId,
            "features": features.mapValues { $0.toJSON() },
        ]
    }
}

public struct FeatureConfig: Codable, Hashable {
    public init() {}

    public func toJSON() -> [String: String] {
        return [:]
    }
}
