import Foundation
@testable import LumaCore
import SwiftyPharo
import Observation

@MainActor
func silentPortal(port: Int) async throws {
    let connection = PortalConnection(deviceManager: .shared, address: "127.0.0.1:\(port)", certificate: nil)
    let started = Date()
    do {
        _ = try await connection.retain(token: "silent") { _ in }
        expect(false, "a connection to a server that never answers ends")
    } catch {
        let waited = Date().timeIntervalSince(started)
        expect(error.localizedDescription == "The lab's server did not answer." && waited >= 29 && waited < 40,
            String(format: "a connection to a server that never answers ends after %.1f s with: %@", waited, error.localizedDescription))
    }
}

@MainActor
func providerErrors() {
    let cases: [(Error, String)] = [
        (LLMProviderError.requestFailed(status: 503, message: #"{"error": {"type": "overloaded_error", "message": "The model is overloaded"}}"#),
            "The provider answered 503 (Service Unavailable): The model is overloaded."),
        (LLMProviderError.requestFailed(status: 429, message: #"{"error": "Rate limit reached."}"#),
            "The provider answered 429 (Too Many Requests): Rate limit reached."),
        (LLMProviderError.requestFailed(status: 502, message: "<html>\n<h1>Bad gateway</h1>\n</html>"),
            "The provider answered 502 (Bad Gateway)."),
        (LLMProviderError.requestFailed(status: 500, message: ""), "The provider answered 500 (Internal Server Error)."),
        (LLMProviderError.adapting(URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://api.example.com/v1")!])),
            "The provider at api.example.com did not answer in time."),
        (LLMProviderError.adapting(URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "http://localhost:11434/v1")!])),
            "The provider at localhost refused the connection."),
        (LLMProviderError.providerReported("Overloaded"), "The provider reported an error: Overloaded."),
    ]
    for (error, wanted) in cases {
        expect(error.localizedDescription == wanted, "a provider failure reads as a sentence: \(error.localizedDescription)")
    }
    let file = OfferedFile(id: UUID(), name: "#1.obj", mediaType: "model/obj", instrumentName: "Mesh Finder")
    let sentences = [LostOfferedFile(file: file, reason: "the host has gone").sentence, LostOfferedFile(file: file, reason: "Its buffers are gone.").sentence]
    expect(sentences == ["“#1.obj” was not saved: the host has gone.", "“#1.obj” was not saved: Its buffers are gone."],
        "a sentence built from an instrument's own text ends once: \(sentences)")
}

@MainActor
func stProbe(runtime: PharoRuntime, file: String) async throws {
    let original = try String(contentsOfFile: file, encoding: .utf8)
    let lines = original.components(separatedBy: "\n")
    let methodLine = lines.firstIndex { $0.hasPrefix("MeshView >> ") }!
    var syntax = lines
    syntax.insert("\t^ 1 + ", at: methodLine + 2)
    var unbalanced = lines
    unbalanced.removeLast(lines.last!.isEmpty ? 2 : 1)
    var undefined = lines
    undefined.insert("\tnoSuchVariable foo.", at: methodLine + 2)
    var header = lines
    header[1] = "\t#name : 'MeshView,"
    var stray = lines
    stray.insert("this is not a method", at: methodLine)
    var openBracket = lines
    openBracket.insert("\t[ 1 + 2.", at: methodLine + 2)
    var noBrace = lines
    noBrace.removeAll { $0 == "}" }
    for (label, variant) in [("syntax", syntax), ("unbalanced", unbalanced), ("undefined", undefined), ("header", header), ("stray", stray),
        ("openBracket", openBracket), ("noBrace", noBrace)] {
        let literal = "'" + variant.joined(separator: "\n").replacingOccurrences(of: "'", with: "''") + "'"
        let result = try await runtime.evaluate("""
            | code | code := LumaInstrumentCode new.
            code install: { Dictionary newFrom: { 'path' -> 'MeshView.class.st'. 'source' -> \(literal) } }.
            code printString
            """)
        let lined = !["undefined", "stray"].contains(label)
        let line = result.printString.firstMatch(of: /MeshView\.class\.st, line (\d+)/).map { Int($0.1)! }
        let pastHeader = label != "syntax" || (line ?? 0) > methodLine + 1
        expect((line != nil) == lined && pastHeader,
            "a broken view file's problem names \(lined ? "the line the compiler stopped at" : "what is wrong"): \(label): \(result.printString)")
    }
}
