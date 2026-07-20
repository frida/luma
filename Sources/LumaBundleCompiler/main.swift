import Dispatch
import Foundation
import Frida

private let _lumaMainGroup = DispatchGroup()
_lumaMainGroup.enter()
Task {
    await LumaBundleCompiler.main()
    _lumaMainGroup.leave()
}
_lumaMainGroup.wait()

struct LumaBundleCompiler {
    enum Kind: String, Decodable {
        case agent
        case module
    }

    struct Entry {
        let kind: Kind
        let swiftName: String
        let entrypoint: String
    }

    struct CompiledEntry {
        let kind: Kind
        let swiftName: String
        let source: String
    }

    struct TypingsEntry {
        let swiftName: String
        let packageName: String
    }

    struct CompiledTypings {
        let swiftName: String
        let files: [(filePath: String, content: String)]
    }

    struct Config: Decodable {
        struct Output: Decodable {
            let agent: String
            let typings: String?
        }

        struct Input: Decodable {
            let bundles: [BundleEntry]
            let typings: [TypingsPackage]
            let externals: [String]
        }

        struct BundleEntry: Decodable {
            let name: String
            let kind: Kind
            let entrypoint: String
        }

        struct TypingsPackage: Decodable {
            let name: String
            let package: String
        }

        let output: Output
        let input: Input
    }

    static func main() async {
        do {
            try await run()
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())

        var projectRoot: String?
        var swiftOutPath: String?
        var typingsOutPath: String?
        var stagingDir: String?
        var manifestPath: String?
        var lockfilePath: String?
        var shouldUpdateLockfile = true
        var entries: [Entry] = []
        var typingsEntries: [TypingsEntry] = []
        var packageSpecs: [String] = []
        var localPackages: [(name: String, path: String)] = []
        var externals: [String] = []

        func popValue(for flag: String) throws -> String {
            guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
                throw ToolError.usage("Missing value for \(flag)")
            }
            let value = args[idx + 1]
            args.removeSubrange(idx...(idx + 1))
            return value
        }

        if args.contains("--help") || args.isEmpty {
            printUsageAndExit(success: true)
        }

        while !args.isEmpty {
            let flag = args.removeFirst()
            switch flag {
            case "--config":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --config") }
                let configPath = args.removeFirst()
                let config = try loadConfig(at: configPath)
                let configDir = URL(fileURLWithPath: configPath).deletingLastPathComponent()
                manifestPath = configDir.appendingPathComponent("package.json").path
                lockfilePath = configDir.appendingPathComponent("package-lock.json").path
                applyConfig(
                    config,
                    swiftOutPath: &swiftOutPath,
                    typingsOutPath: &typingsOutPath,
                    entries: &entries,
                    typingsEntries: &typingsEntries,
                    externals: &externals)

            case "--project-root":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --project-root") }
                projectRoot = args.removeFirst()

            case "--swift-out":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --swift-out") }
                swiftOutPath = args.removeFirst()

            case "--typings-out":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --typings-out") }
                typingsOutPath = args.removeFirst()

            case "--staging-dir":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --staging-dir") }
                stagingDir = args.removeFirst()

            case "--no-lockfile-update":
                shouldUpdateLockfile = false

            case "--package":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --package") }
                packageSpecs.append(args.removeFirst())

            case "--external":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --external") }
                externals.append(args.removeFirst())

            case "--local-package":
                guard args.count >= 2 else {
                    throw ToolError.usage("Missing values for --local-package <name> <path>")
                }
                let name = args.removeFirst()
                let path = args.removeFirst()
                localPackages.append((name: name, path: path))

            case "--agent":
                guard args.count >= 2 else {
                    throw ToolError.usage("Missing values for --agent <swiftName> <entry.ts>")
                }
                let swiftName = args.removeFirst()
                let entry = args.removeFirst()
                entries.append(
                    Entry(
                        kind: .agent,
                        swiftName: swiftName,
                        entrypoint: entry))

            case "--module":
                guard args.count >= 2 else {
                    throw ToolError.usage("Missing values for --module <swiftName> <entry.ts>")
                }
                let swiftName = args.removeFirst()
                let entry = args.removeFirst()
                entries.append(
                    Entry(
                        kind: .module,
                        swiftName: swiftName,
                        entrypoint: entry))

            default:
                throw ToolError.usage("Unknown argument: \(flag)")
            }
        }

        guard let swiftOutPath else {
            throw ToolError.usage("Missing --swift-out.")
        }

        guard !entries.isEmpty else {
            throw ToolError.usage("No --agent or --module entries provided.")
        }

        if !typingsEntries.isEmpty && typingsOutPath == nil {
            throw ToolError.usage("--typings-out is required when using --typings.")
        }

