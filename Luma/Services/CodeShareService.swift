import Combine
import Foundation

@MainActor
final class CodeShareService: ObservableObject {
    static let shared = CodeShareService()

    private let baseURL = URL(string: "https://codeshare.frida.re")!

    private init() {}

    struct ProjectSummary: Identifiable, Decodable, Hashable {
        let id: String
        let owner: String
        let slug: String
        let name: String
        let description: String
        let fridaVersion: String
        let likes: Int

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

    struct ProjectDetails: Decodable {
        let id: String
        let owner: String
        let slug: String
        let name: String
        let description: String
        let source: String
        let fridaVersion: String
        let likes: Int

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

    enum Mode {
        case popular
        case search(query: String)
    }

    func fetchPopular() async throws -> [ProjectSummary] {
        let url = baseURL.appendingPathComponent("api/projects/popular")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([ProjectSummary].self, from: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    func searchProjects(query: String) async throws -> [ProjectSummary] {
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

    func fetchProjectDetails(owner: String, slug: String) async throws -> ProjectDetails {
        let url = baseURL.appendingPathComponent("api/project/\(owner)/\(slug)")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(ProjectDetails.self, from: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}
