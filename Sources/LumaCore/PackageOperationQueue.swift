@MainActor
public final class PackageOperationQueue {
    private var pending: [() async throws -> Void] = []
    private var isRunning = false

    public init() {}

    public func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending.append {
                do {
                    try await operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if !isRunning {
                Task { [self] in
                    try await runNext()
                }
            }
        }
    }

    private func runNext() async throws {
        guard !pending.isEmpty else {
            isRunning = false
            return
        }

        isRunning = true
        let op = pending.removeFirst()

        do {
            try await op()
            try await runNext()
        } catch {
            isRunning = false
            pending.removeAll()
            throw error
        }
    }
}
