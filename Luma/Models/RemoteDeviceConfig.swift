import Foundation
import SwiftData

@Model
final class RemoteDeviceConfig {
    var id: UUID
    var address: String
    var certificate: String?
    var origin: String?
    var token: String?
    var keepaliveInterval: Int?

    @Transient
    var runtimeDeviceID: String?

    init(
        address: String,
        certificate: String? = nil,
        origin: String? = nil,
        token: String? = nil,
        keepaliveInterval: Int? = nil
    ) {
        self.id = UUID()
        self.address = address
        self.certificate = certificate
        self.origin = origin
        self.token = token
        self.keepaliveInterval = keepaliveInterval
        self.runtimeDeviceID = nil
    }
}
