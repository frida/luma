import Foundation

public enum PackageCategory: String, CaseIterable, Identifiable, Sendable {
    case any
    case bridge
    case pattern

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any:
            return "All"
        case .bridge:
            return "Bridges"
        case .pattern:
            return "Patterns"
        }
    }

    public var keyword: String? {
        switch self {
        case .any:
            return nil
        case .bridge:
            return "frida-gum-bridge"
        case .pattern:
            return PatternLibrary.packageKeyword
        }
    }

    public func searchText(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch keyword {
        case nil:
            return trimmed.isEmpty ? nil : trimmed
        case let keyword?:
            return trimmed.isEmpty ? "keywords:\(keyword)" : "\(trimmed) keywords:\(keyword)"
        }
    }
}
