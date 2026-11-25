import Foundation

public struct InstrumentFolder: Sendable {
    public struct File: Sendable {
        public let path: String
        public let content: Data

        public init(path: String, content: Data) {
            self.path = path
            self.content = content
        }
    }

    static let manifestFileName = "package.json"
    static let lockFileName = "package-lock.json"
    static let dependenciesDirectoryName = "node_modules"
    static let typingsFileName = "luma.d.ts"
    static let defaultIconFileName = "icon.png"
    private static let manifestLineWidth = 100
    private static let topLevelManifestKeys = ["name", "displayName", "version", "main", "engines", "dependencies", "luma"]
    private static let settingManifestKeys = ["id", "name", "schema", "optional", "enabledByDefault"]
    private static let schemaManifestKeys = ["kind", "choices", "fields", "item", "default", "min", "max"]
    private static let choiceManifestKeys = ["id", "name"]
    private static let manifestKeyOrders: [String: [String]] = [
        "luma": ["root", "icon", "compatibility", "settings", "widgets", "store"],
        "icon": ["kind", "value"],
        "compatibility": ["platforms", "osIDs", "archs"],
        "settings": settingManifestKeys,
        "fields": settingManifestKeys,
        "schema": schemaManifestKeys,
        "item": schemaManifestKeys,
        "choices": choiceManifestKeys,
        "default": ["kind", "value"],
        "widgets": ["id", "name", "kind", "config", "actions", "persistence"],
        "config": [
            "unit", "maxBuckets", "series", "maxPoints", "columns", "rowActions", "maxItems", "maxRows", "maxBytes", "maxEntries", "prompt",
            "placeholder", "runButtonLabel", "class", "height",
        ],
        "series": choiceManifestKeys,
        "columns": ["id", "name", "alignment"],
        "actions": choiceManifestKeys,
        "rowActions": choiceManifestKeys,
        "store": ["summary", "category", "access"],
        "access": ["kind", "minMonthlyCents"],
    ]

    public let folderURL: URL
    public let name: String
    public let icon: InstrumentIcon
    public let compatibility: InstrumentCompatibility
    public let minAppVersion: StoreVersion?

    private let manifest: Manifest

    public var id: String {
        folderURL.lastPathComponent
    }

    public var packageName: String {
        manifest.name
    }

    public var version: String? {
        manifest.version
    }

    public var storeListing: StoreListing? {
        manifest.luma?.store
    }

    var iconPath: String? {
        manifest.luma?.iconFilePath
    }

    public var rootURL: URL {
        manifest.luma?.root.map { folderURL.appendingPathComponent($0).standardizedFileURL } ?? folderURL.standardizedFileURL
    }

    public init(folderURL: URL) throws {
        let manifestURL = folderURL.appendingPathComponent(Self.manifestFileName)
        let manifest: Manifest
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[.refusesUnknownKeys] = true
            manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch let error as DecodingError {
            throw LumaCoreError.invalidArgument("\(manifestURL.path): \(Self.problem(in: error))")
        }
        self.folderURL = folderURL
        self.manifest = manifest
        name = manifest.displayName ?? manifest.name
        icon = try Self.loadIcon(manifest.luma?.icon, in: folderURL)
        compatibility = manifest.luma?.compatibility ?? .universal
        minAppVersion = try manifest.engines?["luma"].map(Self.lumaRequirement)
        guard (folderURL.standardizedFileURL.path + "/").hasPrefix(rootURL.path + "/") else {
            throw LumaCoreError.invalidArgument("The root in \(Self.manifestFileName) has to be a folder above it.")
        }
    }

    public func customInstrument(id: UUID, createdAt: Date, updatedAt: Date) throws -> CustomInstrumentBundle {
        let files = try sourcePaths().map { path in
            CustomInstrumentFile(
                defID: id,
                path: path,
                content: String(decoding: try Data(contentsOf: rootURL.appendingPathComponent(path)), as: UTF8.self)
            )
        }
        return CustomInstrumentBundle(def: definition(id: id, createdAt: createdAt, updatedAt: updatedAt), files: files)
    }

