import Foundation

public struct CustomInstrumentConfig: Codable, Equatable, Sendable {
    public var defID: UUID
    public var settings: [String: SettingState]

    enum CodingKeys: String, CodingKey {
        case defID = "def_id"
        case settings
    }

    public init(defID: UUID, settings: [String: SettingState] = [:]) {
        self.defID = defID
        self.settings = settings
    }

    public static func decode(from data: Data) throws -> CustomInstrumentConfig {
        try JSONDecoder().decode(CustomInstrumentConfig.self, from: data)
    }

    public func encode() -> Data {
        try! JSONEncoder().encode(self)
    }

    public mutating func normalize(against def: CustomInstrumentDef) {
        defID = def.id
        var newSettings: [String: SettingState] = [:]
        for setting in def.settings {
            if let existing = settings[setting.id] {
                newSettings[setting.id] = SettingState(
                    enabled: existing.enabled,
                    value: existing.value.reconciled(with: setting.schema)
                )
            } else {
                newSettings[setting.id] = SettingState(
                    enabled: setting.enabledByDefault,
                    value: setting.schema.defaultValue
                )
            }
        }
        settings = newSettings
    }

    public func normalized(against def: CustomInstrumentDef) -> CustomInstrumentConfig {
        var copy = self
        copy.normalize(against: def)
        return copy
    }

    public func toAgentJSON(def: CustomInstrumentDef) -> [String: Any] {
        let current = normalized(against: def)
        let entries = def.settings.compactMap { setting -> (String, Any)? in
            guard let state = current.settings[setting.id] else { return nil }
            if setting.optional && !state.enabled { return nil }
            return (setting.id, state.value.toJSONNative())
        }
        return ["settings": Dictionary(uniqueKeysWithValues: entries)]
    }
}

public struct SettingState: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var value: SettingValue

    public init(enabled: Bool, value: SettingValue) {
        self.enabled = enabled
        self.value = value
    }
}
