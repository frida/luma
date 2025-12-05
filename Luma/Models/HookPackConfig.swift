struct HookPackConfig: Codable, Equatable {
    let packId: String
    var features: [String: FeatureConfig]

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
