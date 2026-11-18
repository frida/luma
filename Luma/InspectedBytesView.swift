import LumaCore
import SwiftUI

struct InspectedBytesView: View {
    let bytes: JSInspectValue.Bytes
    let sessionID: UUID
    let engine: Engine

    @Environment(\.storedValue) private var storedValue
    @Environment(\.storedPlacements) private var storedPlacements
    @State private var unstoredPlacements: [PatternPlacement] = []
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bytes(\(bytes.kind.rawValue)[\(bytes.data.count)])")
                .foregroundStyle(.mint)
            PatternDecodeView(
                data: bytes.data,
                baseAddress: bytes.address,
                sessionID: sessionID,
                engine: engine,
                placements: placements,
                memoryWriter: memoryWriter,
                onReread: rereadFromMenu
            )
            .fixedSize(horizontal: false, vertical: true)
            if liveTarget != nil {
                Button("Reread", systemImage: "arrow.clockwise", action: reread)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Reread from memory")
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var placements: Binding<[PatternPlacement]> {
        guard let storedValue, let address = bytes.address else { return $unstoredPlacements }
        return Binding(
            get: { storedPlacements.placed(at: address) },
            set: { engine.setPlacements($0, at: address, in: storedValue) }
        )
    }

    private var memoryWriter: ((_ bytes: [UInt8], _ address: UInt64) async throws -> Void)? {
        guard let target = liveTarget else { return nil }
        return { written, address in
            try await engine.writeMemory(written, at: address, forSessionID: sessionID, updating: target.stored)
        }
    }

    private var rereadFromMenu: (() -> Void)? {
        guard liveTarget != nil else { return nil }
        return { reread() }
    }

    private var liveTarget: (address: UInt64, stored: StoredValue)? {
        guard let address = bytes.address, let storedValue, engine.node(forSessionID: sessionID) != nil else { return nil }
        return (address, storedValue)
    }

    private func reread() {
        guard let target = liveTarget else { return }
        attempt { try await engine.rereadMemory(of: bytes, forSessionID: sessionID, updating: target.stored) }
    }

    private func attempt(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

extension View {
    func stored(_ value: StoredValue, placements: [PatternPlacement]) -> some View {
        environment(\.storedValue, value)
            .environment(\.storedPlacements, placements)
    }
}

extension EnvironmentValues {
    var storedValue: StoredValue? {
        get { self[StoredValueKey.self] }
        set { self[StoredValueKey.self] = newValue }
    }

    var storedPlacements: [PatternPlacement] {
        get { self[StoredPlacementsKey.self] }
        set { self[StoredPlacementsKey.self] = newValue }
    }
}

private struct StoredValueKey: EnvironmentKey {
    static let defaultValue: StoredValue? = nil
}

private struct StoredPlacementsKey: EnvironmentKey {
    static let defaultValue: [PatternPlacement] = []
}
