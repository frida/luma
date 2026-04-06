import Foundation

public struct RemoteDeviceConfig: Codable, Identifiable, Sendable {
    public var id: UUID
    public var address: String
    public var certificate: String?
    public var origin: String?
    public var token: String?
    public var keepaliveInterval: Int?

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
}
