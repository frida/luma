import Foundation
import Frida

@MainActor
public final class ProcessNode: Identifiable, Sendable {
    public let id = UUID()

    public let device: Device
    public let session: Session

    public private(set) var script: Script?
    public private(set) var modules: [ProcessModule] = []

    public init(device: Device, session: Session) {
        self.device = device
        self.session = session
    }

    public func loadScript(source: String, name: String) async throws {
        let script = try await session.createScript(source, name: name, runtime: .v8)
        try await script.load()
        self.script = script
    }
}
