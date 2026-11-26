import Foundation
import GRDB

public struct CustomInstrumentFile: Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "custom_instrument_file"

    public var defID: UUID
    public var path: String
    public var content: String

    public init(defID: UUID, path: String, content: String) {
        self.defID = defID
        self.path = path
        self.content = content
    }

    public init(row: Row) throws {
        defID = row["def_id"]
        path = row["path"]
        content = row["content"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["def_id"] = defID
        container["path"] = path
        container["content"] = content
    }

    public func toJSON() -> [String: Any] {
        ["path": path, "content": content]
    }

    public static func fromJSON(defID: UUID, _ obj: [String: Any]) -> CustomInstrumentFile? {
        guard let path = obj["path"] as? String,
            let content = obj["content"] as? String
        else { return nil }
        guard let validatedPath = try? validateRelativePath(path) else { return nil }
        return CustomInstrumentFile(defID: defID, path: validatedPath, content: content)
    }

    public static func sortedByPath(_ files: [CustomInstrumentFile], entrypoint: String) -> [CustomInstrumentFile] {
        files.sorted { lhs, rhs in
            if lhs.path == entrypoint { return true }
            if rhs.path == entrypoint { return false }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    public var patternKind: PatternSource.Kind? {
        PatternSource.Kind(path: path)
    }

    public static func workspaceRelativePath(defID: UUID, path: String) -> String {
        let encoded = path.replacingOccurrences(of: " ", with: "%20")
        return "InstrumentSources/Custom/\(defID.uuidString)/\(encoded)"
    }

    public static func validateRelativePath(_ rawPath: String) throws -> String {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw LumaCoreError.invalidArgument("File path must not be empty.")
        }
        guard path.utf8.count <= 512 else {
            throw LumaCoreError.invalidArgument("File path is too long.")
        }
        guard !path.hasPrefix("/"), !path.hasPrefix("\\") else {
            throw LumaCoreError.invalidArgument("File path must be relative.")
        }
        guard !path.contains("\\") else {
            throw LumaCoreError.invalidArgument("File path must use '/' separators.")
        }
        guard path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LumaCoreError.invalidArgument("File path contains a control character.")
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LumaCoreError.invalidArgument("File path must not contain '.', '..', or empty path segments.")
        }

        return path
    }
}

public struct CustomInstrumentBundle: Sendable, Equatable {
    public static let labMaxFiles = 256
    public static let labMaxFileBytes = 256 * 1024
    public static let labMaxTotalBytes = 8 * 1024 * 1024

    public var labRefusal: String? {
        if files.count > Self.labMaxFiles {
            return "“\(def.name)” has \(files.count) files; a lab takes at most \(Self.labMaxFiles)"
        }
        if let large = files.first(where: { $0.content.utf8.count > Self.labMaxFileBytes }) {
            let (size, cap) = Self.sizes(large.content.utf8.count, over: Self.labMaxFileBytes, unit: 1024, unitName: "KiB")
            return "“\(def.name)” has \(large.path) at \(size); a lab takes files of at most \(cap)"
        }
        let total = files.reduce(0) { $0 + $1.content.utf8.count }
        if total > Self.labMaxTotalBytes {
            let (size, cap) = Self.sizes(total, over: Self.labMaxTotalBytes, unit: 1024 * 1024, unitName: "MiB")
            return "“\(def.name)” has \(size) of files; a lab takes at most \(cap)"
        }
        return nil
    }

    private static func sizes(_ bytes: Int, over cap: Int, unit: Int, unitName: String) -> (size: String, cap: String) {
        let tenths = (bytes * 10 + unit - 1) / unit
        let capUnits = cap / unit
        if tenths <= capUnits * 10 {
            return ("\(bytes) bytes", "\(cap) bytes (\(capUnits) \(unitName))")
        }
        return (String(format: "%.1f \(unitName)", Double(tenths) / 10), "\(capUnits) \(unitName)")
    }

    public var def: CustomInstrumentDef
    public var files: [CustomInstrumentFile]

    public init(def: CustomInstrumentDef, files: [CustomInstrumentFile]) {
        self.def = def
        self.files = files
    }

    public func toJSON() -> [String: Any] {
        var obj = def.toJSON()
        obj["files"] = files.map { $0.toJSON() }
        return obj
    }

    public static func fromJSON(_ obj: [String: Any]) -> CustomInstrumentBundle? {
        guard let def = CustomInstrumentDef.fromJSON(obj) else { return nil }
        let filesArr = (obj["files"] as? [[String: Any]]) ?? []
        let files = filesArr.compactMap { CustomInstrumentFile.fromJSON(defID: def.id, $0) }
        return CustomInstrumentBundle(def: def, files: files)
    }
}
