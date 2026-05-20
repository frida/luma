import Foundation

public struct SymbolDisplay: Sendable, Hashable {
    public struct Overlay: Sendable, Hashable {
        public let title: String
        public let offset: UInt64

        public init(title: String, offset: UInt64) {
            self.title = title
            self.offset = offset
        }
    }

    public let primary: String
    public let source: SymbolicateResult.SourceLocation?
    public let raw: SymbolicateResult?
    public let overlay: Overlay?

    public init(
        primary: String,
        source: SymbolicateResult.SourceLocation? = nil,
        raw: SymbolicateResult? = nil,
        overlay: Overlay? = nil
    ) {
        self.primary = primary
        self.source = source
        self.raw = raw
        self.overlay = overlay
    }

    public var displayString: String {
        guard let source else { return primary }
        let columnSuffix = source.column.map { ":\($0)" } ?? ""
        return "\(primary) — \(source.file):\(source.line)\(columnSuffix)"
    }
}
