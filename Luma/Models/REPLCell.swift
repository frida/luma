import Foundation
import SwiftData

@Model
class REPLCell {
    var id = UUID()
    var code: String
    @Attribute(.externalStorage)
    private var resultData: Data
    var timestamp: Date
    var isSessionBoundary: Bool

    var result: Result {
        get {
            return try! JSONDecoder().decode(Result.self, from: resultData)
        }
        set {
            resultData = try! JSONEncoder().encode(newValue)
        }
    }

    var session: ProcessSession?

    init(
        code: String,
        result: Result,
        timestamp: Date,
        isSessionBoundary: Bool = false,
    ) {
        self.code = code
        self.resultData = try! JSONEncoder().encode(result)
        self.timestamp = timestamp
        self.isSessionBoundary = isSessionBoundary
    }

    enum Result: Codable, Equatable {
        case text(String)
        case js(JSInspectValue)
        case binary(Data, meta: BinaryMeta?)

        struct BinaryMeta: Codable, Equatable {
            let typedArray: String?
        }
    }
}
