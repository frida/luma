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

    /// Declares the author's attributes and varyings so their own shader body
    /// compiles against locations the host binds to.
    public func vertexPreamble() -> String {
        let inputs = attributes.enumerated().map { index, attribute in
            "layout(location = \(index)) in \(attribute.glslType) \(attribute.name);"
        }
        let outputs = varyings.enumerated().map { index, varying in
            "layout(location = \(index)) out \(varying.glslType) \(varying.name);"
        }
        return ([ShaderTranslator.header] + inputs + outputs + [ShaderTranslator.uniformBlock, ""])
            .joined(separator: "\n")
    }

    public func fragmentPreamble() -> String {
        let inputs = varyings.enumerated().map { index, varying in
            "layout(location = \(index)) in \(varying.glslType) \(varying.name);"
        }
        let outputs = ["layout(location = 0) out vec4 frag_color;"]
        return ([ShaderTranslator.header] + inputs + outputs + [ShaderTranslator.uniformBlock, ""])
            .joined(separator: "\n")
    }
}
