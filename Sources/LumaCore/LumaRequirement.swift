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
        guard def.declaresView || files.contains(where: { HostCode.isHostCode($0.path) }) else { return nil }
        guard let declared = def.minAppVersion, declared >= .instrumentViews else { return .instrumentViews }
        return nil
    }
}

extension CustomInstrumentDef {
    mutating func requireLumaForViews(in files: [CustomInstrumentFile]) {
        guard declaresView || files.contains(where: { HostCode.isHostCode($0.path) }) else { return }
        minAppVersion = max(minAppVersion ?? .instrumentViews, .instrumentViews)
    }

    fileprivate var declaresView: Bool {
        widgets.contains { $0.kind.isView }
    }
}
