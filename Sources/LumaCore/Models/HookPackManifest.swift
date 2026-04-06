import Foundation

public struct HookPackManifest: Decodable, Sendable {
    public struct Icon: Decodable, Sendable {
        public var systemName: String?
        public var file: String?

        public init(systemName: String? = nil, file: String? = nil) {
            self.systemName = systemName
            self.file = file
        }
    }

    public struct Feature: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let defaultEnabled: Bool

        public init(id: String, name: String, defaultEnabled: Bool) {
            self.id = id
            self.name = name
            self.defaultEnabled = defaultEnabled
        }
    }

    public let id: String
    public let name: String
    public let icon: Icon?
    public let entry: String
    public var features: [Feature]

    public init(id: String, name: String, icon: Icon?, entry: String, features: [Feature]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.entry = entry
        self.features = features
    }
}
