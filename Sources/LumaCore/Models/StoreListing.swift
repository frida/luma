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
