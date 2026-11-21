import Foundation
import Observation

@Observable
@MainActor
public final class Storefront {
    public enum State: Equatable, Sendable {
        case closed
        case loading
        case loaded
        case failed(message: String)
    }

    public enum MoreResults: Equatable, Sendable {
        case allLoaded
        case available
        case loading
        case failed(message: String)
    }

    public enum Entitlement: Equatable, Sendable {
        case entitled
        case unknown(requiredMonthlyCents: Int)
        case sponsorshipNeeded(requiredMonthlyCents: Int, accountMonthlyCents: Int)
    }

    public enum InstallState: Equatable, Sendable {
        case notInstalled
        case installed(StoreVersion)
        case updateAvailable(installed: StoreVersion, latest: StoreVersion)
    }

    public enum LocalChanges: Sendable {
        case keep
        case discard
    }

    public private(set) var state: State = .closed
    public private(set) var firstPageSize = 0
    public private(set) var searchText = ""
    public private(set) var category: StoreCategory.ID?
    public private(set) var results: [StoreItem] = []
    public private(set) var totalResults = 0
    public private(set) var moreResults: MoreResults = .allLoaded
    public private(set) var installedItems: [StoreItem] = []
    public private(set) var categories: [StoreCategory] = []
    public private(set) var account: StoreAccount?
    public private(set) var installations: [StoreItem.ID: StoreInstallation] = [:]

    private var categoryNames: [StoreCategory.ID: String] = [:]

    @ObservationIgnored private unowned let engine: Engine
    @ObservationIgnored private let portal: PortalConnection
    @ObservationIgnored private let catalog: StoreCatalog
    @ObservationIgnored private var device: SystemParameters?
    @ObservationIgnored private var listedItems: [StoreItem] = [] {
        didSet { refreshResults() }
    }
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var essentials: Task<Void, Swift.Error>?
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored private var iconFetches: [IconKey: Task<InstrumentIcon, Never>] = [:]
    @ObservationIgnored private var lease: PortalConnection.Lease?
    @ObservationIgnored private var accountLoading: Task<Void, Never>?
    @ObservationIgnored private var accountConnection: Task<StoreAccount, Swift.Error>?

    private static let laterPageSize = 24
    private static let fallbackIcon = InstrumentIcon.symbolic(InstrumentIconCatalog.default.id)

    init(engine: Engine, portal: PortalConnection, catalogURL: URL) {
        self.engine = engine
        self.portal = portal
        self.catalog = StoreCatalog(baseURL: catalogURL)
    }

    public var needsSignIn: Bool {
        engine.gitHubAuth.token == nil
    }

    public var canPublish: Bool {
        account?.publisher != nil
    }

    public var remainingResults: Int {
        totalResults - nextOffset
    }

    public func open(for device: SystemParameters?, showing firstPageSize: Int) async {
        self.device = device
        self.firstPageSize = firstPageSize
        searchText = ""
        category = nil
        installations = reconciledInstallations()
        refreshResults()
        let previousAccountLoading = accountLoading
        let accountLoading = Task {
            await previousAccountLoading?.value
            await self.loadAccountIfSignedIn()
        }
        self.accountLoading = accountLoading
        await reload()
        await accountLoading.value
    }

    public func reload() async {
        essentials?.cancel()
        essentials = Task { try await self.loadInstalledItemsAndCategories() }
        await replaceResults()
    }

    public func search(_ text: String) async {
        searchText = text
        await replaceResults()
    }

    public func filter(by category: StoreCategory.ID?) async {
        self.category = category
        await replaceResults()
    }

    public func loadMore() async {
        switch moreResults {
        case .available, .failed:
            break
        case .allLoaded, .loading:
            return
        }
        moreResults = .loading
        let (text, category, offset) = (searchText, self.category, nextOffset)
        await supersedeListing { await self.loadNextPage(matching: text, in: category, from: offset) }
    }

    public func icon(of item: StoreItem) async -> InstrumentIcon {
        switch item.icon {
        case .symbolic(let id):
            return .symbolic(id)
        case .pixels:
            return await pixelIcon(of: item)
        }
    }

    public func categoryName(of item: StoreItem) -> String? {
        categoryNames[item.category]
    }

    public func loadCategories() async throws {
        remember(try await catalog.categories())
    }

    public func close() async {
        listing?.cancel()
        essentials?.cancel()
        essentials = nil
        await accountLoading?.value
        accountLoading = nil
        _ = try? await accountConnection?.value
        await releaseLease()
        listedItems = []
        installedItems = []
        remember([])
        totalResults = 0
        moreResults = .allLoaded
        state = .closed
    }

