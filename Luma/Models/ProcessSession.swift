import Foundation
import Frida
import SwiftData

@Model
final class ProcessSession {
    var id = UUID()

    @Attribute(.externalStorage)
    private var kindBlob: Data!

    var kind: Kind {
        get {
            try! JSONDecoder().decode(Kind.self, from: kindBlob)
        }
        set {
            kindBlob = try! JSONEncoder().encode(newValue)
        }
    }

    var deviceID: String
    var deviceName: String
    var processName: String
    @Attribute(.externalStorage)
    var iconPNGData: Data?

    var phase: Phase
    var detachReason: SessionDetachReason
    var lastError: Error?

    var createdAt: Date
    var lastKnownPID: UInt
    var lastAttachedAt: Date?

    @Relationship(deleteRule: .cascade)
    var replCells: [REPLCell] = []

    var orderedReplCells: [REPLCell] {
        replCells.sorted { $0.timestamp < $1.timestamp }
    }

    @Relationship(deleteRule: .cascade)
    var instruments: [InstrumentInstance] = []

    @Relationship(deleteRule: .cascade)
    var insights: [AddressInsight] = []

    enum Kind: Codable {
        case spawn(SpawnConfig)
        case attach

        var verbDisplayName: String {
            switch self {
            case .spawn: return "spawn"
            case .attach: return "attach"
            }
        }

        var reestablishLabel: String {
            switch self {
            case .spawn: return "Re-Spawn"
            case .attach: return "Re-Attach"
            }
        }

        var inProgressLabel: String {
            switch self {
            case .spawn: return "Spawning…"
            case .attach: return "Attaching…"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case config
        }

        private enum KindTag: String, Codable {
            case spawn
            case attach
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .spawn(let config):
                try container.encode(KindTag.spawn, forKey: .kind)
                try container.encode(config, forKey: .config)
            case .attach:
                try container.encode(KindTag.attach, forKey: .kind)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(KindTag.self, forKey: .kind)

            switch tag {
            case .spawn:
                let config = try container.decode(SpawnConfig.self, forKey: .config)
                self = .spawn(config)
            case .attach:
                self = .attach
            }
        }
    }

    enum Phase: Int, Codable {
        case idle
        case attaching
        case awaitingInitialResume
        case attached
    }

    init(
        kind: Kind,
        deviceID: String,
        deviceName: String,
        processName: String,
        lastKnownPID: UInt
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.processName = processName

        self.phase = .idle
        self.detachReason = .applicationRequested

        self.createdAt = Date()
        self.lastKnownPID = lastKnownPID

        self.kind = kind
    }
}
