import Foundation
import LumaCore

let arguments = Array(CommandLine.arguments.dropFirst())
let isDryRun = arguments.contains("--dry-run")
guard let planPath = arguments.first(where: { !$0.hasPrefix("--") }) else {
    fail("usage: LumaPublish [--dry-run] <plan.json>, where the plan is [{ \"folder\": ..., \"notes\": ... }]")
}

let plan = try readPlan(at: planPath)
let engine = try makeEngine()
await engine.gitHubAuth.loadPersistedToken()
guard engine.gitHubAuth.token != nil else {
    fail("not signed in: sign in to the store in Luma, or set LUMA_GITHUB_TOKEN")
}

var failures = 0
for release in plan {
    let outcome = await publish(release, dryRun: isDryRun, through: engine.storefront)
    if case .failed = outcome {
        failures += 1
    }
    print("\(release.folderName): \(outcome.text)")
}
exit(failures == 0 ? 0 : 1)

struct PlannedRelease: Decodable {
    let folder: String
    let notes: String

    var folderURL: URL {
        URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
    }

    var folderName: String {
        folderURL.lastPathComponent
    }
}

enum Outcome {
    case published(StoreItem.ID, StoreVersion)
    case wouldPublish(StoreItem.ID, StoreVersion)
    case alreadyPublished(String)
    case failed(String)

    var text: String {
        switch self {
        case .published(let id, let version): "published \(id) \(version)"
        case .wouldPublish(let id, let version): "would publish \(id) \(version)"
        case .alreadyPublished(let reason): "skipped, \(reason)"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

func readPlan(at path: String) throws -> [PlannedRelease] {
    let plan = try JSONDecoder().decode([PlannedRelease].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    if let unnoted = plan.first(where: { $0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
        fail("\(unnoted.folderName): every release needs notes")
    }
    return plan
}

@MainActor
func makeEngine() throws -> Engine {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("luma-publish-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return Engine(
        store: try ProjectStore(path: scratch.appendingPathComponent("db.sqlite").path),
        blobs: try BlobStore(directory: scratch.appendingPathComponent("blobs", isDirectory: true)),
        dataDirectory: scratch,
        tokenStore: PublisherTokenStore())
}

@MainActor
func publish(_ release: PlannedRelease, dryRun: Bool, through storefront: Storefront) async -> Outcome {
    do {
        let draft = try storefront.publishDraft(forFolderAt: release.folderURL)
        guard let version = draft.version else { return .failed("package.json has no version") }
        guard draft.listing.hasValidSummary else { throw StorefrontError.invalidSummary }
        if dryRun {
            return try await rehearse(release, version: version, through: storefront)
        }
        let item = try await storefront.publish(folderAt: release.folderURL, version: version, listing: draft.listing, notes: release.notes)
        return .published(item.id, item.version)
    } catch StorefrontError.rejected(.versionNotNewer, let message) {
        return .alreadyPublished(message)
    } catch {
        return .failed(error.localizedDescription)
    }
}

@MainActor
func rehearse(_ release: PlannedRelease, version: StoreVersion, through storefront: Storefront) async throws -> Outcome {
    let publication = try await storefront.publication(ofFolderAt: release.folderURL)
    if let published = try await storefront.publishedVersion(ofItemID: publication.itemID), published >= version {
        return .alreadyPublished("\(publication.itemID) is already at \(published)")
    }
    return .wouldPublish(publication.itemID, version)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

struct PublisherTokenStore: TokenStore {
    func get(service: String, account: String) async throws -> String? {
        if let token = ProcessInfo.processInfo.environment["LUMA_GITHUB_TOKEN"] {
            return token
        }
        return try await lumaTokens.get(service: service, account: account)
    }

    func set(service: String, account: String, token: String) async throws {}

    func delete(service: String, account: String) async throws {}

    private var lumaTokens: FileTokenStore {
        FileTokenStore(directory: LumaAppPaths.shared.dataDirectory.appendingPathComponent("Tokens", isDirectory: true))
    }
}