    public func definition(id: UUID, createdAt: Date, updatedAt: Date) -> CustomInstrumentDef {
        var def = CustomInstrumentDef(
            id: id,
            name: name,
            icon: icon,
            compatibility: compatibility,
            minAppVersion: minAppVersion,
            entrypoint: prefix + manifest.main,
            dependencies: manifest.dependencies ?? [:],
            settings: manifest.luma?.settings ?? [],
            widgets: manifest.luma?.widgets?.map(\.widget) ?? [],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        def.normalize()
        return def
    }

    public func sourcePaths() throws -> [String] {
        let own = try Self.entries(in: folderURL)
            .filter { !$0.isDirectory && Self.isInstrumentFile($0.path, iconPath: iconPath) }
            .map { prefix + $0.path }
        return (own + sharedPaths(importedBy: own)).sorted()
    }

    public func sharedDirectories() throws -> [URL] {
        let shared = try sourcePaths().filter { !$0.hasPrefix(prefix) }
        return Array(Set(shared.map { rootURL.appendingPathComponent($0).deletingLastPathComponent() }))
    }

    public static func directories(in folderURL: URL) throws -> [URL] {
        [folderURL] + (try entries(in: folderURL).filter(\.isDirectory).map { folderURL.appendingPathComponent($0.path, isDirectory: true) })
    }

    public static func write(
        _ instrument: CustomInstrumentBundle,
        to folderURL: URL,
        replacing previousPaths: some Sequence<String> = EmptyCollection()
    ) throws {
        let fm = FileManager.default
        let def = instrument.def

        let existingManifest = fm.contents(atPath: folderURL.appendingPathComponent(manifestFileName).path)
        let existing = try existingManifest.map { _ in try InstrumentFolder(folderURL: folderURL) }
        let rootURL = existing?.rootURL ?? folderURL
        var generated = try generatedFiles(for: def, mergingInto: existingManifest, under: existing?.prefix ?? "")
        if existing?.definition(id: def.id, createdAt: def.createdAt, updatedAt: def.updatedAt) == def {
            generated.removeAll { $0.path == manifestFileName }
        }
        try write(generated, to: folderURL)
        try write(sourceFiles(of: instrument), to: rootURL)

        let currentPaths = Set(instrument.files.map(\.path))
        for path in previousPaths where !currentPaths.contains(path) {
            let fileURL = rootURL.appendingPathComponent(path)
            if fm.fileExists(atPath: fileURL.path) {
                try fm.removeItem(at: fileURL)
            }
        }
    }

    public static func writeTypings(for def: CustomInstrumentDef, to folderURL: URL) throws {
        try write([typingsFile(for: def)], to: folderURL)
    }

    public static func files(for instrument: CustomInstrumentBundle, mergingInto existingManifest: Data? = nil) throws -> [File] {
        try sourceFiles(of: instrument) + generatedFiles(for: instrument.def, mergingInto: existingManifest, under: "")
    }

    static func stampPackage(name: String, version: StoreVersion, in folderURL: URL) throws {
        try updateManifest(in: folderURL) { package in
            package["name"] = name
            package["version"] = version.description
        }
    }

    static func writeStoreRelease(version: StoreVersion, listing: StoreListing, in folderURL: URL) throws {
        let listingObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(listing))
        try updateManifest(in: folderURL) { package in
            var section = (package["luma"] as? [String: Any]) ?? [:]
            section["store"] = listingObject
            package["version"] = version.description
            package["luma"] = section
        }
    }

    private static func sourceFiles(of instrument: CustomInstrumentBundle) -> [File] {
        instrument.files.map { File(path: $0.path, content: Data($0.content.utf8)) }
    }

    private static func generatedFiles(for def: CustomInstrumentDef, mergingInto existingManifest: Data?, under prefix: String) throws -> [File] {
        var files: [File] = []
        let existing = existingManifest.flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }

        let icon: Manifest.Icon
        switch def.icon {
        case .symbolic(let id):
            icon = .symbolic(id)
        case .pixels(let data):
            let iconPath = existing?.luma?.iconFilePath ?? defaultIconFileName
            icon = .file(iconPath)
            files.append(File(path: iconPath, content: data))
        }

        let section = Manifest.Section(
            root: existing?.luma?.root,
            store: existing?.luma?.store,
            icon: icon,
            compatibility: def.compatibility.isUniversal ? nil : def.compatibility,
            settings: def.settings,
            widgets: def.widgets.map(Manifest.Widget.init)
        )
        var package: [String: Any] =
            if let existingManifest {
                try JSONSerialization.jsonObject(with: existingManifest) as! [String: Any]
            } else {
                ["name": packageName(for: def.name)]
            }
        package["displayName"] = def.name == package["name"] as? String ? nil : def.name
        package["main"] = path(to: def.entrypoint, fromFolderUnder: prefix)
        package["dependencies"] = def.dependencies.isEmpty ? nil : def.dependencies
        var engines = (package["engines"] as? [String: Any]) ?? [:]
        engines["luma"] = def.minAppVersion?.engineRange
        package["engines"] = engines.isEmpty ? nil : engines
        package["luma"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(section))
        files.append(File(path: manifestFileName, content: try manifestData(for: package, keepingOrderOf: existingManifest)))

