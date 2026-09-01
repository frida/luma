import Foundation
import Frida
import Observation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Observable
@MainActor
public final class BareboneAgentLibrary {
    public private(set) var states: [BareboneAgentFlavor: BareboneAgentState] = [:]

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var version: String {
        fridaVersion
    }

    public func state(for flavor: BareboneAgentFlavor) -> BareboneAgentState {
        if let state = states[flavor] {
            return state
        }
        return (cachedPath(for: flavor) != nil) ? .ready : .missing
    }

    public func cachedPath(for flavor: BareboneAgentFlavor) -> URL? {
        let path = path(for: flavor)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return path
    }

    public func download(_ flavor: BareboneAgentFlavor, version: String = BareboneAgentLibrary.version) async throws -> URL {
        states[flavor] = .downloading

        do {
            let destination = path(for: flavor)
            let compressed = try await fetch(flavor, version: version)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XZArchive.decompress(compressed, to: destination)
            states[flavor] = .ready
            return destination
        } catch {
            states[flavor] = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    private func fetch(_ flavor: BareboneAgentFlavor, version: String) async throws -> Data {
        let url = URL(string: "https://github.com/frida/frida/releases/download/\(version)/\(flavor.assetName)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BareboneAgentError.downloadFailed(flavor: flavor, version: version)
        }
        return data
    }

    private func path(for flavor: BareboneAgentFlavor) -> URL {
        directory.appendingPathComponent("frida-barebone-agent-\(flavor.name)", isDirectory: false)
    }
}

public enum BareboneAgentState: Sendable, Equatable {
    case missing
    case downloading
    case ready
    case failed(reason: String)
}

public enum BareboneAgentError: Swift.Error, LocalizedError {
    case downloadFailed(flavor: BareboneAgentFlavor, version: String)
    case decompressionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let flavor, let version):
            return "No \(flavor.name) agent published for Frida \(version)"
        case .decompressionFailed(let reason):
            return "Unable to unpack the agent: \(reason)"
        }
    }
}
