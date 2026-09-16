import Foundation

public final class StageDurationMemory: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var learned: [String: TimeInterval]

    private static let fallbackDuration: TimeInterval = 2.5
    private static let smoothing = 0.4

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.learned = (try? JSONDecoder().decode([String: TimeInterval].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    public func expectedDuration(forKey key: String) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return learned[key] ?? Self.fallbackDuration
    }

    public func record(elapsed: TimeInterval, forKey key: String) {
        guard elapsed > 0, elapsed.isFinite else { return }

        lock.lock()
        let blended = learned[key].map { $0 + (elapsed - $0) * Self.smoothing } ?? elapsed
        learned[key] = blended
        let snapshot = learned
        lock.unlock()

        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
