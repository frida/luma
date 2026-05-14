import Foundation

public struct SymbolicateResult: Hashable, Sendable {
    public let module: String
    public let name: String
    public let offset: UInt64?
    public let source: SourceLocation?

    public struct SourceLocation: Hashable, Sendable {
        public let file: String
        public let line: Int
        public let column: Int?

        public init(file: String, line: Int, column: Int? = nil) {
            self.file = file
            self.line = line
            self.column = column
        }
    }

    public init(module: String, name: String, offset: UInt64? = nil, source: SourceLocation? = nil) {
        self.module = module
        self.name = name
        self.offset = offset
        self.source = source
    }

    public var qualifiedName: String {
        let base = "\(module)!\(name)"
        return offset.map { "\(base)+0x\(String($0, radix: 16))" } ?? base
    }

    public var displayString: String {
        guard let source else { return qualifiedName }
        let columnSuffix = source.column.map { ":\($0)" } ?? ""
        return "\(qualifiedName) — \(source.file):\(source.line)\(columnSuffix)"
    }
}
