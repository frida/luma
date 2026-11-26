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
        case requiresLuma(StoreVersion)
        case installed(StoreVersion)
        case updateAvailable(installed: StoreVersion, latest: StoreVersion)
    }

    public struct LinkedInstallation: Hashable, Sendable {
        public let itemID: StoreItem.ID
        public let installedVersion: StoreVersion
        public let latest: Latest

        public enum Latest: Hashable, Sendable {
            case unknown
            case installed(StoreItem)
            case newer(StoreItem)
        }
    }

    public enum LocalChanges: Sendable {
        case keep
        case discard
    }

    public private(set) var state: State = .closed
    public private(set) var firstPageSize = 0
    public private(set) var searchText = ""
    public private(set) var category: StoreCategory.ID?
    public private(set) var totalResults = 0
    public private(set) var moreResults: MoreResults = .allLoaded
    public private(set) var categories: [StoreCategory] = []
    public private(set) var account: StoreAccount?

    private var listedItems: [StoreItem] = []
    private var categoryNames: [StoreCategory.ID: String] = [:]

    @ObservationIgnored private unowned let engine: Engine
    @ObservationIgnored private let portal: PortalConnection
    @ObservationIgnored private let catalog: StoreCatalog
    @ObservationIgnored private let installed: InstalledStoreItems
    @ObservationIgnored private var installedItemsRefresh: Task<Void, Never>?
    @ObservationIgnored private var device: SystemParameters?
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var essentials: Task<Void, Swift.Error>?
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored private var iconFetches: [IconKey: Task<InstrumentIcon, Never>] = [:]
    @ObservationIgnored private var lease: PortalConnection.Lease?
    @ObservationIgnored private var accountLoading: Task<Void, Never>?
    @ObservationIgnored private var accountConnection: Task<StoreAccount, Swift.Error>?
    @ObservationIgnored private var answersUnderway = 0
    @ObservationIgnored private var signInWatch: SignInWatch = .stopped
    @ObservationIgnored private var outdated: [OutdatedInstallation]?

    private static let laterPageSize = 24
    private static let fallbackIcon = InstrumentIcon.symbolic(InstrumentIconCatalog.default.id)

    init(engine: Engine, portal: PortalConnection, catalogURL: URL) {
        self.engine = engine
        self.portal = portal
        self.catalog = StoreCatalog(baseURL: catalogURL)
        self.installed = InstalledStoreItems(library: engine.instrumentFolders)
    }

    func start() {
        installed.reconcile()
        signInWatch = .watching
        watchForSignIn()
        queueAccountLoading()
        guard !installed.isEmpty else { return }
        installedItemsRefresh = Task { try? await self.refreshInstalledItems() }
    }

    func stop() async {
        signInWatch = .stopped
        installedItemsRefresh?.cancel()
        await close()
        await releaseLease()
    }

    public var results: [StoreItem] {
        listedItems.filter { installed.installations[$0.id] == nil }
    }

    public var installedItems: [StoreItem] {
        installed.items
    }

    public var installations: [StoreItem.ID: StoreInstallation] {
        installed.installations
    }

    public var installationsNeedingUpdate: [OutdatedInstallation] {
        _ = (engine.instrumentFolders.unreadableFolders, installed.installations, installed.items)
        guard let outdated else {
            let computed = withObservationTracking(computeInstallationsNeedingUpdate) { [weak self] in
                MainActor.assumeIsolated { self?.outdated = nil }
            }
            outdated = computed
            return computed
        }
        return outdated
    }

    private func computeInstallationsNeedingUpdate() -> [OutdatedInstallation] {
        let unreadable = engine.instrumentFolders.unreadableFolders
        return installed.installations.values
            .compactMap { installation in unreadable[installed.folderURL(for: installation.itemID).standardizedFileURL].map { (installation, $0) } }
            .sorted { $0.0.itemID < $1.0.itemID }
            .map { installation, folderName in
                let item = installed.items.first { $0.id == installation.itemID }
                return OutdatedInstallation(
                    id: installation.itemID,
                    name: item?.name ?? folderName,
                    installedVersion: installation.version,
                    update: item.flatMap { LumaVersion.meets($0.minAppVersion) ? $0 : nil },
                    isListed: item != nil)
            }
    }

    public struct OutdatedInstallation: Sendable, Identifiable {
        public let id: StoreItem.ID
        public let name: String
        public let installedVersion: StoreVersion
        public let update: StoreItem?
        public let isListed: Bool

        public var explanation: String {
            if update != nil {
                return "Needs updating for Luma 4"
            }
            return isListed
                ? "Needs updating for Luma 4; the store has no version for Luma 4 yet"
                : "Needs updating for Luma 4; Luma offers the update once the store can be reached"
        }
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
        installed.reconcile()
        let accountLoading = queueAccountLoading()
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
        listedItems = []
        remember([])
        totalResults = 0
        moreResults = .allLoaded
        state = .closed
        await releaseLeaseUnlessNeeded()
    }

    public func entitlement(for item: StoreItem) -> Entitlement {
        guard case .sponsor(let requiredMonthlyCents) = item.access else { return .entitled }
        guard let account else { return .unknown(requiredMonthlyCents: requiredMonthlyCents) }
        guard account.monthlyCents < requiredMonthlyCents else { return .entitled }
        return .sponsorshipNeeded(requiredMonthlyCents: requiredMonthlyCents, accountMonthlyCents: account.monthlyCents)
    }

    public func installState(of item: StoreItem) -> InstallState {
        let unmetRequirement = item.minAppVersion.flatMap { LumaVersion.meets($0) ? nil : $0 }
        guard let installedVersion = installed.installations[item.id]?.version else {
            return unmetRequirement.map(InstallState.requiresLuma) ?? .notInstalled
        }
        guard installedVersion < item.version || updateNotice(for: item.id) != nil, unmetRequirement == nil else { return .installed(installedVersion) }
        return .updateAvailable(installed: installedVersion, latest: item.version)
    }

    public var installationsAwaitingStore: [OutdatedInstallation] {
        installationsNeedingUpdate.filter { outdated in !installed.items.contains { $0.id == outdated.id } }
    }

    public func updateNotice(for itemID: StoreItem.ID) -> String? {
        installationsNeedingUpdate.first { $0.id == itemID }?.explanation
    }

    public func linkedInstallation(ofCustomInstrument defID: UUID) -> LinkedInstallation? {
        guard let linked = engine.instrumentFolderLinks[defID].flatMap({ installed.linkedInstallation(at: $0.folderURL) }) else { return nil }
        guard case .installed(let item) = linked.latest, updateNotice(for: linked.itemID) != nil else { return linked }
        return LinkedInstallation(itemID: linked.itemID, installedVersion: linked.installedVersion, latest: .newer(item))
    }

    public func installationFolderURL(for itemID: StoreItem.ID) -> URL {
        installed.folderURL(for: itemID)
    }

    public func versionsSinceInstalled(of item: StoreItem) async throws -> [StoreItemVersion] {
        let versions = try await detail(of: item).versions
        guard let installedVersion = installed.installations[item.id]?.version else { return versions }
        return versions.filter { $0.version > installedVersion }
    }

    public func detail(of item: StoreItem) async throws -> StoreItemDetail {
        let detail = try await catalog.detail(of: item)
        upsert(detail.item)
        return detail
    }

    public func install(_ item: StoreItem, localChanges: LocalChanges = .keep) async throws {
        installed.reconcile()
        if localChanges == .keep, try holdsLocalChanges(itemID: item.id) {
            throw StorefrontError.localChanges(itemID: item.id)
        }
        try await requireAccount()
        let reply = try await request(
            to: item.path,
            type: ".download",
            payload: ["version": item.version.description]
        )
        guard let bundle = (reply["bundle"] as? JSONObject).flatMap(CustomInstrumentBundle.fromJSON),
            let latest = StoreItem.fromWireJSON(reply["item"])
        else { throw StorefrontError.malformedReply }
        try installed.deploy(bundle, as: item)
        upsert(latest)
        try reloadCopyLinkedIntoThisProject(itemID: item.id)
    }

    public func uninstall(itemID: StoreItem.ID, localChanges: LocalChanges = .keep) throws {
        installed.reconcile()
        if localChanges == .keep, try holdsLocalChanges(itemID: itemID) {
            throw StorefrontError.localChanges(itemID: itemID)
        }
        try installed.remove(itemID: itemID)
        if !needsLease {
            Task { await releaseLease() }
        }
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
        if let requirement = bundle.undeclaredLumaRequirement {
            throw StorefrontError.lumaRequirementMissing(requirement)
        }
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

    public func answerPartnerContact(_ choice: PartnerContactChoice) async throws {
        guard let token = engine.gitHubAuth.token else { throw StorefrontError.notSignedIn }
        answersUnderway += 1
        let answering = await Task { try await self.sendPartnerContactAnswer(choice, token: token) }.result
        answersUnderway -= 1
        await releaseLeaseUnlessNeeded()
        try answering.get()
    }

    private func watchForSignIn() {
        withObservationTracking {
            _ = engine.gitHubAuth.token
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.hearTokenChange()
            }
        }
    }

    private func hearTokenChange() {
        guard signInWatch == .watching else { return }
        watchForSignIn()
        if needsSignIn {
            account = nil
        } else {
            queueAccountLoading()
        }
    }

    private enum SignInWatch {
        case stopped
        case watching
    }

    private func refreshInstalledItems() async throws {
        let askedIDs = Set(installed.installations.keys)
        guard !askedIDs.isEmpty else { return }
        let answer = try await catalog.items(withIDs: askedIDs.sorted())
        try Task.checkCancellation()
        installed.adopt(answer, askedAbout: askedIDs)
    }

    @discardableResult
    private func queueAccountLoading() -> Task<Void, Never> {
        let previousAccountLoading = accountLoading
        let accountLoading = Task {
            await previousAccountLoading?.value
            await self.loadAccountIfSignedIn()
        }
        self.accountLoading = accountLoading
        return accountLoading
    }

    private func loadAccountIfSignedIn() async {
        let auth = engine.gitHubAuth
        await auth.loadPersistedToken()
        guard let token = auth.token, needsLease || account == nil else { return }
        _ = try? await loadAccount(token: token)
        await releaseLeaseUnlessNeeded()
    }

    private func loadInstalledItemsAndCategories() async throws {
        async let installedItems: Void = refreshInstalledItems()
        async let categories = catalog.categories()
        let (_, fetchedCategories) = try await (installedItems, categories)
        try Task.checkCancellation()
        remember(fetchedCategories)
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

    private func releaseLeaseUnlessNeeded() async {
        guard !needsLease else { return }
        await releaseLease()
    }

    private var needsLease: Bool {
        state != .closed || listensForUpdates || answersUnderway > 0
    }

    private var listensForUpdates: Bool {
        !needsSignIn && !installed.isEmpty
    }

    private func sendPartnerContactAnswer(_ choice: PartnerContactChoice, token: String) async throws {
        _ = try await loadAccount(token: token)
        let reply = try await request(
            to: "/store/account",
            type: ".answer-partner-contact",
            payload: ["choice": choice.rawValue]
        )
        guard let account = StoreAccount.fromWireJSON(reply["account"]) else { throw StorefrontError.malformedReply }
        self.account = account
    }

    private func loadAccount(token: String) async throws -> StoreAccount {
        if let accountConnection {
            return try await accountConnection.value
        }
        if lease != nil, let account {
            return account
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
            guard engine.gitHubAuth.token == token else { throw StorefrontError.disconnected }
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
            guard notification.type == "+update" else { return }
            hearUpdate(from: notification.from, payload: notification.payload)
        case .detached:
            lease = nil
        }
    }

    private func hearUpdate(from path: String, payload: JSONObject) {
        if path == "/store/account", let account = StoreAccount.fromWireJSON(payload["account"]) {
            self.account = account
        } else if let item = StoreItem.fromWireJSON(payload["item"]), path == item.path {
            upsert(item)
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
        let releasedLease = lease
        lease = nil
        await releasedLease?.release()
    }

    private func holdsLocalChanges(itemID: StoreItem.ID) throws -> Bool {
        let linkedCopy = try customInstrumentLinked(toItemID: itemID).map(engine.storedSnapshot(ofCustomInstrument:))
        return installed.holdsLocalChanges(itemID: itemID, linkedCopy: linkedCopy)
    }

    private func upsert(_ item: StoreItem) {
        if let index = listedItems.firstIndex(where: { $0.id == item.id }) {
            listedItems[index] = item
        }
        installed.remember(item)
    }

    private func reloadCopyLinkedIntoThisProject(itemID: StoreItem.ID) throws {
        guard let defID = customInstrumentLinked(toItemID: itemID) else { return }
        try engine.reloadCustomInstrumentFromFolder(defID: defID)
    }

    private func customInstrumentLinked(toItemID itemID: StoreItem.ID) -> UUID? {
        engine.customInstrumentID(linkedToFolderAt: installationFolderURL(for: itemID))
    }

    private func linkedFolderURL(of defID: UUID) throws -> URL {
        guard let link = engine.instrumentFolderLinks[defID] else { throw StorefrontError.notLinkedToFolder }
        return link.folderURL
    }

    private func readme(in folderURL: URL) -> String? {
        try? String(contentsOf: folderURL.appendingPathComponent("README.md"), encoding: .utf8)
    }
}

public enum StorefrontError: Swift.Error, LocalizedError, Equatable {
    case signInCancelled
    case notSignedIn
    case disconnected
    case localChanges(itemID: StoreItem.ID)
    case notLinkedToFolder
    case notPublisher
    case invalidPackageName(String)
    case lumaRequirementMissing(StoreVersion)
    case rejected(Rejection, message: String)
    case server(message: String)
    case malformedReply

    public enum Rejection: String, Sendable {
        case notFound = "not_found"
        case sponsorshipRequired = "sponsorship_required"
        case appUpdateRequired = "app_update_required"
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
        case .notSignedIn:
            return "Not signed in."
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
        case .lumaRequirementMissing(let version):
            return "An instrument with widgets, settings or Smalltalk files runs only in Luma \(version) or newer, so its package.json has to "
                + "say so: \"engines\": { \"luma\": \"\(version.engineRange)\" }."
        case .rejected(_, let message), .server(let message):
            return message
        case .malformedReply:
            return "The store sent a reply Luma could not read."
        }
    }
}
