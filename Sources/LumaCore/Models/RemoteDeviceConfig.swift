import Foundation
import GRDB

public struct RemoteDeviceConfig: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "remote_device_config"

    public var id: UUID
    public var address: String
    public var certificate: String?
    public var origin: String?
    public var token: String?
    public var keepaliveInterval: Int?

    public var runtimeDeviceID: String?

    public init(
        id: UUID = UUID(),
        address: String,
        certificate: String? = nil,
        origin: String? = nil,
        token: String? = nil,
        keepaliveInterval: Int? = nil
    ) {
        self.id = id
        self.address = address
        self.certificate = certificate
        self.origin = origin
        self.token = token
        self.keepaliveInterval = keepaliveInterval
    }

    enum CodingKeys: String, CodingKey {
        case id
        case address
        case certificate
        case origin
        case token
        case keepaliveInterval = "keepalive_interval"
    }
}
