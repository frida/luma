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
    private static let lockFileName = "package-lock.json"
    private static let dependenciesDirectoryName = "node_modules"
    private static let typingsFileName = "luma.d.ts"
    private static let defaultIconFileName = "icon.png"

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

    public var rootURL: URL {
        manifest.luma?.root.map { folderURL.appendingPathComponent($0).standardizedFileURL } ?? folderURL.standardizedFileURL
    }

    public init(folderURL: URL) throws {
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: folderURL.appendingPathComponent(Self.manifestFileName))
        )
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
            features: manifest.luma?.features ?? [],
            widgets: manifest.luma?.widgets ?? [],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        def.normalize()
        return def
    }

    public func sourcePaths() throws -> [String] {
        let own = try Self.entries(in: folderURL).filter { !$0.isDirectory && !generatedPaths.contains($0.path) }.map { prefix + $0.path }
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
        let existing = try? InstrumentFolder(folderURL: folderURL)
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
            features: def.features,
            widgets: def.widgets
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
        files.append(File(path: manifestFileName, content: try manifestData(for: package)))

        files.append(typingsFile(for: def))

        return files
    }

    private static func updateManifest(in folderURL: URL, _ change: (inout [String: Any]) -> Void) throws {
        let manifestURL = folderURL.appendingPathComponent(manifestFileName)
        var package: [String: Any] =
            if let existing = FileManager.default.contents(atPath: manifestURL.path) {
                try JSONSerialization.jsonObject(with: existing) as! [String: Any]
            } else {
                [:]
            }
        change(&package)
        try write([File(path: manifestFileName, content: try manifestData(for: package))], to: folderURL)
    }

    private static func manifestData(for package: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
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

    private var prefix: String {
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

    private var generatedPaths: Set<String> {
        var paths: Set = [Self.manifestFileName, Self.lockFileName, Self.typingsFileName]
        if let iconPath = manifest.luma?.iconFilePath {
            paths.insert(iconPath)
        }
        return paths
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

    private struct Manifest: Decodable, Sendable {
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
            var features: [CustomInstrumentDef.Feature]?
            var widgets: [InstrumentWidget]?

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
    }
}
