import Foundation

public struct StoreCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let itemCount: Int

    static func fromWireJSON(_ raw: Any?) -> StoreCategory? {
        guard let obj = raw as? JSONObject,
            let id = obj["id"] as? String,
            let name = obj["name"] as? String,
            let itemCount = obj["count"] as? Int,
            StoreItem.isValidName(id)
        else { return nil }
        return StoreCategory(id: id, name: name, itemCount: itemCount)
    }
}