        let hasManifest = manifestPath.map { FileManager.default.fileExists(atPath: $0) } ?? false

        let effectiveProjectRoot: String
        if !packageSpecs.isEmpty || !localPackages.isEmpty || hasManifest {
            guard let stagingDir else {
                throw ToolError.usage("--staging-dir is required when using --package, --local-package, or --config.")
            }

            let fm = FileManager.default
            if !fm.fileExists(atPath: stagingDir) {
                try fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
            }

            for local in localPackages {
                let dst = URL(fileURLWithPath: stagingDir)
                    .appendingPathComponent("node_modules", isDirectory: true)
                    .appendingPathComponent(local.name, isDirectory: true)
                if (try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil {
                    try fm.removeItem(at: dst)
                }
            }

            if hasManifest || !packageSpecs.isEmpty {
                if hasManifest, let src = manifestPath {
                    try syncFile(at: src, into: stagingDir)
                }
                if let src = lockfilePath, fm.fileExists(atPath: src) {
                    try syncFile(at: src, into: stagingDir)
                }

                let summary = packageSpecs.isEmpty ? "from manifest" : packageSpecs.joined(separator: ", ")
                fputs("[packages] installing: \(summary)\n", stderr)

                let pm = PackageManager()

                do {
                    _ = try await pm.install(
                        specs: packageSpecs.isEmpty ? nil : packageSpecs,
                        projectRoot: stagingDir,
                        role: .runtime)
                } catch {
                    fputs("[packages] frida install failed: \(error.localizedDescription)\n", stderr)
                    fputs("[packages] falling back to npm\n", stderr)
                    let stagingLockfile = URL(fileURLWithPath: stagingDir)
                        .appendingPathComponent("package-lock.json").path
                    try runNPMInstall(
                        in: stagingDir,
                        specs: packageSpecs,
                        preferCleanInstall: packageSpecs.isEmpty && fm.fileExists(atPath: stagingLockfile))
                }

                fputs("[packages] done\n", stderr)

                let stagingLockfile = URL(fileURLWithPath: stagingDir)
                    .appendingPathComponent("package-lock.json").path
                if shouldUpdateLockfile, let dst = lockfilePath, fm.fileExists(atPath: stagingLockfile) {
                    if fm.fileExists(atPath: dst) {
                        try fm.removeItem(atPath: dst)
                    }
                    try fm.copyItem(atPath: stagingLockfile, toPath: dst)
                }
            }

            for local in localPackages {
                let dst = URL(fileURLWithPath: stagingDir)
                    .appendingPathComponent("node_modules", isDirectory: true)
                    .appendingPathComponent(local.name, isDirectory: true)
                let src = URL(fileURLWithPath: local.path).standardizedFileURL

                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.createSymbolicLink(at: dst, withDestinationURL: src)

                fputs("[packages] overriding \(local.name) with \(local.path)\n", stderr)
            }

            let sourceRoot = projectRoot ?? "."
            for entry in entries {
                let srcURL = URL(fileURLWithPath: entry.entrypoint, relativeTo: URL(fileURLWithPath: sourceRoot))
                let dstURL = URL(fileURLWithPath: entry.entrypoint, relativeTo: URL(fileURLWithPath: stagingDir))

                try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dstURL.path) {
                    try fm.removeItem(at: dstURL)
                }
                try fm.copyItem(at: srcURL.standardizedFileURL, to: dstURL)
            }

            // Also copy any files that the entries import via relative paths.
            try copyAgentSources(from: sourceRoot, to: stagingDir)

            effectiveProjectRoot = stagingDir
        } else {
            effectiveProjectRoot = projectRoot ?? "."
        }

        let compiler = Compiler()

        let eventsTask = Task {
            for await event in compiler.events {
                switch event {
                case .starting:
                    fputs("[compiler] starting\n", stderr)
                case .finished:
                    fputs("[compiler] finished\n", stderr)
                case .output(let bundle):
                    fputs("[compiler] output length: \(bundle.utf8.count) bytes\n", stderr)
                case .diagnostics(let any):
                    fputs("[compiler] diagnostics: \(any)\n", stderr)
                }
            }
        }

        var compiled: [CompiledEntry] = []
        compiled.reserveCapacity(entries.count)

        for entry in entries {
            let bundle = try await compiler.build(
                entrypoint: entry.entrypoint,
                externals: externals.isEmpty ? nil : externals,
                projectRoot: effectiveProjectRoot,
                sourceMaps: .omitted)

            let source: String
            switch entry.kind {
            case .agent:
                source = bundle
            case .module:
                source = try unwrapSingleModule(from: bundle)
            }

            compiled.append(
                CompiledEntry(
                    kind: entry.kind,
                    swiftName: entry.swiftName,
                    source: source))
        }

