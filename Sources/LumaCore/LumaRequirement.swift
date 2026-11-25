extension LumaVersion {
    public static let release = StoreVersion(String(string.prefix { $0 != "-" }))

    public static func meets(_ requirement: StoreVersion?) -> Bool {
        guard let requirement else { return true }
        guard let release else { return false }
        return release >= requirement
    }
}

extension StoreVersion {
    static let instrumentViews = StoreVersion(major: 3, minor: 0, patch: 0)
    static let widgetsAndSettings = StoreVersion(major: 4, minor: 0, patch: 0)

    public static func least(inEngineRange range: String) -> StoreVersion? {
        guard range.hasPrefix(">=") else { return nil }
        return StoreVersion(String(range.dropFirst(2)))
    }

    public var engineRange: String {
        ">=\(self)"
    }
}

extension CustomInstrumentBundle {
    var undeclaredLumaRequirement: StoreVersion? {
        guard let required = def.lumaRequirement(given: files) else { return nil }
        guard let declared = def.minAppVersion, declared >= required else { return required }
        return nil
    }
}

extension CustomInstrumentDef {
    mutating func requireLuma(given files: [CustomInstrumentFile]) {
        guard let required = lumaRequirement(given: files) else { return }
        minAppVersion = max(minAppVersion ?? required, required)
    }

    fileprivate func lumaRequirement(given files: [CustomInstrumentFile]) -> StoreVersion? {
        if !widgets.isEmpty || !settings.isEmpty {
            return .widgetsAndSettings
        }
        if files.contains(where: { HostCode.isHostCode($0.path) }) {
            return .instrumentViews
        }
        return nil
    }
}
