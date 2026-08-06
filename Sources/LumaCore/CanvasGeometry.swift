import Foundation

/// One value per vertex, named by whoever wrote the shader. The layout is the
/// author's, so the host generates the declarations to match rather than
/// imposing a vertex format of its own.
public struct ShaderAttribute: Sendable, Equatable {
    public let name: String
    public let components: Int

    public init(name: String, components: Int) {
        self.name = name
        self.components = components
    }

    var glslType: String {
        components == 1 ? "float" : "vec\(components)"
    }
}

/// What a canvas draws, when it draws something other than a screen-filling
/// quad: vertices in the author's own layout, and how to join them up.
public struct CanvasGeometry: Sendable, Equatable {
    public enum Primitive: Int32, Sendable, Equatable {
        case points = 0
        case lines = 1
        case lineStrip = 2
        case triangles = 3
        case triangleStrip = 4
    }

    public var attributes: [ShaderAttribute]
    /// Values the vertex stage hands the fragment stage.
    public var varyings: [ShaderAttribute]
    public var primitive: Primitive
    /// Interleaved, one run of components per attribute per vertex.
    public var vertices: [Float]

    public init(
        attributes: [ShaderAttribute],
        varyings: [ShaderAttribute] = [],
        primitive: Primitive = .triangles,
        vertices: [Float] = []
    ) {
        self.attributes = attributes
        self.varyings = varyings
        self.primitive = primitive
        self.vertices = vertices
    }

    /// Floats per vertex.
    public var stride: Int {
        attributes.reduce(0) { $0 + $1.components }
    }

    public var vertexCount: Int {
        stride == 0 ? 0 : vertices.count / stride
    }

    /// Where the shader is headed. OpenGL takes the source as it stands, at a
    /// version with no explicit locations, and binds attributes by name.
    /// Metal's comes through glslang, which wants both.
    public enum Flavour: Sendable {
        case openGL
        case metal
    }

    /// Declares the author's attributes and varyings so their own shader body
    /// compiles against what the renderer binds.
    public func vertexPreamble(
        _ flavour: Flavour,
        uniforms extra: [CanvasUniform] = [],
        buffers: [CanvasBuffer] = []
    ) -> String {
        let inputs = attributes.enumerated().map { index, attribute in
            declaration("in", attribute, at: index, flavour)
        }
        let outputs = varyings.enumerated().map { index, varying in
            declaration("out", varying, at: index, flavour)
        }
        return (["#version \(flavour == .metal ? "450" : "150 core")"]
            + inputs + outputs
            + [uniforms(flavour), declared(extra, flavour), sampled(buffers, flavour), ""])
            .joined(separator: "\n")
    }

    public func fragmentPreamble(
        _ flavour: Flavour,
        uniforms extra: [CanvasUniform] = [],
        buffers: [CanvasBuffer] = []
    ) -> String {
        let inputs = varyings.enumerated().map { index, varying in
            declaration("in", varying, at: index, flavour)
        }
        let output = flavour == .metal
            ? "layout(location = 0) out vec4 frag_color;"
            : "out vec4 frag_color;"
        return (["#version \(flavour == .metal ? "450" : "150 core")"]
            + inputs
            + [output, uniforms(flavour), declared(extra, flavour), sampled(buffers, flavour), ""])
            .joined(separator: "\n")
    }

    private func declaration(
        _ direction: String,
        _ attribute: ShaderAttribute,
        at index: Int,
        _ flavour: Flavour
    ) -> String {
        let qualifier = flavour == .metal ? "layout(location = \(index)) " : ""
        return "\(qualifier)\(direction) \(attribute.glslType) \(attribute.name);"
    }

    /// The author's own uniforms. OpenGL takes them loose and sets each by
    /// name; Metal wants a block, which the host packs to match.
    private func declared(_ extra: [CanvasUniform], _ flavour: Flavour) -> String {
        guard !extra.isEmpty else { return "" }

        let members = extra.map { "    \($0.glslType) \($0.name);" }
        guard flavour == .metal else {
            return extra.map { "uniform \($0.glslType) \($0.name);" }.joined(separator: "\n")
        }
        return (["layout(binding = 1) uniform CanvasParams {"] + members + ["};"])
            .joined(separator: "\n")
    }

    /// Each run gets a sampler and a reader, so the author says `dataAt` of
    /// their own buffer rather than working out where a texel sits.
    private func sampled(_ buffers: [CanvasBuffer], _ flavour: Flavour) -> String {
        buffers.enumerated().map { index, buffer in
            let binding = flavour == .metal ? "layout(binding = \(2 + index)) " : ""
            // The row length is declared with the author's own uniforms, so
            // naming it here as well would redefine it -- and, for Metal,
            // put a non-opaque uniform outside a block.
            return """
                \(binding)uniform sampler2D \(buffer.name);
                float \(buffer.name)At(int i) {
                    int w = int(\(buffer.name)_size.x);
                    return texelFetch(\(buffer.name), ivec2(i - i / w * w, i / w), 0).r;
                }
                """
        }.joined(separator: "\n")
    }

    private func uniforms(_ flavour: Flavour) -> String {
        guard flavour == .metal else {
            return """
                uniform vec2 u_resolution;
                uniform float u_time;
                uniform float u_scheme;
                uniform float u_activity;
                uniform float u_pulse;
                uniform float u_data_count;
                uniform vec4 u_data[16];
                uniform mat4 u_mvp;
                float dataAt(int i) { return u_data[i / 4][i - (i / 4) * 4]; }
                """
        }
        return ShaderVocabulary.uniformBlock
    }
}
