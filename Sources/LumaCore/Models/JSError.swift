import Foundation

public struct JSError: CustomStringConvertible, Codable, Sendable {
    public let text: String

    public let fileName: String?
    public let lineNumber: Int?
    public let columnNumber: Int?

    public let stack: String?

    public init(text: String, fileName: String? = nil, lineNumber: Int? = nil, columnNumber: Int? = nil, stack: String? = nil) {
        self.text = text
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
        self.stack = stack
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case fileName = "file_name"
        case lineNumber = "line_number"
        case columnNumber = "column_number"
        case stack
    }

    public init(from decoder: Decoder) throws {
        try decoder.requireKnownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        lineNumber = try c.decodeIfPresent(Int.self, forKey: .lineNumber)
        columnNumber = try c.decodeIfPresent(Int.self, forKey: .columnNumber)
        stack = try c.decodeIfPresent(String.self, forKey: .stack)
    }

    public var description: String {
        var base = text
        if let fileName, let lineNumber {
            base += " (\(fileName):\(lineNumber)"
            if let columnNumber {
                base += ":\(columnNumber)"
            }
            base += ")"
        }
        if let stack, !stack.isEmpty {
            base += "\n" + stack
        }
        return base
    }
}
