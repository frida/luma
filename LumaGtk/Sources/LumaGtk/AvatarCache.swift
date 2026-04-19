import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Gdk
import GdkPixBuf

@MainActor
final class AvatarCache {
    static let shared = AvatarCache()

    private var cache: [URL: Gdk.Texture] = [:]

    private init() {}

    func texture(for url: URL) async -> Gdk.Texture? {
        if let cached = cache[url] { return cached }

        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let data: Foundation.Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            data = body
        } catch {
            return nil
        }

        guard let pixbuf = IconPixbuf.makePixbuf(fromPNGData: data) else { return nil }
        let texture = Gdk.Texture(pixbuf: pixbuf)

        if let existing = cache[url] { return existing }
        cache[url] = texture
        return texture
    }
}