        files.append(typingsFile(for: def))

        return files
    }

    private static func updateManifest(in folderURL: URL, _ change: (inout [String: Any]) -> Void) throws {
        let manifestURL = folderURL.appendingPathComponent(manifestFileName)
        let existing = FileManager.default.contents(atPath: manifestURL.path)
        var package: [String: Any] =
            if let existing {
                try JSONSerialization.jsonObject(with: existing) as! [String: Any]
            } else {
                [:]
            }
        change(&package)
        try write([File(path: manifestFileName, content: try manifestData(for: package, keepingOrderOf: existing))], to: folderURL)
    }

    private static func manifestData(for package: [String: Any], keepingOrderOf existingManifest: Data?) throws -> Data {
        let originalKeys = try existingManifest.map(topLevelKeys) ?? []
        return Data((try manifestText(package, under: nil, indent: "", lead: 0, originalKeys: originalKeys) + "\n").utf8)
    }

    private static func topLevelKeys(in manifest: Data) throws -> [String] {
        let bytes = [UInt8](manifest)
        var keys: [String] = []
        var depth = 0
        var expectsKey = false
        var stringStart: Int?
        var isEscaped = false
        for (offset, byte) in bytes.enumerated() {
            if let start = stringStart {
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    if depth == 1 && expectsKey {
                        keys.append(try JSONDecoder().decode(String.self, from: Data(bytes[start...offset])))
                        expectsKey = false
                    }
                    stringStart = nil
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                stringStart = offset
            case UInt8(ascii: "{"):
                depth += 1
                expectsKey = depth == 1
            case UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            case UInt8(ascii: ","):
                expectsKey = depth == 1
            default:
                break
            }
        }
        return keys
    }

    private static func manifestText(_ value: Any, under key: String?, indent: String, lead: Int, originalKeys: [String] = []) throws
        -> String
    {
        if let inline = try inlineManifestText(value, under: key), indent.count + lead + inline.count <= manifestLineWidth {
            return inline
        }
        let inner = indent + "  "
        switch value {
        case let object as [String: Any]:
            let members = try orderedManifestKeys(of: object, under: key, originalKeys: originalKeys).map { member in
                let name = try manifestScalar(member)
                return inner + name + ": " + (try manifestText(object[member]!, under: member, indent: inner, lead: name.count + 3))
            }
            return "{\n" + members.joined(separator: ",\n") + "\n" + indent + "}"
        case let array as [Any]:
            let elements = try array.map { inner + (try manifestText($0, under: key, indent: inner, lead: 1)) }
            return "[\n" + elements.joined(separator: ",\n") + "\n" + indent + "]"
        default:
            return try manifestScalar(value)
        }
    }

    private static func inlineManifestText(_ value: Any, under key: String?) throws -> String? {
        switch value {
        case let object as [String: Any]:
            guard !object.values.contains(where: { $0 is [String: Any] }) else { return nil }
            var members: [String] = []
            for member in orderedManifestKeys(of: object, under: key, originalKeys: []) {
                guard let text = try inlineManifestText(object[member]!, under: member) else { return nil }
                members.append(try manifestScalar(member) + ": " + text)
            }
            return members.isEmpty ? "{}" : "{ " + members.joined(separator: ", ") + " }"
        case let array as [Any]:
            guard array.filter({ $0 is [String: Any] || $0 is [Any] }).count <= 1 else { return nil }
            var elements: [String] = []
            for element in array {
                guard let text = try inlineManifestText(element, under: key) else { return nil }
                elements.append(text)
            }
            return "[" + elements.joined(separator: ", ") + "]"
        default:
            return try manifestScalar(value)
        }
    }

    private static func orderedManifestKeys(of object: [String: Any], under key: String?, originalKeys: [String]) -> [String] {
        let known = key.map { manifestKeyOrders[$0] ?? [] } ?? topLevelManifestKeys
        func rank(_ member: String) -> (Int, Int, String) {
            (known.firstIndex(of: member) ?? known.count, originalKeys.firstIndex(of: member) ?? 0, member)
        }
        return object.keys.sorted { rank($0) < rank($1) }
    }

    private static func manifestScalar(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func problem(in error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "\(keyPath(context.codingPath + [key])) is missing"
        case .valueNotFound(_, let context), .typeMismatch(_, let context), .dataCorrupted(let context):
            return context.codingPath.isEmpty ? context.debugDescription : "\(keyPath(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func keyPath(_ path: [CodingKey]) -> String {
        path.reduce("") { written, key in
            key.intValue.map { "\(written)[\($0)]" } ?? (written.isEmpty ? key.stringValue : "\(written).\(key.stringValue)")
        }
    }

    private static func lumaRequirement(_ range: String) throws -> StoreVersion {
        guard let version = StoreVersion.least(inEngineRange: range) else {
            throw LumaCoreError.invalidArgument("engines.luma in \(manifestFileName) has to be >=MAJOR.MINOR.PATCH, not '\(range)'.")
        }
        return version
    }

    private static func loadIcon(_ icon: Manifest.Icon?, in folderURL: URL) throws -> InstrumentIcon {
        switch icon {
        case nil:
            return .symbolic(InstrumentIconCatalog.default.id)
        case .symbolic(let id):
            return .symbolic(id)
        case .file(let path):
            let iconURL = folderURL.appendingPathComponent(try CustomInstrumentFile.validateRelativePath(path))
            return .pixels(try Data(contentsOf: iconURL))
        }
    }

    var prefix: String {
        let folderPath = folderURL.standardizedFileURL.path
        return folderPath == rootURL.path ? "" : String(folderPath.dropFirst(rootURL.path.count + 1)) + "/"
    }

    private func sharedPaths(importedBy own: [String]) -> [String] {
        var shared: Set<String> = []
        var unread = prefix.isEmpty ? [] : own
        while let path = unread.popLast() {
            let fileURL = rootURL.appendingPathComponent(path)
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for specifier in Self.relativeImports(in: source) {
                guard let imported = sourcePath(named: specifier, importedFrom: fileURL), !imported.hasPrefix(prefix),
                    shared.insert(imported).inserted
                else { continue }
                unread.append(imported)
            }
        }
        return Array(shared)
    }

    private func sourcePath(named specifier: String, importedFrom fileURL: URL) -> String? {
        let named = fileURL.deletingLastPathComponent().appendingPathComponent(specifier).standardizedFileURL.path
        let stem = named.hasSuffix(".js") ? String(named.dropLast(3)) : named
        let candidates = [named, stem + ".ts", named + ".ts", named + "/index.ts"]
        var isDirectory: ObjCBool = false
        return candidates
            .first { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && !isDirectory.boolValue }
            .flatMap { $0.hasPrefix(rootURL.path + "/") ? String($0.dropFirst(rootURL.path.count + 1)) : nil }
    }

    private static func relativeImports(in source: String) -> [String] {
        source.matches(of: /(?:from|import|require)\s*\(?\s*["'](\.{1,2}\/[^"']+)["']/).map { String($0.output.1) }
    }

    private static func path(to entrypoint: String, fromFolderUnder prefix: String) -> String {
        if entrypoint.hasPrefix(prefix) {
            return String(entrypoint.dropFirst(prefix.count))
        }
        return String(repeating: "../", count: prefix.split(separator: "/").count) + entrypoint
    }

    static func isInstrumentFile(_ path: String, iconPath: String?) -> Bool {
        let components = path.split(separator: "/")
        let reserved = [manifestFileName, lockFileName, typingsFileName] + (iconPath.map { [$0] } ?? [])
        return !reserved.contains(path)
            && !components.contains { $0.hasPrefix(".") }
            && !components.dropLast().contains { $0 == dependenciesDirectoryName }
    }

    private static func entries(in folderURL: URL) throws -> [(path: String, isDirectory: Bool)] {
        let basePath = folderURL.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )!
        var result: [(path: String, isDirectory: Bool)] = []
        while let url = enumerator.nextObject() as? URL {
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory!
            if isDirectory && url.lastPathComponent == Self.dependenciesDirectoryName {
                enumerator.skipDescendants()
                continue
            }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(basePath.count + 1))
            result.append((path: relativePath, isDirectory: isDirectory))
        }
        return result
    }

    private static func write(_ files: [File], to folderURL: URL) throws {
        let fm = FileManager.default
        for file in files {
            let fileURL = folderURL.appendingPathComponent(file.path)
            if fm.contents(atPath: fileURL.path) == file.content { continue }
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: fileURL)
        }
    }

    private static func packageName(for displayName: String) -> String {
        displayName
            .lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .joined(separator: "-")
    }

    private static func typingsFile(for def: CustomInstrumentDef) -> File {
        File(path: typingsFileName, content: Data(CustomInstrumentTypings.declarations(for: def).utf8))
    }

    fileprivate struct Manifest: Decodable, Sendable {
        let name: String
        let displayName: String?
        let version: String?
        let main: String
        let dependencies: [String: String]?
        let engines: [String: String]?
        let luma: Section?

        struct Section: Codable, Sendable {
            var root: String?
            var store: StoreListing?
            var icon: Icon?
            var compatibility: InstrumentCompatibility?
            var settings: [CustomInstrumentDef.Setting]?
            var widgets: [Widget]?

            var iconFilePath: String? {
                if case .file(let path) = icon {
                    return path
                }
                return nil
            }
        }

        enum Icon: Codable, Sendable {
            case symbolic(String)
            case file(String)

            private enum CodingKeys: String, CodingKey { case kind, value }
            private enum Kind: String, Codable { case symbolic, file }

            init(from decoder: Decoder) throws {
                try decoder.refuseUnknownKeys(CodingKeys.self)
                let c = try decoder.container(keyedBy: CodingKeys.self)
                switch try c.decode(Kind.self, forKey: .kind) {
                case .symbolic: self = .symbolic(try c.decode(String.self, forKey: .value))
                case .file: self = .file(try c.decode(String.self, forKey: .value))
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .symbolic(let id):
                    try c.encode(Kind.symbolic, forKey: .kind)
                    try c.encode(id, forKey: .value)
                case .file(let path):
                    try c.encode(Kind.file, forKey: .kind)
                    try c.encode(path, forKey: .value)
                }
            }
        }

        struct Widget: Codable, Sendable {
            let widget: InstrumentWidget

            private enum CodingKeys: String, CodingKey { case id, name, kind, config, actions, persistence }

            init(_ widget: InstrumentWidget) {
                self.widget = widget
            }

            init(from decoder: Decoder) throws {
                try decoder.refuseUnknownKeys(CodingKeys.self)
                let c = try decoder.container(keyedBy: CodingKeys.self)
                widget = InstrumentWidget(
                    id: try c.decode(String.self, forKey: .id),
                    name: try c.decodeIfPresent(String.self, forKey: .name),
                    kind: try InstrumentWidget.Kind(from: decoder),
                    actions: try c.decodeIfPresent([InstrumentWidget.Action].self, forKey: .actions) ?? [],
                    persistence: try c.decodeIfPresent(InstrumentWidget.Persistence.self, forKey: .persistence) ?? .none)
                if let problem = widget.problem {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath + problem.path.map(ManifestKey.init), debugDescription: problem.text))
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(widget.id, forKey: .id)
                try c.encodeIfPresent(widget.name, forKey: .name)
                try widget.kind.encode(to: encoder)
                if !widget.actions.isEmpty {
                    try c.encode(widget.actions, forKey: .actions)
                }
                try c.encode(widget.persistence, forKey: .persistence)
            }
        }
    }
}

