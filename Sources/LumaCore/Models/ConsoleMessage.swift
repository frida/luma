import Foundation

public struct ConsoleMessage: CustomStringConvertible, Codable, Sendable {
    public let level: ConsoleLevel
    public let values: [JSInspectValue]

    public init(level: ConsoleLevel, values: [JSInspectValue]) {
        self.level = level
        self.values = values
    }

    public var line: String? {
        guard !values.isEmpty else { return nil }
        var words: [String] = []
        for value in values {
            switch value {
            case .string(let text):
                words.append(text)
            case .number, .boolean, .null, .undefined, .bigInt, .symbol:
                words.append(value.inlineDescription)
            default:
                return nil
            }
        }
        return words.joined(separator: " ")
    }

    public var description: String {
        let body =
            values
            .map { String(describing: $0) }
            .joined(separator: " ")
        return "[\(level.rawValue)] \(body)"
    }
}
