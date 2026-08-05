import Foundation

LumaShaderCompiler.main()

/// Translates each authored effect in `Shaders/` into the two forms the
/// frontends consume: a Metal fragment function for the SwiftUI host, and a C
/// string literal of the original GLSL for the GTK host's `luma_shader_effect`
/// widget. Authors write the effect once, body-only, against the uniform
/// vocabulary the preamble below declares.
struct LumaShaderCompiler {
    static let preamble = """
        #version 450
        layout(location = 0) in vec2 v_uv;
        layout(location = 0) out vec4 frag_color;
        layout(binding = 0) uniform ShaderEffectUniforms {
            vec2 u_resolution;
            float u_time;
            float u_scheme;
        };

        """

    static func main() {
        let options = Options(arguments: CommandLine.arguments)

        for effect in effects(in: options.shaderDir) {
            let body = try! String(contentsOf: effect.source, encoding: .utf8)
            write(metalFragment(named: effect.name, body: body), to: options.metalDir, as: "\(effect.metalName).metal")
            write(cStringLiteral(of: body, named: effect.cName), to: options.headerDir, as: "\(effect.cName).h")
        }
    }

    private static func effects(in directory: URL) -> [Effect] {
        let names = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .filter { $0.hasSuffix(".frag.glsl") }
            .sorted()
            .map { Effect(fileName: $0, directory: directory) }
    }

    private static func metalFragment(named name: String, body: String) -> String {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-shader-compiler-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let glsl = workDir.appendingPathComponent("effect.frag")
        let spirv = workDir.appendingPathComponent("effect.spv")
        try! (preamble + body).write(to: glsl, atomically: true, encoding: .utf8)

        run("glslang", ["-V", glsl.path, "-o", spirv.path])
        return run("spirv-cross", [
            "--msl",
            "--rename-entry-point", "main", name, "frag",
            spirv.path,
        ])
    }

    private static func cStringLiteral(of body: String, named name: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let escaped = line
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "    \"\(escaped)\\n\""
        }
        return """
            #pragma once

            static const char *\(name)_src =
            \(lines.joined(separator: "\n"));

            """
    }

    private static func write(_ contents: String, to directory: URL, as fileName: String) {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        guard (try? String(contentsOf: destination, encoding: .utf8)) != contents else { return }
        try! contents.write(to: destination, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        let output = Pipe()
        process.standardOutput = output
        try! process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            FileHandle.standardError.write("luma-shader-compiler: \(tool) failed\n".data(using: .utf8)!)
            exit(1)
        }
        return String(data: data, encoding: .utf8)!
    }

    private struct Effect {
        let name: String
        let metalName: String
        let cName: String
        let source: URL

        init(fileName: String, directory: URL) {
            let stem = fileName.replacingOccurrences(of: ".frag.glsl", with: "")
            let words = stem.split(separator: "-")
            name = words.first! + words.dropFirst().map { $0.capitalized }.joined() + "Fragment"
            metalName = words.map { $0.capitalized }.joined() + "Fragment"
            cName = words.joined(separator: "_") + "_fragment"
            source = directory.appendingPathComponent(fileName)
        }
    }

    private struct Options {
        let shaderDir: URL
        let metalDir: URL
        let headerDir: URL

        init(arguments: [String]) {
            var values: [String: String] = [:]
            for index in stride(from: 1, to: arguments.count - 1, by: 2) {
                values[arguments[index]] = arguments[index + 1]
            }
            shaderDir = URL(fileURLWithPath: values["--shader-dir"]!)
            metalDir = URL(fileURLWithPath: values["--metal-dir"]!)
            headerDir = URL(fileURLWithPath: values["--header-dir"]!)
        }
    }
}
