import Combine
import Foundation
import Frida
import LumaCore
import SwiftUI

@MainActor
final class InstrumentRuntime: ObservableObject, Identifiable {
    let id: UUID

    unowned let processNode: ProcessNodeViewModel
    var instance: LumaCore.InstrumentInstance

    @Published var isAttached: Bool = false
    @Published var lastError: String?

    init(instance: LumaCore.InstrumentInstance, processNode: ProcessNodeViewModel) {
        self.id = instance.id
        self.instance = instance
        self.processNode = processNode
    }

    var displayName: String {
        InstrumentMetadataRegistry.shared.displayName(for: instance)
    }

    var displayIcon: InstrumentIcon {
        InstrumentMetadataRegistry.shared.icon(for: instance)
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

    func applyConfigObject(_ configObject: Any, rawConfigJSON: Data) async {
        instance.configJSON = rawConfigJSON
        processNode.core.updateInstrumentConfig(id: instance.id, configJSON: rawConfigJSON)

        guard isAttached else { return }

        do {
            try await processNode.script.exports.updateInstrumentConfig(
                JSValue([
                    "instanceId": instance.id.uuidString,
                    "config": configObject,
                ]))
        } catch {
            lastError = "Failed to update config: \(error)"
        }
    }
}
