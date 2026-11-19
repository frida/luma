public enum ConsoleLevel: String, Codable, Sendable, CaseIterable {
    case info
    case debug
    case warning
    case error

    public var badge: String {
        switch self {
        case .info: return "INFO"
        case .debug: return "DEBUG"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}
