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
            switch instance.kind {
            case .tracer:
                let config = (try? TracerConfig.decode(from: data)) ?? TracerConfig()
                jsonObject = config.toJSON()

            case .hookPack:
                let config = (try? HookPackConfig.decode(from: data)) ?? HookPackConfig(packId: instance.sourceIdentifier, features: [:])
                jsonObject = config.toJSON()

            case .codeShare:
                if data.isEmpty {
                    jsonObject = [:]
                } else {
                    jsonObject = (try? JSONSerialization.jsonObject(with: data, options: [])) ?? [:]
                }
            }

            try await processNode.script.exports.updateInstrumentConfig(
                JSValue([
                    "instanceId": instance.id.uuidString,
                    "config": jsonObject,
                ]))
        } catch {
            lastError = "Failed to update config: \(error)"
        }
    }
}
