import Foundation

public struct ConsoleMessage: CustomStringConvertible {
    public let level: ConsoleLevel
    public let values: [JSInspectValue]

    public init(level: ConsoleLevel, values: [JSInspectValue]) {
        self.level = level
        self.values = values
    }

    public var description: String {
        let body =
            values
            .map { String(describing: $0) }
            .joined(separator: " ")
        return "[\(level.rawValue)] \(body)"
    }
}
