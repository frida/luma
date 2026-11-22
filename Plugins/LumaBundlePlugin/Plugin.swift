import Foundation
import PackagePlugin

@main
struct LumaBundlePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let compiler = try context.tool(named: "LumaBundleCompiler")
        let versionWriter = try context.tool(named: "LumaVersionWriter")
        let packageRoot = context.package.directoryURL
        let workDirectory = context.pluginWorkDirectoryURL
        let swiftOutput = workDirectory.appending(path: "LumaAgent.swift")
        let typingsOutput = workDirectory.appending(path: "LumaTypings.swift")
        let versionOutput = workDirectory.appending(path: "LumaVersion.swift")
        let stagingDirectory = workDirectory.appending(path: "AgentStaging", directoryHint: .isDirectory)

        let inputFiles = [
            "Package.swift",
            "Agent/bundle.json",
            "Agent/package.json",
            "Agent/package-lock.json",
            "Agent/core/console.ts",
            "Agent/core/env.ts",
            "Agent/core/instrument.ts",
            "Agent/core/itrace.ts",
            "Agent/core/luma.ts",
            "Agent/core/memory.ts",
            "Agent/core/modules.ts",
            "Agent/core/pkg.ts",
            "Agent/core/repl.ts",
            "Agent/core/resolver.ts",
            "Agent/core/swift.ts",
            "Agent/core/symbolicate.ts",
            "Agent/core/threads.ts",
            "Agent/core/value.ts",
            "Agent/instruments/codeshare.ts",
            "Agent/instruments/drain-agent.ts",
            "Agent/instruments/tracer.ts",
            "Sources/LumaBundleCompiler/main.swift",
        ].map { packageRoot.appending(path: $0) }

        return [
            .buildCommand(
                displayName: "Generating Luma agent bundles",
                executable: compiler.url,
                arguments: [
                    "--swift-out", swiftOutput.path,
                    "--typings-out", typingsOutput.path,
                    "--config", packageRoot.appending(path: "Agent/bundle.json").path,
                    "--project-root", packageRoot.path,
                    "--staging-dir", stagingDirectory.path,
                    "--no-lockfile-update",
                ],
                inputFiles: inputFiles,
                outputFiles: [swiftOutput, typingsOutput]
            ),
            .buildCommand(
                displayName: "Embedding Luma version",
                executable: versionWriter.url,
                arguments: [packageRoot.path, versionOutput.path] + Self.statedVersion,
                inputFiles: Self.versionInputs(in: packageRoot),
                outputFiles: [versionOutput]
            ),
        ]
    }

    private static var statedVersion: [String] {
        ProcessInfo.processInfo.environment["LUMA_VERSION"].map { [$0] } ?? []
    }

    private static func versionInputs(in packageRoot: URL) -> [URL] {
        let candidates = ["VERSION", "Scripts/luma-version.sh"].map { packageRoot.appending(path: $0) }
            + [gitDirectory(of: packageRoot).appending(path: "logs/HEAD")]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func gitDirectory(of packageRoot: URL) -> URL {
        let dotGit = packageRoot.appending(path: ".git")
        guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8), pointer.hasPrefix(gitDirectoryPointer) else {
            return dotGit
        }
        let path = pointer.dropFirst(gitDirectoryPointer.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, relativeTo: packageRoot).standardizedFileURL
    }

    private static let gitDirectoryPointer = "gitdir: "
}
