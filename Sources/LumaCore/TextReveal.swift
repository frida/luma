import Foundation

public struct TextReveal: Sendable, Equatable {
    public static let repl = Allowance(lines: .max, characters: 4096)
    public static let event = Allowance(lines: 12, characters: 2048)

    public struct Allowance: Sendable, Equatable {
        public let lines: Int
        public let characters: Int
    }

    public let total: Int
    public private(set) var revealed: Int

    private let text: [Character]
    private let allowance: Allowance

    public init(_ text: String, allowance: Allowance) {
        self.text = Array(text)
        self.allowance = allowance
        total = self.text.count
        revealed = 0
        revealed = end(ofChunkFrom: 0)
    }

    public var isComplete: Bool { revealed == total }

    public mutating func revealMore() {
        revealed = end(ofChunkFrom: revealed)
    }

    public mutating func revealAll() {
        revealed = total
    }

    private func end(ofChunkFrom start: Int) -> Int {
        let limit = min(total, start + allowance.characters)
        var lines = 0
        var index = start
        while index < limit {
            if text[index] == "\n" && index > start {
                lines += 1
                if lines == allowance.lines { return index }
            }
            index += 1
        }
        return limit
    }
}
