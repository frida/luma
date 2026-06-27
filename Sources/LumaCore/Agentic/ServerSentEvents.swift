import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ServerSentEventStream {
    let http: HTTPURLResponse
    let lines: AsyncThrowingStream<String, Error>
}

func openServerSentEventStream(session: URLSession, request: URLRequest) async throws -> ServerSentEventStream {
    #if canImport(FoundationNetworking)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw LumaCoreError.protocolViolation("Server sent an invalid HTTP response.")
    }
    let body = String(decoding: data, as: UTF8.self)
    let lines = AsyncThrowingStream<String, Error> { continuation in
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            continuation.yield(String(line))
        }
        continuation.finish()
    }
    return ServerSentEventStream(http: http, lines: lines)
    #else
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw LumaCoreError.protocolViolation("Server sent an invalid HTTP response.")
    }
    let lines = AsyncThrowingStream<String, Error> { continuation in
        let task = Task {
            do {
                for try await line in bytes.lines {
                    continuation.yield(line)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
    return ServerSentEventStream(http: http, lines: lines)
    #endif
}
