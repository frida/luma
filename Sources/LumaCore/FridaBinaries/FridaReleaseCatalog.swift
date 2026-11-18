import Foundation
import Observation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Observable
@MainActor
public final class FridaReleaseCatalog {
    public private(set) var releases: [FridaRelease] = []

    @ObservationIgnored private var inflightRefresh: Task<Void, Never>?

    public init() {}

    public func refresh() async {
        if let inflightRefresh {
            return await inflightRefresh.value
        }
        let refresh = Task {
            releases = (try? await Self.fetchReleases()) ?? []
        }
        inflightRefresh = refresh
        defer { inflightRefresh = nil }
        await refresh.value
    }

    func loadIfNeeded() async {
        if releases.isEmpty {
            await refresh()
        }
    }

    func latestVersion(offering assetName: (String) -> String) -> String? {
        releases
            .filter { $0.assets.contains(assetName($0.version)) }
            .map(\.version)
            .max(by: Self.precedes)
    }

    private static func fetchReleases() async throws -> [FridaRelease] {
        let url = URL(string: "https://api.github.com/repos/frida/frida/releases?per_page=10")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([Release].self, from: data).map { release in
            FridaRelease(version: release.tagName, assets: Set(release.assets.map(\.name)))
        }
    }

    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
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

public struct FridaRelease: Sendable, Equatable {
    public let version: String
    public let assets: Set<String>
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
