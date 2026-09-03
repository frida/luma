import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ProgressiveDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static func fetch(
        _ url: URL,
        reporting report: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let delegate = ProgressiveDownload(report: report)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    private let report: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<URL, any Error>?
    private var lastReported: Double = 0

    private init(report: @escaping @Sendable (Double?) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            report(nil)
            return
        }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard fraction - lastReported >= 0.01 || fraction == 1 else { return }
        lastReported = fraction
        report(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let result: Result<URL, any Error>
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            result = .failure(URLError(.fileDoesNotExist))
        } else {
            let kept = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
            result = Result { try FileManager.default.moveItem(at: location, to: kept) }
                .map { kept }
        }
        continuation?.resume(with: result)
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
