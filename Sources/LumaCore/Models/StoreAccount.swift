import Foundation

public struct StoreAccount: Hashable, Sendable {
    public let monthlyCents: Int
    public let sponsorURL: URL
    public let publisher: StorePublisher?

    static func fromWireJSON(_ raw: Any?) -> StoreAccount? {
        guard let obj = raw as? JSONObject,
            let monthlyCents = obj["monthly_cents"] as? Int,
            let sponsorURL = (obj["sponsor_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return StoreAccount(
            monthlyCents: monthlyCents,
            sponsorURL: sponsorURL,
            publisher: StorePublisher.fromWireJSON(obj["publisher"])
        )
    }
}
