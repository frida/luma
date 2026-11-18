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

    private let manifest: Manifest

    public var id: String {
        folderURL.lastPathComponent
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
    }

    public func customInstrument(id: UUID, createdAt: Date, updatedAt: Date) throws -> CustomInstrumentBundle {
        let files = try sourcePaths().map { path in
            CustomInstrumentFile(
                defID: id,
                path: path,
                content: String(decoding: try Data(contentsOf: folderURL.appendingPathComponent(path)), as: UTF8.self)
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
            entrypoint: manifest.main,
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
        try Self.entries(in: folderURL).filter { !$0.isDirectory && !generatedPaths.contains($0.path) }.map(\.path).sorted()
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
        var files = try files(for: instrument, mergingInto: existingManifest)
        let described = (try? InstrumentFolder(folderURL: folderURL))?
            .definition(id: def.id, createdAt: def.createdAt, updatedAt: def.updatedAt)
        if described == def {
            files.removeAll { $0.path == manifestFileName }
        }
        try write(files, to: folderURL)

        let currentPaths = Set(instrument.files.map(\.path))
        for path in previousPaths where !currentPaths.contains(path) {
            let fileURL = folderURL.appendingPathComponent(path)
            if fm.fileExists(atPath: fileURL.path) {
                try fm.removeItem(at: fileURL)
            }
        }
    }

    public static func writeTypings(for def: CustomInstrumentDef, to folderURL: URL) throws {
        try write([typingsFile(for: def)], to: folderURL)
    }

    public static func files(for instrument: CustomInstrumentBundle, mergingInto existingManifest: Data? = nil) throws -> [File] {
        let def = instrument.def
        var files = instrument.files.map { File(path: $0.path, content: Data($0.content.utf8)) }

        let icon: Manifest.Icon
        switch def.icon {
        case .symbolic(let id):
            icon = .symbolic(id)
        case .pixels(let data):
            let iconPath = existingManifest.flatMap(iconFilePath(inManifest:)) ?? defaultIconFileName
            icon = .file(iconPath)
            files.append(File(path: iconPath, content: data))
        }

        let section = Manifest.Section(
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
        package["main"] = def.entrypoint
        package["dependencies"] = def.dependencies.isEmpty ? nil : def.dependencies
        package["luma"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(section))
        let manifestData = try JSONSerialization.data(
            withJSONObject: package,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        files.append(File(path: manifestFileName, content: manifestData))

        files.append(typingsFile(for: def))

        return files
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

    private var generatedPaths: Set<String> {
        var paths: Set = [Self.manifestFileName, Self.lockFileName, Self.typingsFileName]
        if case .file(let iconPath) = manifest.luma?.icon {
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

    private static func iconFilePath(inManifest data: Data) -> String? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
            case .file(let path) = manifest.luma?.icon
        else { return nil }
        return path
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
        let main: String
        let dependencies: [String: String]?
        let luma: Section?

        struct Section: Codable, Sendable {
            var icon: Icon?
            var compatibility: InstrumentCompatibility?
            var features: [CustomInstrumentDef.Feature]?
            var widgets: [InstrumentWidget]?
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
