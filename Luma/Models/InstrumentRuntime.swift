import Combine
import Foundation
import Frida
import SwiftUI

@MainActor
final class InstrumentRuntime: ObservableObject, Identifiable {
    let id: UUID

    unowned let processNode: ProcessNode
    @Bindable var instance: InstrumentInstance

    @Published var isAttached: Bool = false
    @Published var lastError: String?

    init(instance: InstrumentInstance, processNode: ProcessNode) {
        self.id = instance.id
        self.instance = instance
        self.processNode = processNode
    }

    func markAttached() {
        isAttached = true
    }

    func dispose() async {
        guard isAttached else { return }

        do {
            try await processNode.script.exports.disposeInstrument([
                "instanceId": instance.id.uuidString
            ])
        } catch {
            lastError = "Failed to dispose instrument \(instance.id): \(error)"
        }

        isAttached = false
    }

    func applyConfigJSON(_ data: Data) async {
        instance.configJSON = data

        guard isAttached else { return }

        do {
            let jsonObject: Any
            if data.isEmpty {
                jsonObject = [:]
            } else if let obj = try? JSONSerialization.jsonObject(with: data) {
                jsonObject = obj
            } else {
                jsonObject = [:]
            }

            try await processNode.script.exports.updateInstrumentConfig([
                "instanceId": instance.id.uuidString,
                "config": jsonObject,
            ])
        } catch {
            lastError = "Failed to update config: \(error)"
        }
    }
}
