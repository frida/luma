import Foundation

public struct JSError: CustomStringConvertible, Sendable {
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
