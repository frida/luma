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
    public private(set) var fetchedVersions: [BareboneAgentFlavor: String] = [:]
    public private(set) var releases: [BareboneAgentRelease] = []

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func state(for flavor: BareboneAgentFlavor) -> BareboneAgentState {
        if let state = states[flavor] {
            return state
        }
        return (cachedPath(for: flavor) != nil) ? .ready : .missing
    }

    public func fetchedVersion(for flavor: BareboneAgentFlavor) -> String? {
        fetchedVersions[flavor]
    }

    public func availableVersions(for flavor: BareboneAgentFlavor) -> [String] {
        releases
            .filter { $0.assets.contains(flavor.assetName) }
            .map(\.version)
            .sorted { Self.precedes($1, $0) }
    }

    public func latestVersion(for flavor: BareboneAgentFlavor) -> String? {
        availableVersions(for: flavor).first
    }

    public func update(for flavor: BareboneAgentFlavor) -> BareboneAgentUpdate {
        guard let latest = latestVersion(for: flavor) else { return .unknown }
        guard let fetched = fetchedVersion(for: flavor) else { return .available(version: latest) }
        return fetched == latest ? .upToDate(version: fetched) : .available(version: latest)
    }

    public func cachedPath(for flavor: BareboneAgentFlavor) -> URL? {
        let path = path(for: flavor)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return path
    }

    @discardableResult
    public func download(_ flavor: BareboneAgentFlavor, version: String) async throws -> URL {
        states[flavor] = .downloading(fraction: nil)

        do {
            let destination = path(for: flavor)
            let compressed = try await fetch(flavor, version: version)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XZArchive.decompress(compressed, to: destination)
            fetchedVersions[flavor] = await Self.embeddedVersion(in: destination)
            states[flavor] = .ready
            return destination
        } catch {
            states[flavor] = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    public func downloadLatest(_ flavor: BareboneAgentFlavor) async throws -> URL {
        if releases.isEmpty {
            await refreshReleases()
        }
        guard let version = latestVersion(for: flavor) else {
            throw BareboneAgentError.noneAvailable(flavor: flavor)
        }
        return try await download(flavor, version: version)
    }

    public func loadFetchedVersion(for flavor: BareboneAgentFlavor) async {
        guard let path = cachedPath(for: flavor) else {
            fetchedVersions[flavor] = nil
            return
        }
        fetchedVersions[flavor] = await Self.embeddedVersion(in: path)
    }

    public func refreshReleases() async {
        releases = (try? await Self.fetchReleases()) ?? []
    }

    private func fetch(_ flavor: BareboneAgentFlavor, version: String) async throws -> Data {
        let url = URL(string: "https://github.com/frida/frida/releases/download/\(version)/\(flavor.assetName)")!
        do {
            let downloaded = try await ProgressiveDownload.fetch(url) { [weak self] fraction in
                Task { @MainActor in
                    self?.states[flavor] = .downloading(fraction: fraction)
                }
            }
            defer { try? FileManager.default.removeItem(at: downloaded) }
            return try Data(contentsOf: downloaded)
        } catch {
            throw BareboneAgentError.downloadFailed(flavor: flavor, version: version)
        }
    }

    private func path(for flavor: BareboneAgentFlavor) -> URL {
        directory.appendingPathComponent("frida-barebone-agent-\(flavor.name)", isDirectory: false)
    }

    private static func embeddedVersion(in url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let blob = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let opening = Data(#"{"type":"frida""#.utf8)
            guard let start = blob.range(of: opening) else { return nil }
            guard let close = blob.range(of: Data("}".utf8), in: start.upperBound..<blob.endIndex) else { return nil }
            let note = Data(blob[start.lowerBound..<close.upperBound])
            return try? JSONDecoder().decode(AgentNote.self, from: note).version
        }.value
    }

    private static func fetchReleases() async throws -> [BareboneAgentRelease] {
        let url = URL(string: "https://api.github.com/repos/frida/frida/releases?per_page=10")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([Release].self, from: data).map { release in
            BareboneAgentRelease(version: release.tagName, assets: Set(release.assets.map(\.name)))
        }
    }

    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = numbers(in: lhs)
        let right = numbers(in: rhs)
        for (a, b) in zip(left, right) where a != b {
            return a < b
        }
        return left.count < right.count
    }

    private static func numbers(in tag: String) -> [Int] {
        tag.split { !$0.isNumber }.compactMap { Int($0) }
    }
}

public struct BareboneAgentRelease: Sendable, Equatable {
    public let version: String
    public let assets: Set<String>
}

public enum BareboneAgentUpdate: Sendable, Equatable {
    case unknown
    case upToDate(version: String)
    case available(version: String)
}

public enum BareboneAgentState: Sendable, Equatable {
    case missing
    case downloading(fraction: Double?)
    case ready
    case failed(reason: String)

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

public enum BareboneAgentError: Swift.Error, LocalizedError {
    case noneAvailable(flavor: BareboneAgentFlavor)
    case downloadFailed(flavor: BareboneAgentFlavor, version: String)
    case decompressionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noneAvailable(let flavor):
            return "No published \(flavor.name) agent found"
        case .downloadFailed(let flavor, let version):
            return "No \(flavor.name) agent published for Frida \(version)"
        case .decompressionFailed(let reason):
            return "Unable to unpack the agent: \(reason)"
        }
    }
}

private struct AgentNote: Decodable {
    let version: String
}

private struct Release: Decodable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}
