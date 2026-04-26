import Foundation
import PackagePlugin

@main
struct EmbedLumaVersion: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let writer = try context.tool(named: "LumaVersionWriter")
        let version = ProcessInfo.processInfo.environment["LUMA_VERSION"] ?? "0.0.0-dev"
        let output = context.pluginWorkDirectory.appending("LumaVersion.swift")
        return [
            .buildCommand(
                displayName: "Embedding Luma version (\(version))",
                executable: writer.path,
                arguments: [version, output.string],
                outputFiles: [output]
            )
        ]
    }
}
