import LumaCore
import SwiftUI

struct InspectedBytesView: View {
    let bytes: JSInspectValue.Bytes
    let sessionID: UUID
    let engine: Engine

    @Environment(\.storedValue) private var storedValue
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bytes(\(bytes.kind.rawValue)[\(bytes.data.count)])")
                .foregroundStyle(.mint)
            HexView(data: bytes.data, baseAddress: bytes.address ?? 0, onWrite: hexWriter) {
                if liveTarget != nil {
                    Button("Reread", action: reread)
                }
            }
            if liveTarget != nil {
                HStack(spacing: 8) {
                    HexEditingCaption()
                    Button("Reread", systemImage: "arrow.clockwise", action: reread)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Reread from memory")
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var liveTarget: (address: UInt64, stored: StoredValue)? {
        guard let address = bytes.address, let storedValue, engine.node(forSessionID: sessionID) != nil else { return nil }
        return (address, storedValue)
    }

    private var hexWriter: ((Int, [UInt8]) -> Void)? {
        guard let target = liveTarget else { return nil }
        return { offset, bytes in write(bytes, at: target.address &+ UInt64(offset), updating: target.stored) }
    }

    private func write(_ bytes: [UInt8], at address: UInt64, updating stored: StoredValue) {
        attempt { try await engine.writeMemory(bytes, at: address, forSessionID: sessionID, updating: stored) }
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

extension EnvironmentValues {
    var storedValue: StoredValue? {
        get { self[StoredValueKey.self] }
        set { self[StoredValueKey.self] = newValue }
    }
}

private struct StoredValueKey: EnvironmentKey {
    static let defaultValue: StoredValue? = nil
}