    public func entitlement(for item: StoreItem) -> Entitlement {
        guard case .sponsor(let requiredMonthlyCents) = item.access else { return .entitled }
        guard let account else { return .unknown(requiredMonthlyCents: requiredMonthlyCents) }
        guard account.monthlyCents < requiredMonthlyCents else { return .entitled }
        return .sponsorshipNeeded(requiredMonthlyCents: requiredMonthlyCents, accountMonthlyCents: account.monthlyCents)
    }

    public func installState(of item: StoreItem) -> InstallState {
        guard let installed = installations[item.id]?.version else { return .notInstalled }
        guard installed < item.version else { return .installed(installed) }
        return .updateAvailable(installed: installed, latest: item.version)
    }

    public func installationFolderURL(for itemID: StoreItem.ID) -> URL {
        engine.instrumentFolders.directory.appendingPathComponent(itemID.replacingOccurrences(of: "/", with: "."), isDirectory: true)
    }

    public func detail(of item: StoreItem) async throws -> StoreItemDetail {
        let detail = try await catalog.detail(of: item)
        upsert(detail.item)
        return detail
    }

    public func install(_ item: StoreItem, localChanges: LocalChanges = .keep) async throws {
        let folderURL = installationFolderURL(for: item.id)
        if localChanges == .keep, holdsLocalChanges(folderURL, itemID: item.id) {
            throw StorefrontError.localChanges(itemID: item.id)
        }
        try await requireAccount()
        let reply = try await request(
            to: item.path,
            type: ".download",
            payload: ["version": item.version.description, "client": Self.client]
        )
        guard let bundle = (reply["bundle"] as? JSONObject).flatMap(CustomInstrumentBundle.fromJSON),
            let latest = StoreItem.fromWireJSON(reply["item"])
        else { throw StorefrontError.malformedReply }
        try deploy(bundle, as: item, to: folderURL)
        upsert(latest)
        listInstalled(latest)
    }

