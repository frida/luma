import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodeShareService {
    private static let baseURL = URL(string: "https://codeshare.frida.re")!

    public enum Mode: Sendable {
        case popular
        case search(query: String)
    }

    public struct ProjectSummary: Identifiable, Decodable, Hashable, Sendable {
        public let id: String
        public let owner: String
        public let slug: String
        public let name: String
        public let description: String
        public let fridaVersion: String
        public let likes: Int

        enum CodingKeys: String, CodingKey {
            case id
            case owner
            case slug
            case name = "project_name"
            case description
            case fridaVersion = "frida_version"
            case likes
        }
    }

    public struct ProjectDetails: Decodable, Sendable {
        public let id: String
        public let owner: String
        public let slug: String
        public let name: String
        public let description: String
        public let source: String
        public let fridaVersion: String
        public let likes: Int

        enum CodingKeys: String, CodingKey {
            case id
            case owner
            case slug
            case name = "project_name"
            case description
            case source
            case fridaVersion = "frida_version"
            case likes
        }
    }

    public static func fetchPopular() async throws -> [ProjectSummary] {
        let url = baseURL.appendingPathComponent("api/projects/popular")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([ProjectSummary].self, from: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    public static func searchProjects(query: String) async throws -> [ProjectSummary] {
        guard !query.isEmpty else { return [] }
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("api/projects/search"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "query", value: query)]
        do {
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            return try JSONDecoder().decode([ProjectSummary].self, from: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    public static func fetchProjectDetails(owner: String, slug: String) async throws -> ProjectDetails {
        let url = baseURL.appendingPathComponent("api/project/\(owner)/\(slug)")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(ProjectDetails.self, from: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}
