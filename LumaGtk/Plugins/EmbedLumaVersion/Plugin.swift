import Foundation
import PackagePlugin

@main
struct EmbedLumaVersion: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let writer = try context.tool(named: "LumaVersionWriter")
        let version = ProcessInfo.processInfo.environment["LUMA_VERSION"] ?? "0.0.0-dev"
        let output = context.pluginWorkDirectoryURL.appending(path: "LumaVersion.swift")
        return [
            .buildCommand(
                displayName: "Embedding Luma version (\(version))",
                executable: writer.url,
                arguments: [version, output.path],
                outputFiles: [output]
            )
        ]
    }
}