    public func uninstall(itemID: StoreItem.ID, localChanges: LocalChanges = .keep) throws {
        let folderURL = installationFolderURL(for: itemID)
        if localChanges == .keep, holdsLocalChanges(folderURL, itemID: itemID) {
            throw StorefrontError.localChanges(itemID: itemID)
        }
        if FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.removeItem(at: folderURL)
        }
        record(nil, forItemID: itemID)
        installedItems.removeAll { $0.id == itemID }
        engine.instrumentFolders.reload()
    }

    public func publishDraft(forCustomInstrument defID: UUID) throws -> StorePublishDraft {
        let folderURL = try linkedFolderURL(of: defID)
        let folder = try InstrumentFolder(folderURL: folderURL)
        return StorePublishDraft(
            slug: folder.packageName,
            version: folder.version.flatMap(StoreVersion.init),
            listing: folder.storeListing ?? StoreListing(summary: "", category: nil, access: .free),
            description: readme(in: folderURL)
        )
    }

    @discardableResult
    public func publish(
        customInstrument defID: UUID,
        version: StoreVersion,
        listing: StoreListing,
        notes: String
    ) async throws -> StoreItem {
        guard let publisher = try await requireAccount().publisher else { throw StorefrontError.notPublisher }
        let folderURL = try linkedFolderURL(of: defID)
        let folder = try InstrumentFolder(folderURL: folderURL)
        let slug = folder.packageName
        guard StoreItem.isValidName(slug) else { throw StorefrontError.invalidPackageName(slug) }
        let now = Date()
        let bundle = try Engine.validatedCustomInstrumentBundle(folder.customInstrument(id: defID, createdAt: now, updatedAt: now))
        var payload: JSONObject = [
            "kind": StoreItemKind.instrument.rawValue,
            "version": version.description,
            "summary": listing.summary,
            "description": readme(in: folderURL) ?? "",
            "access": listing.access.toWireJSON(),
            "notes": notes,
            "bundle": bundle.toJSON(),
        ]
        payload["category"] = listing.category
        let reply = try await request(to: StoreItem.path(of: "\(publisher.handle)/\(slug)"), type: ".publish", payload: payload)
        guard let item = StoreItem.fromWireJSON(reply["item"]) else { throw StorefrontError.malformedReply }
        try InstrumentFolder.writeStoreRelease(version: version, listing: listing, in: folderURL)
        upsert(item)
        return item
    }

    @discardableResult
    public func requireAccount() async throws -> StoreAccount {
        guard let token = await engine.gitHubAuth.requestToken() else { throw StorefrontError.signInCancelled }
        return try await loadAccount(token: token)
    }

    private func reconciledInstallations() -> [StoreItem.ID: StoreInstallation] {
        let appState = LumaAppState.shared
        let uninstalledBehindOurBack = appState.storeInstallations.keys.filter {
            !FileManager.default.fileExists(atPath: installationFolderURL(for: $0).path)
        }
        for itemID in uninstalledBehindOurBack {
            appState.setStoreInstallation(nil, forItemID: itemID)
        }
        return appState.storeInstallations
    }

    private func refreshResults() {
        results = listedItems.filter { installations[$0.id] == nil }
    }

    private func loadAccountIfSignedIn() async {
        let auth = engine.gitHubAuth
        await auth.loadPersistedToken()
        guard let token = auth.token else { return }
        _ = try? await loadAccount(token: token)
    }

    private func loadInstalledItemsAndCategories() async throws {
        async let installed = fetchInstalledItems()
        async let categories = catalog.categories()
        let (fetchedInstalledItems, fetchedCategories) = try await (installed, categories)
        try Task.checkCancellation()
        installedItems = fetchedInstalledItems
        remember(fetchedCategories)
    }

    private func fetchInstalledItems() async throws -> [StoreItem] {
        let ids = installations.keys.sorted()
        guard !ids.isEmpty else { return [] }
        return try await catalog.items(withIDs: ids)
    }

    private func remember(_ categories: [StoreCategory]) {
        self.categories = categories
        categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
    }

    private func replaceResults() async {
        state = .loading
        moreResults = .allLoaded
        let (text, category) = (searchText, self.category)
        await supersedeListing { await self.loadFirstPage(matching: text, in: category) }
    }

    private func supersedeListing(with work: @escaping @MainActor () async -> Void) async {
        listing?.cancel()
        let task = Task { await work() }
        listing = task
        await task.value
    }

    private func loadFirstPage(matching text: String, in category: StoreCategory.ID?) async {
        do {
            let page = try await catalog.page(matching: text, in: category, for: device, offset: 0, limit: firstPageSize)
            try await essentials?.value
            try Task.checkCancellation()
            listedItems = page.items
            track(page)
            state = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(message: error.localizedDescription)
        }
    }

    private func loadNextPage(matching text: String, in category: StoreCategory.ID?, from offset: Int) async {
        do {
            let page = try await catalog.page(matching: text, in: category, for: device, offset: offset, limit: Self.laterPageSize)
            try Task.checkCancellation()
            let listedIDs = Set(listedItems.map(\.id))
            listedItems += page.items.filter { !listedIDs.contains($0.id) }
            track(page)
        } catch {
            guard !Task.isCancelled else { return }
            moreResults = .failed(message: error.localizedDescription)
        }
    }

    private func track(_ page: StoreCatalogPage) {
        totalResults = page.total
        nextOffset = page.nextOffset
        moreResults = page.hasMore ? .available : .allLoaded
    }

    private func pixelIcon(of item: StoreItem) async -> InstrumentIcon {
        let key = IconKey(itemID: item.id, version: item.version)
        if let fetch = iconFetches[key] {
            return await fetch.value
        }
        let fetch = Task { await self.fetchPixelIcon(of: item, cachedAs: key) }
        iconFetches[key] = fetch
        return await fetch.value
    }

    private func fetchPixelIcon(of item: StoreItem, cachedAs key: IconKey) async -> InstrumentIcon {
        do {
            return .pixels(try await catalog.iconPixels(of: item))
        } catch {
            iconFetches[key] = nil
            return Self.fallbackIcon
        }
    }

    private struct IconKey: Hashable {
        let itemID: StoreItem.ID
        let version: StoreVersion
    }

    private func loadAccount(token: String) async throws -> StoreAccount {
        if let account {
            return account
        }
        if let accountConnection {
            return try await accountConnection.value
        }
        let connection = Task { try await self.connect(token: token) }
        accountConnection = connection
        defer { accountConnection = nil }
        return try await connection.value
    }

    private func connect(token: String) async throws -> StoreAccount {
        try await retainLease(token: token)
        do {
            let account = try await fetchAccount()
            self.account = account
            return account
        } catch {
            await releaseLease()
            throw error
        }
    }

    private func retainLease(token: String) async throws {
        do {
            lease = try await portal.retain(token: token) { [weak self] event in
                self?.handle(event)
            }
        } catch {
            guard let failure = (error as? AuthFailure) ?? AuthFailure.fromError(error) else { throw error }
            if failure.isAuthRejection {
                await engine.gitHubAuth.signOut()
            }
            throw StorefrontError(failure)
        }
    }

    private func handle(_ event: PortalConnection.Event) {
        switch event {
        case .notification(let notification):
            guard notification.from == "/store/account", notification.type == "+update",
                let account = StoreAccount.fromWireJSON(notification.payload["account"])
            else { return }
            self.account = account
        case .detached:
            lease = nil
            account = nil
        }
    }

    private func fetchAccount() async throws -> StoreAccount {
        let reply = try await request(to: "/store/account", type: ".get")
        guard let account = StoreAccount.fromWireJSON(reply["account"]) else { throw StorefrontError.malformedReply }
        return account
    }

    private func request(to path: String, type: String, payload: JSONObject = [:]) async throws -> JSONObject {
        guard let lease else { throw StorefrontError.disconnected }
        do {
            return try await lease.request(to: path, type: type, payload: payload).payload
        } catch let failure as AuthFailure {
            throw StorefrontError(failure)
        }
    }

    private func releaseLease() async {
        await lease?.release()
        lease = nil
        account = nil
    }

    private func holdsLocalChanges(_ folderURL: URL, itemID: StoreItem.ID) -> Bool {
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return false }
        guard let installation = installations[itemID] else { return true }
        return (try? snapshot(of: folderURL)) != installation.snapshot
    }

    private func deploy(_ bundle: CustomInstrumentBundle, as item: StoreItem, to folderURL: URL) throws {
        var instrument = try Engine.validatedCustomInstrumentBundle(bundle)
        instrument.def.normalize()
        let previousPaths = (try? InstrumentFolder(folderURL: folderURL).sourcePaths()) ?? []
        try InstrumentFolder.stampPackage(name: item.slug, version: item.version, in: folderURL)
        try InstrumentFolder.write(instrument, to: folderURL, replacing: previousPaths)
        record(StoreInstallation(itemID: item.id, version: item.version, snapshot: try snapshot(of: folderURL)), forItemID: item.id)
        engine.instrumentFolders.reload()
    }

    private func snapshot(of folderURL: URL) throws -> InstrumentFolderLink.Snapshot {
        let folder = try InstrumentFolder(folderURL: folderURL)
        return InstrumentFolderLink.Snapshot(of: try folder.customInstrument(id: UUID(), createdAt: .distantPast, updatedAt: .distantPast))
    }

    private func record(_ installation: StoreInstallation?, forItemID itemID: StoreItem.ID) {
        LumaAppState.shared.setStoreInstallation(installation, forItemID: itemID)
        installations[itemID] = installation
        refreshResults()
    }

    private func upsert(_ item: StoreItem) {
        if let index = listedItems.firstIndex(where: { $0.id == item.id }) {
            listedItems[index] = item
        }
        if let index = installedItems.firstIndex(where: { $0.id == item.id }) {
            installedItems[index] = item
        }
    }

    private func listInstalled(_ item: StoreItem) {
        guard !installedItems.contains(where: { $0.id == item.id }) else { return }
        installedItems.append(item)
    }

    private func linkedFolderURL(of defID: UUID) throws -> URL {
        guard let link = engine.instrumentFolderLinks[defID] else { throw StorefrontError.notLinkedToFolder }
        return link.folderURL
    }

    private func readme(in folderURL: URL) -> String? {
        try? String(contentsOf: folderURL.appendingPathComponent("README.md"), encoding: .utf8)
    }

    private static var client: JSONObject {
        var client: JSONObject = ["platform": platform]
        client["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return client
    }

    private static var platform: String {
        #if os(Windows)
        "windows"
        #elseif os(macOS)
        "macos"
        #elseif os(Linux)
        "linux"
        #elseif os(iOS)
        "ios"
        #endif
    }
}

