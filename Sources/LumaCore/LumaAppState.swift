import Foundation

@MainActor
public final class LumaAppState {
    public static let shared: LumaAppState = LumaAppState(paths: .shared)

    public struct MissionDefaults: Codable, Equatable, Sendable {
        public var providerID: String
        public var modelID: String
        public var tokenBudgetInput: Int
        public var tokenBudgetOutput: Int
        public var thinkingEnabled: Bool
        public var thinkingBudget: Int
        public var reasoningEffort: String?

        public init(
            providerID: String,
            modelID: String,
            tokenBudgetInput: Int,
            tokenBudgetOutput: Int,
            thinkingEnabled: Bool,
            thinkingBudget: Int,
            reasoningEffort: String? = nil
        ) {
            self.providerID = providerID
            self.modelID = modelID
            self.tokenBudgetInput = tokenBudgetInput
            self.tokenBudgetOutput = tokenBudgetOutput
            self.thinkingEnabled = thinkingEnabled
            self.thinkingBudget = thinkingBudget
            self.reasoningEffort = reasoningEffort
        }

        public static let initial = MissionDefaults(
            providerID: "claude-code",
            modelID: "default",
            tokenBudgetInput: 250_000,
            tokenBudgetOutput: 32_000,
            thinkingEnabled: false,
            thinkingBudget: 4_096
        )
    }

    private struct Stored: Codable, Equatable {
        var untitledRelative: String?
        var externalAbsolute: String?
        var recentPaths: [String] = []
        var openDocuments: [String] = []
        var providerBaseURLs: [String: String]?
        var missionDefaults: MissionDefaults?
        var externalMCPTrustsClient: Bool?
        var instrumentFolderLinks: [String: InstrumentFolderLink]?
    }

    private var stored: Stored
    private let paths: LumaAppPaths
    private let maxRecents = 10

    public init(paths: LumaAppPaths) {
        self.paths = paths

        let fm = FileManager.default
        if fm.fileExists(atPath: paths.stateURL.path),
           let data = try? Data(contentsOf: paths.stateURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        {
            self.stored = decoded
        } else {
            self.stored = Stored()
        }
    }

    public var untitledDirectory: URL { paths.untitledDirectory }
    public var dataDirectory: URL { paths.dataDirectory }

    public var lastDocumentPath: String? {
        get {
            if let rel = stored.untitledRelative {
                return paths.untitledDirectory.appendingPathComponent(rel).path
            }
            return stored.externalAbsolute
        }
        set {
            var next = stored
            if let newValue {
                let prefix = paths.untitledDirectory.path + "/"
                if newValue.hasPrefix(prefix) {
                    next.untitledRelative = String(newValue.dropFirst(prefix.count))
                    next.externalAbsolute = nil
                } else {
                    next.untitledRelative = nil
                    next.externalAbsolute = newValue
                }
            } else {
                next.untitledRelative = nil
                next.externalAbsolute = nil
            }
            guard stored != next else { return }
            stored = next
            persist()
        }
    }

    public var recentPaths: [String] {
        stored.recentPaths
    }

    public func recordRecent(path: String) {
        var list = stored.recentPaths.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > maxRecents {
            list = Array(list.prefix(maxRecents))
        }
        guard list != stored.recentPaths else { return }
        stored.recentPaths = list
        persist()
    }

    public var openDocumentPaths: [String] {
        stored.openDocuments
    }

    public func noteDocumentOpened(path: String) {
        guard !stored.openDocuments.contains(path) else { return }
        stored.openDocuments.append(path)
        persist()
    }

    public func noteDocumentClosed(path: String) {
        guard let index = stored.openDocuments.firstIndex(of: path) else { return }
        stored.openDocuments.remove(at: index)
        persist()
    }

    public func setOpenDocumentPaths(_ paths: [String]) {
        guard stored.openDocuments != paths else { return }
        stored.openDocuments = paths
        persist()
    }

    public func pruneMissingRecents() {
        let fm = FileManager.default
        let pruned = stored.recentPaths.filter { fm.fileExists(atPath: $0) }
        guard pruned.count != stored.recentPaths.count else { return }
        stored.recentPaths = pruned
        persist()
    }

    public func isUntitledAutoSavePath(_ path: String) -> Bool {
        path.hasPrefix(paths.untitledDirectory.path + "/") || path == paths.untitledDirectory.path
    }

    public var missionDefaults: MissionDefaults {
        get { stored.missionDefaults ?? .initial }
        set {
            guard stored.missionDefaults != newValue else { return }
            stored.missionDefaults = newValue
            persist()
        }
    }

    public var externalMCPTrustsClient: Bool {
        get { stored.externalMCPTrustsClient ?? false }
        set {
            guard stored.externalMCPTrustsClient != newValue else { return }
            stored.externalMCPTrustsClient = newValue
            persist()
        }
    }

    public func instrumentFolderLink(forDefID defID: UUID) -> InstrumentFolderLink? {
        stored.instrumentFolderLinks?[defID.uuidString]
    }

    public func setInstrumentFolderLink(_ link: InstrumentFolderLink?, forDefID defID: UUID) {
        var links = stored.instrumentFolderLinks ?? [:]
        links[defID.uuidString] = link
        let next: [String: InstrumentFolderLink]? = links.isEmpty ? nil : links
        guard stored.instrumentFolderLinks != next else { return }
        stored.instrumentFolderLinks = next
        persist()
    }

    public func providerBaseURL(providerID: String) -> String? {
        stored.providerBaseURLs?[providerID]
    }

    public func setProviderBaseURL(_ value: String?, providerID: String) {
        var map = stored.providerBaseURLs ?? [:]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            map[providerID] = trimmed
        } else {
            map.removeValue(forKey: providerID)
        }
        let next: [String: String]? = map.isEmpty ? nil : map
        guard stored.providerBaseURLs != next else { return }
        stored.providerBaseURLs = next
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: paths.stateURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("[LumaAppState] persist failed at \(paths.stateURL.path): \(error)\n".utf8)
            )
        }
    }
}
