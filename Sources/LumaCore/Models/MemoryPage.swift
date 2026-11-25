import Foundation
import GRDB

public enum MemoryPage {
    public static let size: UInt64 = 0x1000
    public static let mask: UInt64 = size &- 1

    public static func base(of address: UInt64) -> UInt64 {
        address & ~mask
    }
}

public enum MemoryPageRegion: Sendable, Hashable {
    case module(uuid: String, offset: UInt64)
    case anonymous(identity: String, address: UInt64)
}

public struct MemoryPagePublish: Sendable {
    public let region: MemoryPageRegion
    public let bytes: Data
    public let capturedAt: Date

    public init(region: MemoryPageRegion, bytes: Data, capturedAt: Date = Date()) {
        self.region = region
        self.bytes = bytes
        self.capturedAt = capturedAt
    }
}

public struct MemoryPageModule: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "memory_page_module"

    public var sessionID: UUID
    public var moduleUUID: String
    public var offset: UInt64
    public var bytes: Data
    public var capturedAt: Date

    public init(sessionID: UUID, moduleUUID: String, offset: UInt64, bytes: Data, capturedAt: Date = Date()) {
        self.sessionID = sessionID
        self.moduleUUID = moduleUUID
        self.offset = offset
        self.bytes = bytes
        self.capturedAt = capturedAt
    }

    public func encode(to container: inout PersistenceContainer) {
        container["session_id"] = sessionID
        container["module_uuid"] = moduleUUID
        container["offset"] = Int64(bitPattern: offset)
        container["bytes"] = bytes
        container["captured_at"] = capturedAt
    }

    public init(row: Row) throws {
        sessionID = row["session_id"]
        moduleUUID = row["module_uuid"]
        let raw: Int64 = row["offset"]
        offset = UInt64(bitPattern: raw)
        bytes = row["bytes"]
        capturedAt = row["captured_at"]
    }
}

public struct MemoryPageAnon: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "memory_page_anon"

    public var sessionID: UUID
    public var processIdentity: String
    public var address: UInt64
    public var bytes: Data
    public var capturedAt: Date

    public init(sessionID: UUID, processIdentity: String, address: UInt64, bytes: Data, capturedAt: Date = Date()) {
        self.sessionID = sessionID
        self.processIdentity = processIdentity
        self.address = address
        self.bytes = bytes
        self.capturedAt = capturedAt
    }

    public func encode(to container: inout PersistenceContainer) {
        container["session_id"] = sessionID
        container["process_identity"] = processIdentity
        container["address"] = Int64(bitPattern: address)
        container["bytes"] = bytes
        container["captured_at"] = capturedAt
    }

    public init(row: Row) throws {
        sessionID = row["session_id"]
        processIdentity = row["process_identity"]
        let raw: Int64 = row["address"]
        address = UInt64(bitPattern: raw)
        bytes = row["bytes"]
        capturedAt = row["captured_at"]
    }
}
