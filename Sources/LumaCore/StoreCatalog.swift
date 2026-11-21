import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct StoreCatalog: Sendable {
    let baseURL: URL

    func page(
        matching query: String,
        in category: StoreCategory.ID?,
        for device: SystemParameters?,
        offset: Int,
        limit: Int
    ) async throws -> StoreCatalogPage {
        var parameters: [(name: String, value: String)] = [("offset", String(offset)), ("limit", String(limit))]
        if !query.isEmpty {
            parameters.append(("query", query))
        }
        if let category {
            parameters.append(("category", category))
        }
        if let device {
            parameters += [("platform", device.platform), ("os", device.osID), ("arch", device.arch)]
        }
        let reply = try await fetchJSON(itemsURL.withQuery(Self.encodedQuery(parameters)))
        guard let entries = reply["items"] as? [JSONObject], let total = reply["total"] as? Int else {
            throw StorefrontError.malformedReply
        }
        let nextOffset = offset + entries.count
        return StoreCatalogPage(
            items: entries.compactMap(StoreItem.fromWireJSON),
            total: total,
            nextOffset: nextOffset,
            hasMore: !entries.isEmpty && nextOffset < total
        )
    }

    func items(withIDs ids: [StoreItem.ID]) async throws -> [StoreItem] {
        let idList = ids.map(Self.percentEncoded).joined(separator: ",")
        let reply = try await fetchJSON(itemsURL.withQuery("ids=\(idList)"))
        guard let entries = reply["items"] as? [JSONObject] else { throw StorefrontError.malformedReply }
        return entries.compactMap(StoreItem.fromWireJSON)
    }

    func categories() async throws -> [StoreCategory] {
        guard let entries = try await fetchJSON(baseURL.appendingPathComponent("categories"))["categories"] as? [JSONObject] else {
            throw StorefrontError.malformedReply
        }
        return entries.compactMap(StoreCategory.fromWireJSON)
    }

    func detail(of item: StoreItem) async throws -> StoreItemDetail {
        guard let detail = StoreItemDetail.fromWireJSON(try await fetchJSON(url(of: item))) else { throw StorefrontError.malformedReply }
        return detail
    }

    func iconPixels(of item: StoreItem) async throws -> Data {
        let iconURL = url(of: item).appendingPathComponent("icon")
        return try await fetch(iconURL.withQuery(Self.encodedQuery([("v", item.version.description)])))
    }

    private var itemsURL: URL {
        baseURL.appendingPathComponent("items")
    }

    private func url(of item: StoreItem) -> URL {
        itemsURL.appendingPathComponent(item.publisher.handle).appendingPathComponent(item.slug)
    }

    private static func encodedQuery(_ parameters: [(name: String, value: String)]) -> String {
        parameters.map { "\($0.name)=\(percentEncoded($0.value))" }.joined(separator: "&")
    }

    private static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters)!
    }

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private func fetchJSON(_ url: URL) async throws -> JSONObject {
        let data = try await fetch(url)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw StorefrontError.malformedReply
        }
        return body
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await download(url)
        let status = (response as! HTTPURLResponse).statusCode
        guard status == 200 else { throw failure(status: status, body: try? JSONSerialization.jsonObject(with: data) as? JSONObject) }
        return data
    }

    private func download(_ url: URL) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(from: url)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private func failure(status: Int, body: JSONObject?) -> StorefrontError {
        guard let error = body?["error"] as? JSONObject,
            let code = error["code"] as? String,
            let message = error["message"] as? String
        else { return .server(message: "The store answered with HTTP status \(status).") }
        return StorefrontError(code: code, message: message)
    }
}

struct StoreCatalogPage: Sendable {
    let items: [StoreItem]
    let total: Int
    let nextOffset: Int
    let hasMore: Bool
}

extension URL {
    fileprivate func withQuery(_ percentEncodedQuery: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = percentEncodedQuery
        return components.url!
    }
}