public enum StorefrontError: Swift.Error, LocalizedError, Equatable {
    case signInCancelled
    case disconnected
    case localChanges(itemID: StoreItem.ID)
    case notLinkedToFolder
    case notPublisher
    case invalidPackageName(String)
    case rejected(Rejection, message: String)
    case server(message: String)
    case malformedReply

    public enum Rejection: String, Sendable {
        case notFound = "not_found"
        case sponsorshipRequired = "sponsorship_required"
        case forbidden
        case versionNotNewer = "version_not_newer"
        case invalidItem = "invalid_item"
    }

    init(_ failure: AuthFailure) {
        self.init(code: failure.code, message: failure.message)
    }

    init(code: String, message: String) {
        if let rejection = Rejection(rawValue: code) {
            self = .rejected(rejection, message: message)
        } else {
            self = .server(message: message)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .signInCancelled:
            return "Signing in was cancelled."
        case .disconnected:
            return "Lost the connection to the store."
        case .localChanges:
            return "The installed instrument has been changed since it was installed."
        case .notLinkedToFolder:
            return "Only an instrument linked to a folder can be published."
        case .notPublisher:
            return "This account may not publish to the store."
        case .invalidPackageName(let name):
            return "'\(name)' cannot name an item in the store: use lowercase letters, digits and dashes, starting with a letter or digit."
        case .rejected(_, let message), .server(let message):
            return message
        case .malformedReply:
            return "The store sent a reply Luma could not read."
        }
    }
}
