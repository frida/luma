import Foundation

/// What a stored blob holds, so one file store keeps trace captures beside a
/// Pharo result's Fuel and its snapshot rather than a store per kind.
public enum BlobKind: String, Sendable, Codable, CaseIterable {
    case trace
    case pharoFuel = "pharo_fuel"
    case pharoSnapshot = "pharo_snapshot"
}

/// A file-backed blob store keyed by id and kind. The three-tier load in
/// `Engine` -- live pending, this store, then a paginated fetch -- reads
/// through it.
public final class BlobStore: Sendable {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, id: UUID, kind: BlobKind) throws {
        try data.write(to: url(id: id, kind: kind), options: .atomic)
    }

    public func load(id: UUID, kind: BlobKind) throws -> Data {
        try Data(contentsOf: url(id: id, kind: kind), options: .mappedIfSafe)
    }

    public func exists(id: UUID, kind: BlobKind) -> Bool {
        FileManager.default.fileExists(atPath: url(id: id, kind: kind).path)
    }

    public func size(id: UUID, kind: BlobKind) -> Int? {
        let path = url(id: id, kind: kind).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.size] as? Int
    }

    public func delete(id: UUID, kind: BlobKind) {
        try? FileManager.default.removeItem(at: url(id: id, kind: kind))
    }

    public func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A trace keeps its bare-id name so captures written before the store was
    /// generalized still load; the other kinds tag the file so they sit beside
    /// it without colliding.
    private func url(id: UUID, kind: BlobKind) -> URL {
        switch kind {
        case .trace:
            return directory.appendingPathComponent("\(id.uuidString).bin")
        default:
            return directory.appendingPathComponent("\(id.uuidString).\(kind.rawValue).bin")
        }
    }
}
