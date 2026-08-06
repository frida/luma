import CShaderTranslate
import Foundation

/// Turns GLSL written at runtime into Metal Shading Language, so an effect
/// typed into a snippet reaches a Metal host without a build step. The GTK
/// host needs none of this: OpenGL takes the GLSL as it stands.
public enum ShaderTranslator {

    /// The preamble every authored effect is compiled against, naming the
    /// uniforms it may read. It matches what `LumaShaderCompiler` prepends at
    /// build time, so an effect reads the same whether it was authored here or
    /// shipped in `Shaders/`.
    /// What a screen-filling effect is compiled against: the vertex stage is
    /// the host's, handing down only where on screen the pixel sits.
    public static var preamble: String {
        """
        \(ShaderVocabulary.header)
        layout(location = 0) in vec2 v_uv;
        layout(location = 0) out vec4 frag_color;
        \(ShaderVocabulary.uniformBlock)

        """
    }

    /// Answers the Metal source for `body`, which carries only its own helpers
    /// and `main()`.
    public static func metalSource(for body: String, entryPoint: String) throws -> String {
        try metalSource(forComplete: preamble + body, stage: .fragment, entryPoint: entryPoint)
    }

    public enum Stage: Int32 {
        case vertex = 0
        case fragment = 1
    }

    /// Translates a whole shader, preamble and all, for callers that build
    /// their own -- a canvas whose attributes the author declared.
    public static func metalSource(forComplete glsl: String, stage: Stage, entryPoint: String) throws -> String {
        var message: UnsafeMutablePointer<CChar>?
        let translated = luma_shader_translate_to_msl(glsl, stage.rawValue, entryPoint, &message)

        guard let translated else {
            let detail = message.map { String(cString: $0) } ?? "no detail"
            message.map { free($0) }
            throw ShaderTranslationError(message: detail)
        }

        defer { free(translated) }
        return String(cString: translated)
    }
}

/// Carries what the shader compiler said, so a mistyped effect is reported
/// where it was written rather than drawing nothing.
public struct ShaderTranslationError: Error, CustomStringConvertible {
    public let message: String

    public var description: String { message }
}
