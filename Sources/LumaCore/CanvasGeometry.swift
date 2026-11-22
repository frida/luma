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
    public var varyings: [ShaderAttribute]
    public var primitive: Primitive
    /// Interleaved, one run of components per attribute per vertex.
    public var vertices: CanvasBytes?
    public var indices: CanvasBytes?

    public init(
        attributes: [ShaderAttribute],
        varyings: [ShaderAttribute] = [],
        primitive: Primitive = .triangles,
        vertices: CanvasBytes? = nil,
        indices: CanvasBytes? = nil
    ) {
        self.attributes = attributes
        self.varyings = varyings
        self.primitive = primitive
        self.vertices = vertices
        self.indices = indices
    }

    public var stride: Int {
        attributes.reduce(0) { $0 + $1.components }
    }

    public var vertexCount: Int {
        stride == 0 ? 0 : (vertices?.count ?? 0) / (stride * MemoryLayout<Float>.stride)
    }

    public var indexCount: Int {
        (indices?.count ?? 0) / MemoryLayout<UInt32>.stride
    }

    public var drawsTriangleEdges: Bool {
        indices != nil && primitive == .lines
    }

    /// Where the shader is headed. OpenGL takes the source as it stands, at a
    /// version with no explicit locations, and binds attributes by name.
    /// Metal's comes through glslang, which wants both.
    public enum Flavor: Sendable {
        case openGL
        case metal
    }

    /// Declares the author's attributes and varyings so their own shader body
    /// compiles against what the renderer binds.
    public func vertexPreamble(
        _ flavor: Flavor,
        uniforms extra: [CanvasUniform] = [],
        buffers: [CanvasBuffer] = [],
        images: [CanvasImage] = []
    ) -> String {
        let inputs = attributes.enumerated().map { index, attribute in
            declaration("in", attribute, at: index, flavor)
        }
        let outputs = varyings.enumerated().map { index, varying in
            declaration("out", varying, at: index, flavor)
        }
        return (["#version \(flavor == .metal ? "450" : "150 core")"]
            + inputs + outputs
            + [uniforms(flavor), declared(extra, flavor),
               sampled(buffers, flavor), pictured(images, after: buffers.count, flavor), ""])
            .joined(separator: "\n")
    }

    public func fragmentPreamble(
        _ flavor: Flavor,
        uniforms extra: [CanvasUniform] = [],
        buffers: [CanvasBuffer] = [],
        images: [CanvasImage] = []
    ) -> String {
        let inputs = varyings.enumerated().map { index, varying in
            declaration("in", varying, at: index, flavor)
        }
        let output = flavor == .metal
            ? "layout(location = 0) out vec4 frag_color;"
            : "out vec4 frag_color;"
        return (["#version \(flavor == .metal ? "450" : "150 core")"]
            + inputs
            + [output, uniforms(flavor), declared(extra, flavor),
               sampled(buffers, flavor), pictured(images, after: buffers.count, flavor), ""])
            .joined(separator: "\n")
    }

    private func declaration(
        _ direction: String,
        _ attribute: ShaderAttribute,
        at index: Int,
        _ flavor: Flavor
    ) -> String {
        let qualifier = flavor == .metal ? "layout(location = \(index)) " : ""
        return "\(qualifier)\(direction) \(attribute.glslType) \(attribute.name);"
    }

    /// The author's own uniforms. OpenGL takes them loose and sets each by
    /// name; Metal wants a block, which the host packs to match.
    private func declared(_ extra: [CanvasUniform], _ flavor: Flavor) -> String {
        guard !extra.isEmpty else { return "" }

        let members = extra.map { "    \($0.glslType) \($0.name);" }
        guard flavor == .metal else {
            return extra.map { "uniform \($0.glslType) \($0.name);" }.joined(separator: "\n")
        }
        return (["layout(binding = 1) uniform CanvasParams {"] + members + ["};"])
            .joined(separator: "\n")
    }

    /// Each run gets a sampler and a reader, so the author says `dataAt` of
    /// their own buffer rather than working out where a texel sits.
    private func sampled(_ buffers: [CanvasBuffer], _ flavor: Flavor) -> String {
        buffers.enumerated().map { index, buffer in
            let binding = flavor == .metal ? "layout(binding = \(2 + index)) " : ""
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

    /// A picture is sampled across rather than read by index, so it needs no
    /// reader of its own: the author says `texture` of it. Its bindings carry
    /// on from where the buffers left off, since both are samplers.
    private func pictured(_ images: [CanvasImage], after buffers: Int, _ flavor: Flavor) -> String {
        images.enumerated().map { index, image in
            let binding = flavor == .metal ? "layout(binding = \(2 + buffers + index)) " : ""
            return "\(binding)uniform sampler2D \(image.name);"
        }.joined(separator: "\n")
    }

    private func uniforms(_ flavor: Flavor) -> String {
        guard flavor == .metal else {
            return """
                uniform vec2 u_resolution;
                uniform float u_time;
                uniform float u_scheme;
                uniform float u_activity;
                uniform float u_pulse;
                uniform float u_data_count;
                uniform float u_scale;
                uniform vec4 u_data[16];
                uniform mat4 u_mvp;
                float dataAt(int i) { return u_data[i / 4][i - (i / 4) * 4]; }
                """
        }
        return ShaderVocabulary.uniformBlock
    }
}

public struct CanvasBytes: Sendable, Equatable {
    public let bytes: SharedBytes
    public let offset: Int
    public let count: Int

    public init(bytes: SharedBytes, offset: Int, count: Int) {
        self.bytes = bytes
        self.offset = offset
        self.count = count
    }

    public init(copying values: UnsafeBufferPointer<Float>) {
        self.init(bytes: SharedBytes(copying: UnsafeRawBufferPointer(values)), offset: 0, count: values.count * MemoryLayout<Float>.stride)
    }

    public init(copying values: [Float]) {
        self = values.withUnsafeBufferPointer { CanvasBytes(copying: $0) }
    }

    public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try bytes.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + count)])) }
    }
}
