import Foundation
@testable import LumaCore
import SwiftyPharo
import Observation

nonisolated(unsafe) var failures = 0

func note(_ message: String) {
    print(message)
    fflush(stdout)
}

func expect(_ condition: Bool, _ message: String) {
    if !condition { failures += 1 }
    note("\(condition ? "PASS" : "FAIL") \(message)")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

@MainActor
func waitFor(_ what: String, seconds: Double = 30, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    fail("timed out waiting for \(what)")
}

final class Flag: @unchecked Sendable {
    var value = false
}

@MainActor
func makeEngine(at projectDirectory: URL) async throws -> Engine {
    let traces = projectDirectory.appendingPathComponent("traces", isDirectory: true)
    try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
    let store = try ProjectStore(path: projectDirectory.appendingPathComponent("db.sqlite").path)
    let engine = Engine(
        store: store, blobs: try BlobStore(directory: traces), dataDirectory: projectDirectory.appendingPathComponent("data"))
    await engine.start()
    return engine
}

@MainActor
func toolResults(in request: LLMTurnRequest) -> [String] {
    request.messages.last?.blocks.compactMap { block -> String? in
        if case .toolResult(_, let json, _, _) = block.content { return json }
        return nil
    } ?? []
}

extension ObjectChats.Thread {
    var newestCall: ObjectChatToolCall? {
        toolCalls.max { ($0.createdAt, $0.index) < ($1.createdAt, $1.index) }
    }
}

var labTarget: URL {
    Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("LabTarget")
}