extension InstrumentFolder.Manifest.Section {
    init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            root: try c.decodeIfPresent(String.self, forKey: .root),
            store: try c.decodeIfPresent(StoreListing.self, forKey: .store),
            icon: try c.decodeIfPresent(InstrumentFolder.Manifest.Icon.self, forKey: .icon),
            compatibility: try c.decodeIfPresent(InstrumentCompatibility.self, forKey: .compatibility),
            settings: try c.decodeIfPresent([CustomInstrumentDef.Setting].self, forKey: .settings),
            widgets: try c.decodeIfPresent([InstrumentFolder.Manifest.Widget].self, forKey: .widgets))
        if let problem = InstrumentWidget.countProblem(widgets?.count ?? 0) {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [CodingKeys.widgets], debugDescription: problem))
        }
    }
}

extension CodingUserInfoKey {
    static let refusesUnknownKeys = CodingUserInfoKey(rawValue: "refusesUnknownKeys")!
}

extension Decoder {
    func refuseUnknownKeys<Key: CodingKey & Equatable>(_: Key.Type, knowing known: [Key]? = nil, renamed: [String: String] = [:]) throws {
        guard userInfo[.refusesUnknownKeys] != nil else { return }
        let unknown = try container(keyedBy: ManifestKey.self).allKeys.filter { key in
            Key(stringValue: key.stringValue).map { known?.contains($0) ?? true } != true
        }
        if let first = unknown.min(by: { $0.stringValue < $1.stringValue }) {
            let problem = renamed[first.stringValue].map { "unknown key (now \($0))" } ?? "unknown key"
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [first], debugDescription: problem))
        }
    }
}

private struct ManifestKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.init(stringValue: stringValue)
    }

    init(_ intValue: Int) {
        self.init(intValue: intValue)
    }

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ step: InstrumentWidget.Problem.Step) {
        switch step {
        case .key(let key): self.init(stringValue: key)
        case .index(let index): self.init(intValue: index)
        }
    }
}
