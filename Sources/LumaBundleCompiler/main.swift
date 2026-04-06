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
    enum Kind {
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
        var stagingDir: String?
        var entries: [Entry] = []
        var packageSpecs: [String] = []
        var localPackages: [(name: String, path: String)] = []

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
            case "--project-root":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --project-root") }
                projectRoot = args.removeFirst()

            case "--swift-out":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --swift-out") }
                swiftOutPath = args.removeFirst()

            case "--staging-dir":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --staging-dir") }
                stagingDir = args.removeFirst()

            case "--package":
                guard !args.isEmpty else { throw ToolError.usage("Missing value for --package") }
                packageSpecs.append(args.removeFirst())

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

        let effectiveProjectRoot: String
        if !packageSpecs.isEmpty || !localPackages.isEmpty {
            guard let stagingDir else {
                throw ToolError.usage("--staging-dir is required when using --package or --local-package.")
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

            fputs("[packages] installing: \(packageSpecs.joined(separator: ", "))\n", stderr)

            let pm = PackageManager()
            let opts = PackageInstallOptions()
            opts.projectRoot = stagingDir
            opts.role = .runtime
            opts.specs = packageSpecs

            _ = try await pm.install(options: opts)

            fputs("[packages] done\n", stderr)

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
        let options = BuildOptions()
        options.projectRoot = effectiveProjectRoot
        options.sourceMaps = .omitted

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
            let bundle = try await compiler.build(entrypoint: entry.entrypoint, options: options)

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

        let swiftFile = makeSwiftFile(from: compiled)
        let url = URL(fileURLWithPath: swiftOutPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil)
        try swiftFile.write(to: url, atomically: true, encoding: .utf8)
    }

    static func printUsageAndExit(success: Bool) -> Never {
        let prog = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "LumaBundleCompiler"
        let text = """
            Usage:
              \(prog) --swift-out <swift-file> [--project-root <path>] \\
                      [--staging-dir <path>] [--package <spec>]... \\
                      [--agent <swiftName> <entry.ts>]... \\
                      [--module <swiftName> <entry.ts>]...

            Kinds:
              agent   - keep Frida's compiled bundle container as a Swift string
              module  - unwrap Frida's 📦 bundle and embed only the module JS

            Options:
              --staging-dir <path>  Directory for package installation and compilation
              --package <spec>      Install npm package into staging dir before compilation

            Examples:
              \(prog) --project-root /path/to/repo \\
                      --swift-out Luma/Generated/LumaAgent.swift \\
                      --staging-dir /path/to/build/.agent-staging \\
                      --package frida-itrace \\
                      --agent  core      Luma/Agent/core/luma.ts \\
                      --agent  drain     Luma/Agent/instruments/drain-agent.ts \\
                      --module tracer    Luma/Agent/instruments/tracer.ts \\
                      --module codeShare Luma/Agent/instruments/codeshare.ts

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
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            let relPath = url.path.replacingOccurrences(of: srcDir.path + "/", with: "")
            let dst = dstDir.appendingPathComponent(relPath)

            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: dst)
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

private func makeSwiftFile(from entries: [LumaBundleCompiler.CompiledEntry]) -> String {
    var out = """
        // This file is auto-generated by LumaBundleCompiler.
        // Do not edit by hand. Your changes will be overwritten.

        import Foundation

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