        eventsTask.cancel()

        try writeGeneratedFile(makeAgentFile(from: compiled), to: swiftOutPath)

        if let typingsOutPath, let stagingDir {
            let compiledTypings = try typingsEntries.map { entry in
                CompiledTypings(
                    swiftName: entry.swiftName,
                    files: try readTypingsFiles(for: entry, stagingDir: stagingDir))
            }
            try writeGeneratedFile(makeTypingsFile(from: compiledTypings), to: typingsOutPath)
        }
    }

    static func loadConfig(at path: String) throws -> (config: Config, baseDir: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(Config.self, from: data)
        return (config, url.deletingLastPathComponent().path)
    }

    static func applyConfig(
        _ loaded: (config: Config, baseDir: String),
        swiftOutPath: inout String?,
        typingsOutPath: inout String?,
        entries: inout [Entry],
        typingsEntries: inout [TypingsEntry],
        externals: inout [String]
    ) {
        let (config, baseDir) = loaded
        let resolve: (String) -> String = { resolvePath($0, baseDir: baseDir) }

        if swiftOutPath == nil {
            swiftOutPath = resolve(config.output.agent)
        }
        if typingsOutPath == nil, let out = config.output.typings {
            typingsOutPath = resolve(out)
        }

        for bundle in config.input.bundles {
            entries.append(Entry(kind: bundle.kind, swiftName: bundle.name, entrypoint: bundle.entrypoint))
        }
        for typing in config.input.typings {
            typingsEntries.append(
                TypingsEntry(swiftName: typing.name, packageName: typing.package))
        }
        externals.append(contentsOf: config.input.externals)
    }

    static func syncFile(at source: String, into directory: String) throws {
        let fm = FileManager.default
        let dst = URL(fileURLWithPath: directory)
            .appendingPathComponent((source as NSString).lastPathComponent).path
        if fm.fileExists(atPath: dst) {
            try fm.removeItem(atPath: dst)
        }
        try fm.copyItem(atPath: source, toPath: dst)
    }

    static func resolvePath(_ path: String, baseDir: String) -> String {
        if (path as NSString).isAbsolutePath { return path }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: baseDir, isDirectory: true))
            .standardizedFileURL.path
    }

    static func writeGeneratedFile(_ contents: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        // Preserve the mtime on no-op runs so SwiftPM stays incremental.
        let alreadyUpToDate = (try? String(contentsOf: url, encoding: .utf8)) == contents
        if alreadyUpToDate { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func readTypingsFiles(
        for entry: TypingsEntry,
        stagingDir: String
    ) throws -> [(filePath: String, content: String)] {
        let fm = FileManager.default
        let packageRoot = URL(fileURLWithPath: stagingDir)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(entry.packageName, isDirectory: true)
            .standardizedFileURL

        let enumerator = fm.enumerator(
            at: packageRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var files: [(filePath: String, content: String)] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard url.pathExtension == "ts", url.lastPathComponent.hasSuffix(".d.ts") else { continue }

            let relPath = url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
            let content = try String(contentsOf: url, encoding: .utf8)
            files.append((filePath: "\(entry.packageName)/\(relPath)", content: content))
        }
        files.sort { $0.filePath < $1.filePath }
        return files
    }

    static func printUsageAndExit(success: Bool) -> Never {
        let prog = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "LumaBundleCompiler"
        let text = """
            Usage:
              \(prog) --config <config.json> --project-root <path> --staging-dir <path>

            Options:
              --config <path>               JSON config listing packages, typings, agents, modules
              --project-root <path>         Root that agent entrypoints resolve against
              --staging-dir <path>          Directory for package installation and compilation
              --no-lockfile-update          Do not copy the staging lockfile back to the config directory
              --swift-out <path>            Override agent output path from config
              --typings-out <path>          Override typings output path from config
              --package <spec>              Install an extra npm package
              --external <name>             Do not bundle imports of this npm package
              --typings <swiftName> <spec>  Install an extra typings package and embed its *.d.ts files
              --local-package <name> <path> Override an installed package with a local checkout
              --agent <swiftName> <entry>   Add a Frida-bundle agent entry
              --module <swiftName> <entry>  Add an unwrapped-module entry

            """
        fputs(text, success ? stdout : stderr)
        exit(success ? 0 : 1)
    }

    /// Copy the Agent source tree into the staging directory so the
    /// compiler can resolve relative imports alongside installed packages.
    static func copyAgentSources(from sourceRoot: String, to stagingDir: String) throws {
        let fm = FileManager.default
        let agentRelDir = "Agent"
        let srcDir = URL(fileURLWithPath: agentRelDir, relativeTo: URL(fileURLWithPath: sourceRoot)).standardizedFileURL
        let dstDir = URL(fileURLWithPath: agentRelDir, relativeTo: URL(fileURLWithPath: stagingDir))

        guard fm.fileExists(atPath: srcDir.path) else { return }

        let enumerator = fm.enumerator(
            at: srcDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true, url.lastPathComponent == "node_modules" {
                enumerator?.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }

            let relPath = url.path.replacingOccurrences(of: srcDir.path + "/", with: "")
            guard relPath != "package.json", relPath != "package-lock.json" else { continue }
            let dst = dstDir.appendingPathComponent(relPath)

            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: dst)
        }
    }

    static func runNPMInstall(in directory: String, specs: [String], preferCleanInstall: Bool) throws {
        let args: [String]
        if preferCleanInstall {
            args = ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"]
        } else {
            args = ["npm", "install", "--ignore-scripts", "--no-audit", "--no-fund"] + specs
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ToolError.buildFailed("npm \(args.dropFirst().joined(separator: " ")) exited with \(process.terminationStatus)")
        }
    }
}

