import Foundation

public struct Author: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let avatarURL: String

    public init(id: String, name: String, avatarURL: String) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case avatarURL = "avatar_url"
    }
}
