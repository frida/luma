import Foundation

public struct StoreAccount: Hashable, Sendable {
    public let monthlyCents: Int
    public let sponsorURL: URL
    public let publisher: StorePublisher?
    public let partnerContact: PartnerContact

    static func fromWireJSON(_ raw: Any?) -> StoreAccount? {
        guard let obj = raw as? JSONObject,
            let monthlyCents = obj["monthly_cents"] as? Int,
            let sponsorURL = (obj["sponsor_url"] as? String).flatMap(URL.init(string:)),
            let partnerContact = (obj["partner_contact"] as? String).flatMap(PartnerContact.init(rawValue:))
        else { return nil }
        return StoreAccount(
            monthlyCents: monthlyCents,
            sponsorURL: sponsorURL,
            publisher: StorePublisher.fromWireJSON(obj["publisher"]),
            partnerContact: partnerContact
        )
    }
}

public enum PartnerContact: String, Sendable {
    case unanswered
    case allowed
    case declined
}

public enum PartnerContactChoice: String, Sendable {
    case allowed
    case declined
}
