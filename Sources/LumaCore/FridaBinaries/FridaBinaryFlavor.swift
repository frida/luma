public protocol FridaBinaryFlavor: Hashable, Sendable {
    var displayName: String { get }
    var cachedFileName: String { get }
    func assetName(version: String) -> String
}
