import Foundation

public struct CustomInstrumentConfig: Codable, Equatable, Sendable {
    public var defID: UUID
    public var features: [String: FeatureState]

    public init(defID: UUID, features: [String: FeatureState] = [:]) {
        self.defID = defID
        self.features = features
    }

    public static func decode(from data: Data) throws -> CustomInstrumentConfig {
        try JSONDecoder().decode(CustomInstrumentConfig.self, from: data)
    }

    public func encode() -> Data {
        try! JSONEncoder().encode(self)
    }

    public mutating func normalize(against def: CustomInstrumentDef) {
        defID = def.id
        var newFeatures: [String: FeatureState] = [:]
        for feature in def.features {
            if let existing = features[feature.id] {
                newFeatures[feature.id] = FeatureState(
                    enabled: existing.enabled,
                    value: existing.value.reconciled(with: feature.schema)
                )
            } else {
                newFeatures[feature.id] = FeatureState(
                    enabled: feature.enabledByDefault,
                    value: feature.schema.defaultValue
                )
            }
        }
        features = newFeatures
    }

    public func normalized(against def: CustomInstrumentDef) -> CustomInstrumentConfig {
        var copy = self
        copy.normalize(against: def)
        return copy
    }

    public func toAgentJSON(def: CustomInstrumentDef) -> [String: Any] {
        let current = normalized(against: def)
        let entries = def.features.compactMap { feature -> (String, Any)? in
            guard let state = current.features[feature.id] else { return nil }
            if feature.optional && !state.enabled { return nil }
            return (feature.id, state.value.toJSONNative())
        }
        return ["settings": Dictionary(uniqueKeysWithValues: entries)]
    }
}

public struct FeatureState: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var value: FeatureValue

    public init(enabled: Bool, value: FeatureValue) {
        self.enabled = enabled
        self.value = value
    }
}
