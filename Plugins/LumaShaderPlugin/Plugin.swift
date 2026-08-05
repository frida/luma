import Foundation
import PackagePlugin

@main
struct LumaShaderPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let compiler = try context.tool(named: "LumaShaderCompiler")
        let shaderDirectory = context.package.directoryURL.appending(path: "Shaders")
        let output = context.pluginWorkDirectoryURL.appending(path: "ShaderEffects.swift")

        let sources = try FileManager.default
            .contentsOfDirectory(atPath: shaderDirectory.path)
            .filter { $0.hasSuffix(".frag.glsl") }
            .sorted()
            .map { shaderDirectory.appending(path: $0) }

        return [
            .buildCommand(
                displayName: "Generating Luma shader effects",
                executable: compiler.url,
                arguments: [
                    "--shader-dir", shaderDirectory.path,
                    "--swift-out", output.path,
                ],
                inputFiles: sources + [context.package.directoryURL.appending(path: "Sources/LumaShaderCompiler/main.swift")],
                outputFiles: [output]
            )
        ]
    }
}