enum ToolError: LocalizedError {
    case usage(String)
    case buildFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .buildFailed(let message):
            return "Build failed: \(message)"
        }
    }
}

private func makeAgentFile(from entries: [LumaBundleCompiler.CompiledEntry]) -> String {
    var out = generatedFileHeader() + """
        enum LumaAgent {

        """

    for (index, entry) in entries.enumerated() {
        let indented = indentMultiline(entry.source, by: 4)

        if index > 0 {
            out += "\n"
        }

        out += """
                static let \(entry.swiftName)Source: String = #\"\"\"
            \(indented)
                \"\"\"#

            """
    }

    out += "}\n"
    return out
}

private func makeTypingsFile(from entries: [LumaBundleCompiler.CompiledTypings]) -> String {
    var out = generatedFileHeader() + """
        enum LumaTypings {

        """

    for (index, entry) in entries.enumerated() {
        if index > 0 {
            out += "\n"
        }

        out += """
                static let \(entry.swiftName): [TypeScriptTypingFile] = [

            """

        for file in entry.files {
            let indented = indentMultiline(file.content, by: 12)
            out += """
                        TypeScriptTypingFile(
                            filePath: \"\(file.filePath)\",
                            content: #\"\"\"
                \(indented)
                            \"\"\"#),

                """
        }

        out += """
                ]

            """
    }

    out += "}\n"
    return out
}

private func generatedFileHeader() -> String {
    """
    // This file is auto-generated by LumaBundleCompiler.
    // Do not edit by hand. Your changes will be overwritten.

    import Foundation


    """
}


private func indentMultiline(_ string: String, by spaces: Int) -> String {
    let prefix = String(repeating: " ", count: spaces)
    return
        string
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { prefix + $0 }
        .joined(separator: "\n")
}

private func unwrapSingleModule(from bundle: String) throws -> String {
    let headerPrefix = "📦\n"
    let separator = "✄\n"

    guard bundle.hasPrefix(headerPrefix) else {
        throw ESMUnwrapError.invalidFormat
    }

    guard let separatorRange = bundle.range(of: "\n" + separator) else {
        throw ESMUnwrapError.headerNotFound
    }

    let headerString = String(bundle[..<separatorRange.lowerBound])
    let headerAndSepString = String(bundle[..<separatorRange.upperBound])

    guard let bundleData = bundle.data(using: .utf8) else {
        throw ESMUnwrapError.encodingError
    }

    let headerAndSepByteCount = headerAndSepString.utf8.count
    let bodyBytes = bundleData[headerAndSepByteCount...]

    let headerLines = headerString.split(separator: "\n", omittingEmptySubsequences: false)
    guard headerLines.first == "📦" else {
        throw ESMUnwrapError.invalidFormat
    }

    guard headerLines.count >= 2 else {
        throw ESMUnwrapError.invalidFormat
    }

    let line = headerLines[1]
    let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let size = Int(parts[0]) else {
        throw ESMUnwrapError.invalidHeaderLine(String(line))
    }

    guard bodyBytes.count >= size else {
        throw ESMUnwrapError.sizeOutOfRange
    }

    let start = bodyBytes.startIndex
    let end = bodyBytes.index(start, offsetBy: size)
    let fileData = bodyBytes[start..<end]

    guard let source = String(data: fileData, encoding: .utf8) else {
        throw ESMUnwrapError.encodingError
    }

    return source
}

private enum ESMUnwrapError: Swift.Error {
    case invalidFormat
    case headerNotFound
    case invalidHeaderLine(String)
    case encodingError
    case sizeOutOfRange
}
