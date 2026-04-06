import Foundation
import Frida

@MainActor
public final class Engine: Sendable {
    public let deviceManager = DeviceManager()

    public private(set) var processNodes: [ProcessNode] = []

    public let events: EventStream

    public let tokenStore: any TokenStore

    public init(tokenStore: any TokenStore) {
        self.tokenStore = tokenStore
        self.events = EventStream()
    }

    public func addProcessNode(_ node: ProcessNode) {
        processNodes.append(node)
    }

    public func removeProcessNode(_ node: ProcessNode) {
        processNodes.removeAll { $0 === node }
    }
}
