import Combine
import Foundation

@MainActor
final class HookPackLibrary: ObservableObject {
    static let shared = HookPackLibrary()

    @Published private(set) var packs: [HookPack] = []

    private init() {}

    func reload() {
        packs = discoverPacks()
    }

    func pack(withId id: String) -> HookPack? {
        packs.first { $0.manifest.id == id }
    }

    private func discoverPacks() -> [HookPack] {
        let fm = FileManager.default
        guard
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent(Bundle.main.bundleIdentifier!, isDirectory: true)
                .appendingPathComponent("HookPacks", isDirectory: true)
        else {
            return []
        }

        guard
            let contents = try? fm.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var result: [HookPack] = []
        for url in contents {
            guard
                let rv = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                rv.isDirectory == true
            else {
                continue
            }

            let manifestURL = url.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else { continue }

            do {
                let manifest = try JSONDecoder().decode(HookPackManifest.self, from: data)
                result.append(HookPack(manifest: manifest, folderURL: url))
            } catch {
                print("Failed to decode hook-pack manifest at \(manifestURL): \(error)")
            }
        }

        return result
    }
}

struct HookPack {
    let manifest: HookPackManifest
    let folderURL: URL

    var entryURL: URL {
        folderURL.appendingPathComponent(manifest.entry)
    }
}
