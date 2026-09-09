import Foundation

public struct ModuleFunction: Sendable, Hashable {
    public let offset: UInt64
    public let name: String
    public let source: ModuleAnalysis.Function.Source

    public init(offset: UInt64, name: String, source: ModuleAnalysis.Function.Source) {
        self.offset = offset
        self.name = name
        self.source = source
    }

    static func fromJSON(_ dict: [String: Any]) -> ModuleFunction? {
        guard let offset = dict["offset"] as? NSNumber,
              let name = dict["name"] as? String,
              let source = dict["source"] as? String,
              let kind = ModuleAnalysis.Function.Source(rawValue: source)
        else {
            return nil
        }
        return ModuleFunction(offset: offset.uint64Value, name: name, source: kind)
    }
}
