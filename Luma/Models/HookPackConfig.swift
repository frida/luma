import Foundation

struct HookPackConfig: Codable, Equatable {
    let packId: String
    var features: [String: FeatureConfig]

    static func decode(from data: Data) throws -> HookPackConfig {
        try JSONDecoder().decode(HookPackConfig.self, from: data)
    }

    func encode() -> Data {
        try! JSONEncoder().encode(self)
    }

    func toJSON() -> [String: Any] {
        [
            "packId": packId,
            "features": features.mapValues { $0.toJSON() },
        ]
    }
}

public struct FeatureConfig: Codable, Hashable {
    init() {}

    func toJSON() -> [String: String] {
        return [:]
    }
}
