import Foundation
import Frida

public struct ProcessSession: Codable, Identifiable, Sendable {
    public var id: UUID
    public var kind: Kind
    public var deviceID: String
    public var deviceName: String
    public var processName: String
    public var iconPNGData: Data?

    public var phase: Phase
    public var detachReason: SessionDetachReason
    public var lastError: String?

    public var createdAt: Date
    public var lastKnownPID: UInt
    public var lastAttachedAt: Date?

    public var processInfo: ProcessInfo?
    public var lastKnownModules: [PersistedModule]?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        deviceID: String,
        deviceName: String,
        processName: String,
        lastKnownPID: UInt
    ) {
        self.id = id
        self.kind = kind
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.processName = processName
        self.phase = .idle
        self.detachReason = .applicationRequested
        self.createdAt = Date()
        self.lastKnownPID = lastKnownPID
    }

    public struct PersistedModule: Codable, Sendable {
        public let name: String
        public let base: UInt64
        public let size: UInt64

        public init(name: String, base: UInt64, size: UInt64) {
            self.name = name
            self.base = base
            self.size = size
        }
    }

    public struct ProcessInfo: Codable, Sendable {
        public let platform: String
        public let arch: String
        public let pointerSize: Int

        public init(platform: String, arch: String, pointerSize: Int) {
            self.platform = platform
            self.arch = arch
            self.pointerSize = pointerSize
        }
    }

    public enum Kind: Codable, Sendable {
        case spawn(SpawnConfig)
        case attach

        public var verbDisplayName: String {
            switch self {
            case .spawn: return "spawn"
            case .attach: return "attach"
            }
        }

        public var reestablishLabel: String {
            switch self {
            case .spawn: return "Re-Spawn"
            case .attach: return "Re-Attach"
            }
        }

        public var inProgressLabel: String {
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

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .spawn(let config):
                try container.encode(KindTag.spawn, forKey: .kind)
                try container.encode(config, forKey: .config)
            case .attach:
                try container.encode(KindTag.attach, forKey: .kind)
            }
        }

        public init(from decoder: Decoder) throws {
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

    public enum Phase: Int, Codable, Sendable {
        case idle
        case attaching
        case awaitingInitialResume
        case attached
    }
}
