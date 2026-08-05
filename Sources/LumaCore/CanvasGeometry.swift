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
    public func vertexPreamble(_ flavour: Flavour) -> String {
        let inputs = attributes.enumerated().map { index, attribute in
            declaration("in", attribute, at: index, flavour)
        }
        let outputs = varyings.enumerated().map { index, varying in
            declaration("out", varying, at: index, flavour)
        }
        return (["#version \(flavour == .metal ? "450" : "150 core")"]
            + inputs + outputs + [uniforms(flavour), ""]).joined(separator: "\n")
    }

    public func fragmentPreamble(_ flavour: Flavour) -> String {
        let inputs = varyings.enumerated().map { index, varying in
            declaration("in", varying, at: index, flavour)
        }
        let output = flavour == .metal
            ? "layout(location = 0) out vec4 frag_color;"
            : "out vec4 frag_color;"
        return (["#version \(flavour == .metal ? "450" : "150 core")"]
            + inputs + [output, uniforms(flavour), ""]).joined(separator: "\n")
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
                float dataAt(int i) { return u_data[i / 4][i - (i / 4) * 4]; }
                """
        }
        return ShaderTranslator.uniformBlock
    }
}
