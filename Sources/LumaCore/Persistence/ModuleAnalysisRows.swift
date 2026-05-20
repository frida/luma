import Foundation
import GRDB

struct ModuleAnalysisRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "module_analysis"

    var sessionID: UUID
    var modulePath: String
    var moduleUUID: String?
    var mappedRanges: Data
    var analyzedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case modulePath = "module_path"
        case moduleUUID = "module_uuid"
        case mappedRanges = "mapped_ranges"
        case analyzedAt = "analyzed_at"
    }
}

struct ModuleAnalysisFunctionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "module_analysis_function"

    var sessionID: UUID
    var modulePath: String
    var offset: Int64
    var name: String?
    var source: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case modulePath = "module_path"
        case offset
        case name
        case source
    }
}

struct ModuleAnalysisBlockRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "module_analysis_block"

    var sessionID: UUID
    var modulePath: String
    var functionOffset: Int64
    var offset: Int64
    var size: Int64

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case modulePath = "module_path"
        case functionOffset = "function_offset"
        case offset
        case size
    }
}

struct ModuleSymbolRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "module_symbol"

    var sessionID: UUID
    var modulePath: String
    var offset: Int64
    var name: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case modulePath = "module_path"
        case offset
        case name
    }
}
