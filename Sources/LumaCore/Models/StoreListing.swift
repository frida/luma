import Foundation

public struct StoreListing: Codable, Hashable, Sendable {
    public var summary: String
    public var category: StoreCategory.ID?
    public var access: StoreAccess

    public init(summary: String, category: StoreCategory.ID?, access: StoreAccess) {
        self.summary = summary
        self.category = category
        self.access = access
    }
}

extension StoreListing {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            summary: try c.decode(String.self, forKey: .summary),
            category: try c.decodeIfPresent(StoreCategory.ID.self, forKey: .category),
            access: try c.decode(StoreAccess.self, forKey: .access))
    }
}

public struct StorePublishDraft: Hashable, Sendable {
    public let slug: String
    public var version: StoreVersion?
    public var listing: StoreListing
    public let description: String?

    public init(slug: String, version: StoreVersion?, listing: StoreListing, description: String?) {
        self.slug = slug
        self.version = version
        self.listing = listing
        self.description = description
    }
}
