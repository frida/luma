import Foundation
import PackagePlugin

@main
struct LumaBundlePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let compiler = try context.tool(named: "LumaBundleCompiler")
        let packageRoot = context.package.directoryURL
        let workDirectory = context.pluginWorkDirectoryURL
        let swiftOutput = workDirectory.appending(path: "LumaAgent.swift")
        let typingsOutput = workDirectory.appending(path: "LumaTypings.swift")
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
                outputFiles: [swiftOutput, typingsOutput, stagingDirectory]
            ),
        ]
    }
}
